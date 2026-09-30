/**
 * Pruebas de la lectura de `admin_metricas_locales`.
 *
 *   npx tsx src/features/admin/metricas/locales/lectura.test.ts
 *
 * Lo que se vigila: que cada campo llegue con su nombre (también los
 * numéricos que la base manda como texto), que lo vencido llegue SIEMPRE con
 * sus dos partes, que lo que falta sea nulo y no cero (un ticket sin
 * consumos, un porcentaje sin cuotas juzgadas), que las series y las
 * cohortes queden alineadas con sus semanas y que una respuesta rota no tire
 * la pestaña.
 */
import { RESPUESTA_SEMANA } from './__fixtures__/semana'
import { leerFilaLocal, leerLocalesDeLaSemana } from './lectura'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const d = leerLocalesDeLaSemana(RESPUESTA_SEMANA)

console.log('── La semana que usó la base ─────────────────────────────────')
igual(d.semana, { desde: '2026-09-21', hasta: '2026-09-27', enCurso: true }, 'la semana, con su lunes, su domingo y en curso')
igual([d.hoy, d.hasta, d.dias], ['2026-09-26', '2026-09-26', 6], 'hoy, el último día contado y los días')
igual(d.anterior, { desde: '2026-09-14', hasta: '2026-09-19', mismaAltura: true }, 'la anterior, a la misma altura')
igual(d.cierre, { lunes: '2026-09-28', pasado: false }, 'el cierre del lunes siguiente')
igual(d.graciaDias, 2, 'los días de gracia')

console.log('── Las clínicas ───────────────────────────────────────────────')
igual(
  d.locales.map((l) => l.nombre),
  ['La Quinta Bar', 'El Marchante', 'Nueva Clínica', 'Sin Financiamientos'],
  'de más a menos financiamiento, aunque lleguen desordenados',
)
const em = d.locales.find((l) => l.merchantId === 'em')
igual(em?.consumoUsd, 364, 'un financiamiento que llega como texto se lee')
igual(em?.vencido, { payableUsd: 72.56, financedUsd: 58.9, feeUsd: 13.66, cuotas: 4, personas: 3 }, 'lo vencido, con sus dos partes')
igual(em?.aTiempo, { vencen: 10, juzgadas: 9, aTiempo: 7, pct: 77.8 }, 'las cuotas de la semana y su veredicto')
igual(
  em?.transferencia,
  { generadoUsd: 150, transferidoUsd: 0, pendienteUsd: 150, previstoUsd: 117.5, atrasadoUsd: 40 },
  'el cierre del lunes, con lo atrasado aparte',
)
igual(em?.mejorNoche, { fecha: '2026-09-25', consumoUsd: 180 }, 'la mejor día')
const sv = d.locales.find((l) => l.merchantId === 'sv')
igual(sv?.ticketMedioUsd, null, 'sin financiamientos no hay ticket (nulo, no cero)')
igual(sv?.aTiempo.pct, null, 'sin cuotas juzgadas no hay porcentaje')
igual(sv?.mejorNoche, null, 'sin financiamientos no hay mejor día')

console.log('── Todos ─────────────────────────────────────────────────────')
igual([d.totales.merchantId, d.totales.estado], [null, null], 'la fila de todos no es una clínica')
igual(d.totales.personas, 47, 'los pacientes de todos son las recontadas, no la suma (50)')
igual(
  Math.round(d.locales.reduce((s, l) => s + l.consumoUsd, 0) * 100) / 100,
  d.totales.consumoUsd,
  'la suma del financiamiento por clínica es el de todos',
)

console.log('── Series y cohortes ─────────────────────────────────────────')
igual(d.series.semanas.length, 12, 'doce semanas')
igual(
  d.series.locales.every((s) => s.consumoUsd.length === 12 && s.personas.length === 12),
  true,
  'cada serie, con una cifra por semana',
)
igual(d.cohortes.semanas.length, 8, 'ocho semanas de cohortes')
const emCohortes = d.cohortes.locales.find((c) => c.merchantId === 'em')
igual(emCohortes?.semanas.map((s) => s.cuota1 === null), [true, true, true, true, true, false, false, false], 'una semana sin financiamientos es nula')
igual(emCohortes?.semanas[5]?.cuota1?.pctATiempo, 78.6, 'el porcentaje de una cohorte juzgada')
igual(emCohortes?.semanas[6]?.cuota1?.pctATiempo, null, 'sin juzgadas no hay porcentaje')

console.log('── Respuestas rotas ──────────────────────────────────────────')
const vacia = leerLocalesDeLaSemana(null)
igual([vacia.locales.length, vacia.series.locales.length, vacia.cohortes.locales.length], [0, 0, 0], 'una respuesta nula no rompe nada')
igual(vacia.totales.consumoUsd, 0, 'los totales de una respuesta vacía son cero')
const sinDesglose = leerFilaLocal({ nombre: 'X', vencido: { payable_usd: 10 } })
igual(
  [sinDesglose.vencido.payableUsd, sinDesglose.vencido.financedUsd],
  [0, 0],
  'lo vencido sin su financiamiento no se enseña a medias: se queda en cero',
)
const corta = leerLocalesDeLaSemana({
  series: { semanas: ['2026-09-07', '2026-09-14', '2026-09-21'], locales: [{ merchant_id: 'a', consumo_usd: [5] }] },
})
igual(corta.series.locales[0]?.consumoUsd, [0, 0, 5], 'una serie corta se completa por lo más viejo')

if (fallos > 0) {
  console.error(`\n${fallos} prueba(s) fallaron`)
  process.exit(1)
}
console.log('\nTodo bien.')
