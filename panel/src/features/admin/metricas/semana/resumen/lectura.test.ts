/**
 * Pruebas de la lectura de `admin_metricas_semana_resumen`.
 *
 *   npx tsx src/features/admin/metricas/semana/resumen/lectura.test.ts
 *
 * Lo que se vigila: que cada cifra llegue a su sitio con su clase de dinero
 * (facturado sin comisión, total a cobrar con sus dos partes), que la comisión se
 * deduzca si falta, que lo que puede faltar llegue como null y no como cero,
 * y que una respuesta sin la semana o sin sus cifras se rechace en vez de
 * pintarse en ceros.
 */
import { leerResumen } from './lectura'
import { respuestaCruda } from './__fixtures__/respuestaResumen'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

function lanza(fn: () => unknown, titulo: string) {
  let lanzo = false
  try {
    fn()
  } catch {
    lanzo = true
  }
  if (!lanzo) fallos++
  console.log(`${lanzo ? '  ok  ' : ' FALLA'}  ${titulo}`)
}

console.log('── La respuesta entera ───────────────────────────────────────')
const r = leerResumen(respuestaCruda())
igual(r.hoy, '2026-09-26', 'el hoy que usó la base')
igual(r.semana, { desde: '2026-09-21', hasta: '2026-09-27', enCurso: true }, 'la semana que usó la base')
igual([r.hasta, r.dias], ['2026-09-26', 6], 'cuenta hasta hoy: seis días')
igual(
  r.anterior,
  { desde: '2026-09-14', hasta: '2026-09-19', dias: 6, mismaAltura: true, corte: '2026-09-19T19:00:00+00:00' },
  'la anterior, hasta el mismo momento (con su corte)',
)
igual(r.local, null, 'sin clínica')
igual(leerResumen(respuestaCruda({ local: 'abc' })).local, 'abc', 'con clínica')

console.log('── Las cifras ────────────────────────────────────────────────')
igual(r.cifras.financedUsd, 1129, 'total financiado: el financiamiento sin comisión')
igual(r.cifras.feeUsd, 261.92, 'Comisión Helios + IVA')
igual(r.cifras.payableUsd, 1390.92, 'total a cobrar')
igual(
  Math.round((r.cifras.financedUsd + r.cifras.feeUsd) * 100) / 100,
  r.cifras.payableUsd,
  'el total a cobrar es financiado + comisión',
)
igual([r.cifras.servicioUsd, r.cifras.ivaUsd], [225.8, 36.12], 'la comisión sin IVA y su IVA')
igual([r.cifras.consumos, r.cifras.personas, r.cifras.nuevas], [43, 61, 30], 'financiamientos, pacientes y nuevos')
igual(r.cifras.ticketMedioUsd, 26.26, 'ticket medio sin comisión')
igual(r.comparacion.financedUsd, 1015.5, 'la comparación')

console.log('── La chispa ─────────────────────────────────────────────────')
igual(r.semanas.length, 8, 'ocho semanas')
igual(r.semanas.at(-1)?.desde, '2026-09-21', 'la última es la elegida')
igual(r.semanas.at(-1)?.enCurso, true, 'y está en curso')
igual(r.semanas.at(-1)?.hastaDato, '2026-09-26', 'con datos hasta hoy')
igual(r.semanas[0]?.desde, '2026-08-03', 'de la más vieja a la elegida')

console.log('── Los días ────────────────────────────────────────────────')
igual(r.noches.length, 3, 'tres días con financiamiento')
igual(r.noches[0]?.dia, '2026-09-26', 'la primera, la más reciente')
igual(r.noches[0]?.nombre, 'Terraza Semilla', 'con el nombre de la clínica')
igual(
  [r.noches[0]?.financedUsd, r.noches[0]?.feeUsd, r.noches[0]?.payableUsd],
  [182, 42.21, 224.21],
  'cada día con sus tres cifras de dinero',
)

console.log('── Lo que falta ──────────────────────────────────────────────')
const sinFee = leerResumen({
  ...respuestaCruda(),
  cifras: { financed_usd: 100, payable_usd: 123.2, consumos: 2, personas: 3 },
})
igual(sinFee.cifras.feeUsd, 23.2, 'sin fee_usd, se deduce: payable − financed')
igual(sinFee.cifras.ticketMedioUsd, null, 'sin ticket, null (no cero)')
const sinConsumo = leerResumen({
  ...respuestaCruda({ noches: [] }),
  cifras: { financed_usd: 0, fee_usd: 0, payable_usd: 0, consumos: 0, ticket_medio_usd: null, personas: 0, nuevas: 0 },
})
igual(sinConsumo.noches, [], 'una semana sin financiamientos: ningún día')
igual(sinConsumo.cifras.consumos, 0, 'y cero financiamientos, que es un dato')
igual(
  leerResumen({ ...respuestaCruda(), noches: [{ business_date: 'ayer', merchant_id: 'x' }, { nombre: 'sin nada' }] }).noches,
  [],
  'un día sin día o sin clínica se descarta',
)
lanza(() => leerResumen({ ...respuestaCruda(), semana: null }), 'sin la semana, se rechaza')
lanza(() => leerResumen({ ...respuestaCruda(), cifras: undefined }), 'sin sus cifras, se rechaza')
lanza(() => leerResumen({ ...respuestaCruda(), anterior: {} }), 'sin la anterior, se rechaza')
lanza(() => leerResumen(null), 'una respuesta vacía se rechaza')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
