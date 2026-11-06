// ============================================================================
// RX — Lee un archivo de precios y lo deja en filas limpias, sin base ni red.
// La validación de verdad la hace `rx_cargar_precios`: aquí se rechaza lo que
// no se puede interpretar sin adivinar (un precio como «1.234,50»).
// ============================================================================

export const COLUMNAS = [
  'farmacia', 'nombre', 'precio', 'moneda', 'laboratorio', 'presentacion',
  'sku', 'url', 'disponible', 'visto_en', 'fuente', 'controlado',
]
const OBLIGATORIAS = ['farmacia', 'nombre', 'precio', 'moneda']

/** Texto CSV a filas de celdas. Admite comas o punto y coma (Excel en español), comillas y BOM. */
export function leerCsv(texto) {
  const limpio = texto.replace(/^﻿/, '')
  const primera = limpio.split(/\r?\n/, 1)[0] ?? ''
  const separador = (primera.match(/;/g)?.length ?? 0) > (primera.match(/,/g)?.length ?? 0) ? ';' : ','

  const filas = []
  let fila = []
  let celda = ''
  let entreComillas = false

  for (let i = 0; i < limpio.length; i++) {
    const c = limpio[i]
    if (entreComillas) {
      if (c === '"' && limpio[i + 1] === '"') {
        celda += '"'
        i++
      } else if (c === '"') {
        entreComillas = false
      } else {
        celda += c
      }
    } else if (c === '"') {
      entreComillas = true
    } else if (c === separador) {
      fila.push(celda)
      celda = ''
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && limpio[i + 1] === '\n') i++
      fila.push(celda)
      filas.push(fila)
      fila = []
      celda = ''
    } else {
      celda += c
    }
  }
  if (entreComillas) throw new Error('El archivo tiene unas comillas sin cerrar.')
  if (celda !== '' || fila.length > 0) {
    fila.push(celda)
    filas.push(fila)
  }
  return filas
}

/**
 * Un precio sin adivinar: «12.50», «12,50» o 12.5. «1.234,50» se rechaza, y
 * también «1.234» o «1,234»: pueden ser mil doscientos o uno con veintitrés.
 */
export function leerPrecio(valor) {
  if (typeof valor === 'number') return Number.isFinite(valor) && valor > 0 ? String(valor) : null
  const texto = String(valor ?? '').trim()
  if (/^[0-9]{1,3}[.,][0-9]{3}$/.test(texto)) return null
  if (/^[0-9]+(\.[0-9]+)?$/.test(texto)) return texto
  if (/^[0-9]+,[0-9]{1,4}$/.test(texto)) return texto.replace(',', '.')
  return null
}

function celdaATexto(valor) {
  if (valor === null || valor === undefined) return ''
  if (valor instanceof Date) return valor.toISOString()
  return String(valor).replaceAll('\u0000', '').trim()
}

/**
 * Filas de celdas (de un CSV o un Excel) a objetos para la base. La primera fila
 * es la cabecera; las columnas que sobran se ignoran y sin una obligatoria no se
 * sigue. Devuelve `{ filas, rechazos }`, con el número de fila del archivo.
 */
export function aFilas(celdas) {
  if (celdas.length === 0) throw new Error('El archivo está vacío.')
  const cabecera = celdas[0].map((c) => celdaATexto(c).toLowerCase())
  const faltan = OBLIGATORIAS.filter((c) => !cabecera.includes(c))
  if (faltan.length > 0) throw new Error(`Faltan las columnas: ${faltan.join(', ')}.`)

  const filas = []
  const rechazos = []
  celdas.slice(1).forEach((fila, i) => {
    if (fila.every((c) => celdaATexto(c) === '')) return
    const numero = i + 2
    const objeto = {}
    for (const columna of COLUMNAS) {
      const j = cabecera.indexOf(columna)
      objeto[columna] = j === -1 ? '' : fila[j]
    }
    if (COLUMNAS.some((c) => celdaATexto(objeto[c]).includes('�'))) {
      rechazos.push({ fila: numero, motivo: 'Caracteres dañados: guarda el archivo como CSV UTF-8' })
      return
    }
    const precio = leerPrecio(objeto.precio)
    if (precio === null) {
      rechazos.push({ fila: numero, motivo: `Precio no válido: «${celdaATexto(objeto.precio)}»` })
      return
    }
    filas.push({
      ...Object.fromEntries(COLUMNAS.map((c) => [c, celdaATexto(objeto[c])])),
      precio,
      fila_archivo: numero,
    })
  })
  return { filas, rechazos }
}

export function enLotes(lista, tamano) {
  const lotes = []
  for (let i = 0; i < lista.length; i += tamano) lotes.push(lista.slice(i, i + tamano))
  return lotes
}
