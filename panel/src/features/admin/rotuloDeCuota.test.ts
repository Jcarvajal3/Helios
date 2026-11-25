/**
 * Pruebas del rótulo de una cuota (la inicial es la cuota 0).
 *
 *   npx tsx src/features/admin/rotuloDeCuota.test.ts
 */
import {
  cobradoDeLaOrden,
  cuotasDelPlan,
  cuotasDelPlanDe,
  esLaInicial,
  laCuota,
  pagaLaInicial,
  quePagaElPago,
  rotuloDeCuota,
  sinLaInicial,
} from './rotuloDeCuota'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

console.log('── El rótulo ─────────────────────────────────────────────────')
igual(rotuloDeCuota(0), 'Inicial', 'la cuota 0 es la inicial')
igual(rotuloDeCuota(0, 2), 'Inicial', 'la inicial no lleva «de N»')
igual(rotuloDeCuota(1), 'Cuota 1', 'sin plan, sin «de N»')
igual(rotuloDeCuota(2, 2), 'Cuota 2 de 2', 'con plan')
igual(rotuloDeCuota(null), 'Cuota', 'sin número')
igual(laCuota(0), 'la inicial', 'en una frase, la inicial')
igual(laCuota(1), 'la cuota 1', 'en una frase, la cuota 1')
igual(laCuota(null), 'una cuota', 'en una frase, sin número')
igual(esLaInicial(0), true, 'la 0 es la inicial')
igual(esLaInicial(null), false, 'null no es la inicial')

console.log('── El plan ───────────────────────────────────────────────────')
const conInicial = [{ sequence: 0 }, { sequence: 1 }, { sequence: 2 }]
const vieja = [{ sequence: 1 }, { sequence: 2 }]
igual(cuotasDelPlan(conInicial), 2, 'con inicial, el plan sigue siendo de 2')
igual(cuotasDelPlan(vieja), 2, 'una orden vieja, 2')
igual(sinLaInicial(conInicial).map((c) => c.sequence), [1, 2], 'sin la inicial quedan la 1 y la 2')

console.log('── Lo que dice la base (installments_total, down_payment_pct) ─')
igual(cuotasDelPlanDe(3, 50), 2, 'con inicial, 3 cuotas son un plan de 2')
igual(cuotasDelPlanDe(2, null), 2, 'sin inicial, 2')
igual(cuotasDelPlanDe(2, 0), 2, 'con 0 %, sin inicial')
igual(cobradoDeLaOrden({ pagadas: 1, total: 2, downPaymentPct: null }), '1 de 2', 'orden vieja')
igual(cobradoDeLaOrden({ pagadas: 0, total: 3, downPaymentPct: 50 }), 'Inicial sin pagar', 'espera la inicial')
igual(cobradoDeLaOrden({ pagadas: 1, total: 3, downPaymentPct: 50 }), 'Inicial + 0 de 2', 'activa, solo la inicial')
igual(cobradoDeLaOrden({ pagadas: 2, total: 3, downPaymentPct: 50 }), 'Inicial + 1 de 2', 'la inicial y la cuota 1')
igual(cobradoDeLaOrden({ pagadas: 0, total: 0, downPaymentPct: 50 }), null, 'sin cuotas (revertida), nada')

console.log('── Qué paga un pago reportado ─────────────────────────────────')
const pagoDeLaInicial = {
  purchases: [{ installmentsTotal: 3, downPaymentPct: 50, installments: [{ sequence: 0 }] }],
}
const pagoDeUnaCuota = {
  purchases: [{ installmentsTotal: 2, downPaymentPct: null, installments: [{ sequence: 1 }] }],
}
const pagoMixto = {
  purchases: [
    { installmentsTotal: 2, downPaymentPct: null, installments: [{ sequence: 2 }, { sequence: 1 }] },
    { installmentsTotal: 3, downPaymentPct: 50, installments: [{ sequence: 0 }] },
  ],
}
igual(pagaLaInicial(pagoDeLaInicial), true, 'la cuota 0 es una inicial')
igual(pagaLaInicial(pagoDeUnaCuota), false, 'una cuota de una orden vieja no lo es')
igual(pagaLaInicial(pagoMixto), true, 'basta con que una orden pague su inicial')
igual(pagaLaInicial({ purchases: [] }), false, 'sin órdenes, no')
igual(quePagaElPago(pagoDeLaInicial), 'Inicial', 'la inicial, sin «de N»')
igual(quePagaElPago(pagoDeUnaCuota), 'Cuota 1 de 2', 'una cuota del plan')
igual(quePagaElPago(pagoMixto), 'Inicial + Cuota 1 de 2 + Cuota 2 de 2', 'la inicial va primero')

if (fallos > 0) {
  console.error(`\n${fallos} prueba(s) fallaron`)
  process.exit(1)
}
console.log('\nTodo bien.')
