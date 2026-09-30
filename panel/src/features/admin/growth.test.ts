/**
 * Pruebas de la lectura de las métricas de la gente.
 *
 *   npx tsx src/features/admin/growth.test.ts
 *
 * Lo que se vigila: que sin local se lea todo como antes; que con un local lo
 * del padrón (registros, quien pidió el código, embudo, estados, grupos creados) llegue
 * como `null` y nunca como un cero; y que la Retención diga de dónde sale
 * cada cohorte.
 */
import {
  leerGrowthOverview,
  leerUserBehavior,
  leerUserCohorts,
} from './growth'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const LOCAL = '179b20df-8f9c-1a61-4927-f53fd545b218'

console.log('── El tablero ────────────────────────────────────────────────')
const todos = leerGrowthOverview({
  business_date: '2026-09-26',
  from: '2026-09-21',
  to: '2026-09-26',
  window_days: 6,
  previous_from: '2026-09-14',
  previous_to: '2026-09-19',
  merchant_id: null,
  registered: { count: 12, previous: 9 },
  verified: { count: 12, previous: 9 },
  requested: { count: 15, previous: 11 },
  activated: { count: 5, previous: 4 },
  active_users: { count: 54, previous: 47 },
  orders: { count: 43, previous: 48 },
  spend: { financed_usd: '1129.00', previous_usd: 1015.5, revenue_usd: 225.8, fee_usd: 261.93, per_user_usd: 20.9, per_order_usd: 26.26, orders_per_user: 0.8 },
  totals: { requested: 202, phone_confirmed: 194, registered: 162, onboarded: 156, ever_bought: 134, buyers_pct: 82.7 },
  series: [{ day: '2026-09-21', registered: 2, verified: 2, requested: 3, activated: 1, active_users: 9, orders: 7, financed_usd: 180 }],
})
igual(todos.registered, { count: 12, previous: 9 }, 'los registros, con la ventana anterior')
igual(todos.requested, { count: 15, previous: 11 }, 'quien pidió el código, aparte de los registros')
igual(
  [todos.totals.requested, todos.totals.phoneConfirmed, todos.totals.registered],
  [202, 194, 162],
  'del código al registro, desde el primer día',
)
igual(todos.series.map((d) => d.requested), [3], 'la serie trae quien pidió el código cada día')
igual(todos.spend.financedUsd, 1129, 'un numeric que llega como texto se lee')
igual(todos.previousFrom, '2026-09-14', 'la ventana contra la que se compara')
igual(todos.totals.buyersPct, 82.7, 'el padrón entero')

const conLocal = leerGrowthOverview({
  from: '2026-09-21',
  to: '2026-09-26',
  window_days: 6,
  merchant_id: LOCAL,
  registered: null,
  verified: null,
  requested: null,
  activated: { count: 3, previous: 2 },
  active_users: { count: 20, previous: 18 },
  orders: { count: 15, previous: 14 },
  spend: { financed_usd: 400 },
  totals: { requested: null, phone_confirmed: null, registered: null, onboarded: null, ever_bought: 61, buyers_pct: null },
  series: [{ day: '2026-09-21', registered: null, verified: null, activated: 1, active_users: 4, orders: 3, financed_usd: 60 }],
})
igual(conLocal.merchantId, LOCAL, 'la clínica que usó la base')
igual(conLocal.registered, null, 'con clínica, los registros no son un cero')
igual(conLocal.requested, null, 'ni quien pidió el código')
igual(conLocal.totals.requested, null, 'ni el total de quien pidió el código')
igual(conLocal.totals.registered, null, 'ni el padrón')
igual(conLocal.totals.everBought, 61, 'pero sí quien se ha financiado en la clínica')
igual(conLocal.series.map((d) => d.registered), [null], 'la serie tampoco inventa registros')

console.log('── El uso ────────────────────────────────────────────────────')
const uso = leerUserBehavior({
  merchant_id: LOCAL,
  active_users: 20,
  per_user: {},
  levels: [{ level: 1, users: null, active_users: 4, financed_usd: 80 }],
  statuses: null,
})
igual(uso.levels.map((l) => l.users), [null], 'con clínica, cuánta gente hay en el nivel no se sabe')
igual(uso.statuses, null, 'ni el padrón por estado')
igual(leerUserBehavior({ statuses: [] }).statuses, [], 'sin clínica, una lista vacía es una lista')

console.log('── La retención ──────────────────────────────────────────────')
igual(leerUserCohorts({ base: 'primera_visita', rows: [] }, 'week', 8).base, 'primera_visita', 'con clínica, desde la primera visita')
igual(leerUserCohorts({ rows: [] }, 'week', 8).base, 'registro', 'sin decirlo, desde el registro')
igual(leerUserCohorts({ grain: 'month', periods: 6 }, 'week', 8).grain, 'month', 'el cubo que usó la base')

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
