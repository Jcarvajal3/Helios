/**
 * Pruebas del periodo y la lectura de Métricas › Juan Pablo.
 *
 *   npx tsx src/features/admin/metricas/juan-pablo/periodo.test.ts
 *
 * Lo que se vigila: que sin fechas se mire hoy, que el futuro se recorte a
 * hoy, que hoy no se escriba en la URL, que los atajos cubran lo que dicen y
 * que la respuesta de la base se lea entera.
 */
import { validarJuanPablo } from './busqueda'
import { leerJuanPablo } from './lectura'
import { atajosDeJuanPablo, busquedaDelRango, rangoElegido } from './periodo'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const HOY = '2026-10-23' // un viernes

console.log('── El periodo ────────────────────────────────────────────────')
igual(rangoElegido({}, HOY), { from: HOY, to: HOY }, 'sin fechas, hoy')
igual(
  rangoElegido({ desde: '2026-10-01', hasta: '2026-10-15' }, HOY),
  { from: '2026-10-01', to: '2026-10-15' },
  'un rango cerrado, tal cual',
)
igual(
  rangoElegido({ desde: '2026-10-20', hasta: '2026-11-30' }, HOY),
  { from: '2026-10-20', to: HOY },
  'el futuro se recorta a hoy',
)
igual(rangoElegido({ desde: '2026-11-01', hasta: '2026-11-30' }, HOY), { from: HOY, to: HOY }, 'entero en el futuro, hoy')
igual(busquedaDelRango({ from: HOY, to: HOY }, HOY), { desde: undefined, hasta: undefined }, 'hoy no se escribe')
igual(
  busquedaDelRango({ from: '2026-10-19', to: HOY }, HOY),
  { desde: '2026-10-19', hasta: HOY },
  'lo demás, sí',
)

console.log('── La URL ────────────────────────────────────────────────────')
igual(validarJuanPablo({ desde: '2026-10-01', hasta: '2026-10-02' }), { desde: '2026-10-01', hasta: '2026-10-02' }, 'un periodo')
igual(validarJuanPablo({ desde: '2026-10-01' }), { desde: undefined, hasta: undefined }, 'medio periodo se cae')
igual(validarJuanPablo({ desde: '2026-10-05', hasta: '2026-10-01' }), { desde: undefined, hasta: undefined }, 'al revés se cae')
igual(validarJuanPablo({ desde: '2026-02-31', hasta: '2026-03-01' }), { desde: undefined, hasta: undefined }, 'un día que no existe se cae')

console.log('── Los atajos ────────────────────────────────────────────────')
const atajos = Object.fromEntries(atajosDeJuanPablo(HOY).map((a) => [a.label, a.rango]))
igual(atajos['Hoy'], { from: HOY, to: HOY }, 'hoy')
igual(atajos['Ayer'], { from: '2026-10-22', to: '2026-10-22' }, 'ayer')
igual(atajos['Esta semana'], { from: '2026-10-19', to: HOY }, 'esta semana, del lunes a hoy')
igual(atajos['Semana pasada'], { from: '2026-10-12', to: '2026-10-18' }, 'la pasada, de lunes a domingo')
igual(atajos['Este mes'], { from: '2026-10-01', to: HOY }, 'este mes')
igual(atajos['Mes pasado'], { from: '2026-09-01', to: '2026-09-30' }, 'el mes pasado, entero')
igual(atajos['Este año'], { from: '2026-01-01', to: HOY }, 'este año')

console.log('── La lectura ────────────────────────────────────────────────')
const leida = leerJuanPablo({
  desde: '2026-10-01',
  hasta: '2026-10-23',
  dias: 23,
  ordenes: 9,
  gtv_usd: 806.19,
  revenue_usd: 96.75,
  revenue_pct: 12,
  ticket_medio_usd: 89.58,
  medicos: { afiliados: 21, con_ordenes: 7, con_ordenes_pct: 33.33, ordenes_por_medico: 1.29 },
  por_medico: [
    { merchant_id: 'a', medico: 'Dra. Ana', clinica: 'Consultorio', ordenes: 2, pct: 22.22, gtv_usd: 200, revenue_usd: 24 },
  ],
})
igual(leida.ordenes, 9, 'las órdenes')
igual(leida.medicos, { afiliados: 21, conOrdenes: 7, conOrdenesPct: 33.33, ordenesPorMedico: 1.29 }, 'los médicos')
igual(leida.porMedico[0]?.medico, 'Dra. Ana', 'cada médico')
const vacia = leerJuanPablo({ desde: HOY, hasta: HOY, dias: 1, ordenes: 0, gtv_usd: 0, revenue_usd: 0, medicos: { afiliados: 21, con_ordenes: 0 }, por_medico: [] })
igual([vacia.revenuePct, vacia.ticketMedioUsd, vacia.medicos.ordenesPorMedico], [null, null, null], 'sin órdenes, sin divisiones')

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
