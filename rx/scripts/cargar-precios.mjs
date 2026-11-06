#!/usr/bin/env node
// ============================================================================
// RX — Carga precios de farmacias a la base, desde un CSV o un Excel.
//
//   npm --prefix rx run precios -- <archivo.csv|xlsx> --fuente <nombre> [opciones]
//
//   --seco                  solo lee el archivo: no toca la base, así que no
//                           comprueba farmacias, controlados ni rangos.
//   --visto-en <ISO>        la fecha de las filas que no traen la suya, con zona:
//                           2026-11-06T10:00:00-04:00. Nunca se asume «ahora».
//   --farmacia-nueva <X>    admite esa farmacia antes de cargar.
//
// ⚠️ Escribe en producción (`rx_cargar_precios`). Entra por la Management API,
// como `aplicar.mjs`, con la sesión del CLI de Supabase: ninguna cuenta de la
// app puede cargar precios, y por eso el médico tampoco.
//
// Columnas (la primera fila es la cabecera; ver rx/plantilla-precios.csv):
//   farmacia, nombre, precio, moneda    obligatorias
//   visto_en                            obligatoria, o con --visto-en
//   laboratorio, presentacion, sku, url, disponible, fuente, controlado
// ============================================================================

import { randomBytes } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { consultar } from '../../supabase/poda/aplicar.mjs'
import { aFilas, enLotes, leerCsv } from './lector-precios.mjs'

const TAMANO_LOTE = 1000

function opcion(args, nombre) {
  const i = args.indexOf(nombre)
  return i === -1 ? undefined : args[i + 1]
}

async function leerArchivo(ruta) {
  const extension = path.extname(ruta).toLowerCase()
  if (extension === '.csv') return leerCsv(fs.readFileSync(ruta, 'utf8'))
  if (extension === '.xlsx') {
    const { readSheet } = await import('read-excel-file/node')
    return readSheet(ruta)
  }
  throw new Error('Solo se aceptan archivos .csv o .xlsx.')
}

function literal(texto) {
  return `'${String(texto).replaceAll("'", "''")}'`
}

function sqlDelLote(fuente, archivo, filas) {
  // Una etiqueta al azar: ningún texto del archivo puede cerrar la cadena.
  const etiqueta = `rx${randomBytes(8).toString('hex')}`
  const json = JSON.stringify(filas)
  return `select public.rx_cargar_precios(${literal(fuente)}, ${literal(archivo)}, $${etiqueta}$${json}$${etiqueta}$::jsonb) as r`
}

async function main() {
  const args = process.argv.slice(2)
  const conValor = new Set(['--fuente', '--visto-en', '--farmacia-nueva'])
  const ruta = args.find((a, i) => !a.startsWith('--') && !conValor.has(args[i - 1]))
  const fuente = opcion(args, '--fuente')
  const vistoEn = opcion(args, '--visto-en')
  const farmaciaNueva = opcion(args, '--farmacia-nueva')
  const seco = args.includes('--seco')

  if (!ruta || !fuente) {
    console.error('Uso: npm --prefix rx run precios -- <archivo.csv|xlsx> --fuente <nombre> [--seco] [--visto-en <ISO>] [--farmacia-nueva <nombre>]')
    process.exit(2)
  }

  const { filas, rechazos } = aFilas(await leerArchivo(ruta))
  if (vistoEn) for (const fila of filas) fila.visto_en ||= vistoEn
  console.log(`${path.basename(ruta)}: ${filas.length} filas legibles, ${rechazos.length} rechazadas al leer.`)
  for (const r of rechazos.slice(0, 20)) console.log(`  fila ${r.fila}: ${r.motivo}`)
  if (rechazos.length > 20) console.log(`  … y ${rechazos.length - 20} más`)

  if (seco) {
    console.log('Modo seco: no se tocó la base.')
    return
  }

  if (farmaciaNueva) {
    consultar(`select public.rx_agregar_farmacia(${literal(farmaciaNueva)}) as slug`)
    console.log(`Farmacia admitida: ${farmaciaNueva}`)
  }

  let aceptadas = 0
  let ignoradas = 0
  let rechazadas = 0
  const motivos = new Map()
  const lotes = enLotes(filas, TAMANO_LOTE)

  for (const [i, lote] of lotes.entries()) {
    const [{ r }] = consultar(sqlDelLote(fuente, path.basename(ruta), lote))
    const resultado = typeof r === 'string' ? JSON.parse(r) : r
    aceptadas += resultado.aceptadas
    ignoradas += resultado.ignoradas
    rechazadas += resultado.rechazadas
    for (const { motivo } of resultado.rechazos) motivos.set(motivo, (motivos.get(motivo) ?? 0) + 1)
    console.log(`Lote ${i + 1}/${lotes.length}: ${resultado.aceptadas} aceptadas, ${resultado.rechazadas} rechazadas.`)
  }

  console.log(`Listo: ${aceptadas} aceptadas, ${ignoradas} más viejas que lo guardado, ${rechazadas + rechazos.length} rechazadas.`)
  for (const [motivo, cuantas] of motivos) console.log(`  ${motivo}: ${cuantas}`)
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e instanceof Error ? e.message : e)
    process.exit(1)
  })
}
