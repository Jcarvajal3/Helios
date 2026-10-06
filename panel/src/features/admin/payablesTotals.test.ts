/**
 * Pruebas de lo que se les debe a los locales: lo que sale hoy, lo atrasado y lo
 * comprometido a futuro.
 *
 *   npx tsx src/features/admin/payablesTotals.test.ts
 *
 * `next_run_usd` (de `helios_settlement_outlook`) ya incluye lo atrasado. Hasta
 * el 27-09 se le sumaba otra vez: el semáforo del pago de Inicio pedía más
 * dinero del que salía y «comprometido a futuro» salía corto. El caso es el de
 * Galpón en dev: 533,00 € en el cierre, 279,25 € de ellos atrasados.
 */
import type { MerchantPayable } from './api'
import { comprometidoFuturoDe, payablesTotals } from './definitions'

let fallos = 0
function igual(obtenido: number, esperado: number, que: string) {
  const ok = Math.abs(obtenido - esperado) < 0.005
  if (!ok) fallos++
  console.log(`${ok ? '  ok   ' : ' FALLA '} ${que}${ok ? '' : ` — dio ${obtenido}, se esperaba ${esperado}`}`)
}

function local(parcial: Partial<MerchantPayable>): MerchantPayable {
  return {
    merchantId: 'x',
    merchantName: 'Clínica',
    taxId: null,
    isTest: false,
    todayDate: '2026-09-26',
    nextRunDate: '2026-09-28',
    nextRunUsd: 0,
    accruedUsd: 0,
    accruedCount: 0,
    overdueUsd: 0,
    oldestDueDate: null,
    upcomingUsd: 0,
    totalPendingUsd: 0,
    lastPayoutOn: null,
    lastPayoutUsd: null,
    ...parcial,
  }
}

const galpon = local({ nextRunUsd: 533, overdueUsd: 279.25, totalPendingUsd: 903.5, upcomingUsd: 370.5 })
const bar = local({ merchantId: 'y', nextRunUsd: 120, overdueUsd: 0, totalPendingUsd: 615, upcomingUsd: 495 })
const prueba = local({ merchantId: 'z', isTest: true, nextRunUsd: 999, overdueUsd: 999, totalPendingUsd: 999 })

console.log('\n── Una clínica con atraso ───────────────────────────────────────')
igual(comprometidoFuturoDe(galpon), 370.5, 'lo comprometido a futuro es lo pendiente menos lo que sale hoy')

console.log('\n── Todas las clínicas ─────────────────────────────────────────')
const t = payablesTotals([galpon, bar, prueba])
igual(t.saleEsteCierre, 653, 'lo que sale hoy no suma lo atrasado dos veces')
igual(t.atrasado, 279.25, 'lo atrasado, una vez')
igual(t.comprometidoFuturo, 865.5, 'lo comprometido a futuro')
igual(t.totalPendiente, 1518.5, 'el total, sin la clínica de prueba')
igual(
  t.atrasado + (t.saleEsteCierre - t.atrasado) + t.comprometidoFuturo,
  t.totalPendiente,
  'atrasado + resto de lo de hoy + a futuro = total',
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
