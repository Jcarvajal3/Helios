/**
 * Pruebas de «Cómo paga la gente de cada local».
 *
 *   npx tsx src/features/admin/metricas/locales/pago.test.ts
 *
 * Lo que se vigila: que sean las cuatro semanas ANTERIORES a la elegida, que
 * una semana sin ventas no se pinte como un 0 %, que una semana sin cuotas
 * juzgadas no tenga veredicto, y que el porcentaje sea el de las juzgadas.
 */
import { RESPUESTA_SEMANA } from './__fixtures__/semana'
import { leerLocalesDeLaSemana } from './lectura'
import { comoPagaLaGente } from './pago'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const d = leerLocalesDeLaSemana(RESPUESTA_SEMANA)
const p = comoPagaLaGente(d)

igual(p.semanas, ['2026-08-24', '2026-08-31', '2026-09-07', '2026-09-14'], 'las cuatro semanas antes de la elegida')
igual(p.filas.map((f) => f.merchantId), ['lq', 'em'], 'los que vendieron en ellas, en el orden de la tabla')

const lq = p.filas.at(0)
igual(
  lq?.celdas.map((c) => (c.estado === 'juzgada' ? c.pct : c.estado)),
  [78.3, 75, 72, 75],
  'La Quinta: el porcentaje de cada semana',
)
const parcial = lq?.celdas.at(3)
igual(
  parcial?.estado === 'juzgada' ? [parcial.juzgadas, parcial.cuotas, parcial.aTiempo] : null,
  [12, 30, 9],
  'una semana a medio juzgar dice cuántas se juzgaron',
)

const em = p.filas.at(1)
igual(
  em?.celdas.map((c) => c.estado),
  ['sin-ventas', 'sin-ventas', 'juzgada', 'sin-veredicto'],
  'El Marchante: sin financiamientos no es un 0 %, y sin juzgadas no hay veredicto',
)

const semanaVieja = comoPagaLaGente({ ...d, semana: { ...d.semana, desde: '2026-08-17' } })
igual(semanaVieja.semanas, ['2026-08-03', '2026-08-10'], 'si no hay cuatro semanas antes, las que haya')

if (fallos > 0) {
  console.error(`\n${fallos} prueba(s) fallaron`)
  process.exit(1)
}
console.log('\nTodo bien.')
