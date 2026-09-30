/**
 * Pruebas del reparto de los pagos a la clínica en consultas y comisiones.
 *
 *   npx tsx src/features/merchant/pagos.test.ts
 */
import {
  agruparLineas,
  conceptoDe,
  leerLineaDeTransferencia,
  leerPrevision,
  leerTransferencia,
  repartir,
} from './pagos'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual<T>(dio: T, esperado: T, titulo: string) {
  comprueba(JSON.stringify(dio) === JSON.stringify(esperado), titulo, `dio ${JSON.stringify(dio)}`)
}

console.log('── conceptos ─────────────────────────────────────────────────')
igual(conceptoDe('staff_commission'), 'comisiones', 'la comisión del personal')
igual(conceptoDe('scheduled_installment'), 'consultas', 'la cuota por fecha es consulta')
igual(conceptoDe(null), 'consultas', 'sin motivo, consulta')
igual(
  repartir([
    { motivo: 'scheduled_installment', amountUsd: 50 },
    { motivo: 'staff_commission', amountUsd: 0.5 },
    { motivo: 'staff_commission', amountUsd: 0.5 },
    { motivo: 'scheduled_installment', amountUsd: 30.1 },
  ]),
  { consultasUsd: 80.1, comisionesUsd: 1 },
  'reparte en consultas y comisiones',
)

console.log('\n── previsión ─────────────────────────────────────────────────')
const sinReparto = leerPrevision({
  today_date: '2026-09-30',
  next_run_date: '2026-10-05',
  next_run_usd: '150.50',
  total_pending_usd: 300,
})
igual(sinReparto.nextRunUsd, 150.5, 'lo del lunes')
igual(sinReparto.nextRun, null, 'sin reparto de la base, no se inventa')
igual(
  leerPrevision({ next_run_consultas_usd: 150, next_run_comisiones_usd: '0.50' }).nextRun,
  { consultasUsd: 150, comisionesUsd: 0.5 },
  'con reparto de la base',
)

console.log('\n── transferencias ────────────────────────────────────────────')
const conColumnas = leerTransferencia({
  id: 'p1',
  amount_usd: 101,
  method: 'pago_movil',
  created_at: '2026-09-28T14:00:00Z',
  consultas_usd: 100,
  comisiones_usd: 1,
  merchant_payout_items: [{ amount_usd: 100 }, { amount_usd: 1 }],
})
igual(conColumnas.reparto, { consultasUsd: 100, comisionesUsd: 1 }, 'el reparto de la transferencia manda')
igual(conColumnas.itemCount, 2, 'cuenta las líneas')

const sumando = leerTransferencia({
  id: 'p2',
  amount_usd: 51,
  merchant_payout_items: [
    { amount_usd: 50, settlements: { reason: 'scheduled_installment' } },
    { amount_usd: 0.5, reason: 'staff_commission', settlements: { reason: 'staff_commission' } },
    { amount_usd: 0.5, settlements: { reason: 'staff_commission' } },
  ],
})
igual(sumando.reparto, { consultasUsd: 50, comisionesUsd: 1 }, 'sin columnas, sumando las líneas por su motivo')

const aMedias = leerTransferencia({
  id: 'p3',
  amount_usd: 51,
  merchant_payout_items: [
    { amount_usd: 50, settlements: { reason: 'scheduled_installment' } },
    { amount_usd: 1, settlements: null },
  ],
})
igual(aMedias.reparto, null, 'una línea sin motivo: no hay reparto (mejor nada que a medias)')
igual(leerTransferencia({ id: 'p4', merchant_payout_items: [{ count: 7 }] }).itemCount, 7, 'con la cuenta embebida')

console.log('\n── líneas de una transferencia ───────────────────────────────')
const lineas = [
  { amount_usd: 50, settlements: { id: 's1', reason: 'scheduled_installment', due_date: '2026-09-22', business_date: '2026-09-15' } },
  { amount_usd: 20, settlements: { id: 's2', reason: 'scheduled_installment', due_date: '2026-09-23', business_date: '2026-09-15' } },
  { amount_usd: 30, settlements: { id: 's3', reason: 'scheduled_installment', due_date: '2026-09-24', business_date: '2026-09-17' } },
  { amount_usd: 0.5, settlements: { id: 's4', reason: 'staff_commission', due_date: '2026-09-21', business_date: '2026-09-21' } },
  { amount_usd: 0.5, settlements: { id: 's5', reason: 'staff_commission', due_date: '2026-09-22', business_date: '2026-09-22' } },
  { amount_usd: 9, settlements: null },
]
  .map(leerLineaDeTransferencia)
  .filter((l) => l !== null)
igual(lineas.length, 5, 'una línea sin liquidación se descarta')
igual(
  agruparLineas(lineas),
  [
    { concepto: 'consultas', businessDate: '2026-09-15', count: 2, amountUsd: 70 },
    { concepto: 'consultas', businessDate: '2026-09-17', count: 1, amountUsd: 30 },
    { concepto: 'comisiones', businessDate: null, count: 2, amountUsd: 1 },
  ],
  'consultas por día y las comisiones juntas al final',
)

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
