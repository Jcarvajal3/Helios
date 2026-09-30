/**
 * Pruebas de la ficha analítica de un local.
 *
 *   npx tsx src/features/admin/metricas/locales/ficha.test.ts
 *
 * Lo que se vigila: que la serie del gráfico lleve el consumo (sin fee)
 * y su nota, que las semanas de consumo vayan de la más nueva a la más vieja
 * con lo consumido de la serie.
 */
import { RESPUESTA_SEMANA } from './__fixtures__/semana'
import {
  cohortesDelLocal,
  puntosDelConsumo,
  serieDelLocal,
  ultimas,
} from './ficha'
import { leerLocalesDeLaSemana } from './lectura'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const d = leerLocalesDeLaSemana(RESPUESTA_SEMANA)

console.log('── La serie ──────────────────────────────────────────────────')
const serie = serieDelLocal(d, 'em')
igual(serie?.nombre, 'El Marchante', 'la serie de la clínica pedida')
igual(serieDelLocal(d, 'no-existe'), null, 'una clínica sin serie es nulo')
const puntos = serie ? puntosDelConsumo(d.series.semanas, serie) : []
igual(puntos.length, 12, 'un punto por semana')
igual(puntos.at(-1), { key: '2026-09-21', label: '21–27 sep', values: [364], note: '13 financiamientos · 19 pacientes' }, 'la última semana, con su nota')
igual(ultimas([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 8), [3, 4, 5, 6, 7, 8, 9, 10], 'la chispa lleva las últimas ocho')

console.log('── Cómo paga su gente ────────────────────────────────────────')
const coh = cohortesDelLocal(d, 'em')
igual(coh.map((c) => c.semana).slice(0, 3), ['2026-09-21', '2026-09-14', '2026-09-07'], 'de la más nueva a la más vieja')
igual([coh[1]?.consumoUsd, coh[1]?.personas], [303, 17], 'con lo financiado y la gente de la serie')
igual(coh.at(-1)?.cuota1, null, 'una semana sin financiamientos no tiene cuotas')
igual(cohortesDelLocal(d, 'no-existe'), [], 'una clínica sin cohortes no tiene filas')

if (fallos > 0) {
  console.error(`\n${fallos} prueba(s) fallaron`)
  process.exit(1)
}
console.log('\nTodo bien.')
