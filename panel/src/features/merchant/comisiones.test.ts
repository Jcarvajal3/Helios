/**
 * Pruebas de las comisiones del personal.
 *
 *   npx tsx src/features/merchant/comisiones.test.ts
 */
import {
  agruparPorSemana,
  atajosDeComisiones,
  diaEnCaracas,
  leerComisiones,
  leerItemsDeComision,
  diaDePagoDeComision,
  lunesDe,
  rangoPorDefecto,
  semanasDelRango,
  totales,
} from './comisiones'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual<T>(dio: T, esperado: T, titulo: string) {
  comprueba(JSON.stringify(dio) === JSON.stringify(esperado), titulo, `dio ${JSON.stringify(dio)}`)
}

console.log('── lectores ──────────────────────────────────────────────────')
const filas = leerComisiones([
  { staff_user_id: 'u2', staff_name: 'Beatriz', charge_count: 3, amount_usd: '1.50', paid_usd: 1, pending_usd: '0.50' },
  { staff_user_id: 'u1', staff_name: 'Ana', charge_count: 7, amount_usd: 3.5, paid_usd: 2.5, pending_usd: 1 },
  { staff_user_id: 'u3', staff_name: null, charge_count: 0, amount_usd: 0 },
])
igual(filas.map((f) => f.staffName), ['Ana', 'Beatriz', 'Sin nombre'], 'de quien más ganó a quien menos')
igual(filas[1].amountUsd, 1.5, 'numeric como texto se lee')
igual(leerComisiones(null), [], 'una respuesta vacía es una lista vacía')

igual(
  totales(filas),
  { chargeCount: 10, amountUsd: 5, paidUsd: 3.5, pendingUsd: 1.5 },
  'los totales del rango',
)
igual(
  totales(leerComisiones([{ amount_usd: 0.1 }, { amount_usd: 0.2 }])).amountUsd,
  0.3,
  'sin la cola de coma flotante (0,1 + 0,2)',
)

const items = leerItemsDeComision([
  { charge_id: 'a', order_number: 1, created_at: '2026-09-28T13:00:00Z', amount_usd: 0.5, status: 'devengada', payout_id: null, paid_on: null },
  { charge_id: 'b', order_number: 2, created_at: '2026-09-22T02:30:00Z', amount_usd: 0.5, status: 'pagada', payout_id: 'p1', paid_on: '2026-09-28' },
  { charge_id: 'c', order_number: 3, created_at: '2026-09-29T15:00:00Z', amount_usd: 0.5, status: 'revertida' },
  { charge_id: 'd', order_number: 4, created_at: '2026-09-30T15:00:00Z', amount_usd: 0.5, status: 'rara' },
])
igual(items.map((i) => i.orderNumber), [4, 3, 1, 2], 'de la más reciente a la más antigua')
igual(items[0].status, null, 'un estado desconocido es null')

console.log('\n── semanas ───────────────────────────────────────────────────')
igual(lunesDe('2026-09-30'), '2026-09-28', 'el miércoles 30/09 es de la semana del lunes 28')
igual(lunesDe('2026-09-28'), '2026-09-28', 'un lunes es su propio lunes')
igual(lunesDe('2026-10-04'), '2026-09-28', 'el domingo cierra la semana')
igual(
  semanasDelRango({ from: '2026-09-17', to: '2026-09-30' }),
  [
    { from: '2026-09-28', to: '2026-09-30' },
    { from: '2026-09-21', to: '2026-09-27' },
    { from: '2026-09-17', to: '2026-09-20' },
  ],
  'las semanas del rango, recortadas y de la más reciente',
)
igual(semanasDelRango({ from: '2026-09-30', to: '2026-09-01' }), [], 'un rango al revés no tiene semanas')

// 2026-09-22T02:30Z son las 22:30 del lunes 21 en Caracas: su semana es la del 21.
igual(diaEnCaracas('2026-09-22T02:30:00Z'), '2026-09-21', 'el día de Caracas, no el de UTC')
const grupos = agruparPorSemana(items)
igual(grupos.map((g) => g.semana.from), ['2026-09-28', '2026-09-21'], 'agrupadas por su semana')
igual(grupos[0].amountUsd, 1, 'la revertida no suma (0,5 + 0,5 de la de estado raro)')
igual(grupos[0].pendingUsd, 0.5, 'por pagar: solo las devengadas')
igual(grupos[1].pendingUsd, 0, 'una semana ya pagada no tiene nada por pagar')

console.log('\n── día de pago ───────────────────────────────────────────────')
igual(
  diaDePagoDeComision({ createdAt: '2026-09-30T15:00:00Z', confirmedAt: null }),
  '2026-10-01',
  'se paga el día siguiente (sin cierre de los lunes)',
)
igual(
  diaDePagoDeComision({ createdAt: '2026-10-03T15:00:00Z', confirmedAt: null }),
  '2026-10-04',
  'un sábado se paga el domingo: el pago es diario',
)
igual(
  diaDePagoDeComision({ createdAt: '2026-09-22T02:30:00Z', confirmedAt: null }),
  '2026-09-22',
  'por el día de Caracas: las 22:30 del 21 se pagan el 22',
)
igual(
  diaDePagoDeComision({ createdAt: '2026-09-21T23:30:00Z', confirmedAt: '2026-09-22T04:10:00Z' }),
  '2026-09-23',
  'cuenta la confirmación, no el alta (confirmó pasada la medianoche del 22)',
)
igual(leerItemsDeComision([{ confirmed_at: '2026-09-22T04:10:00Z' }])[0].confirmedAt, '2026-09-22T04:10:00Z', 'lee confirmed_at')

console.log('\n── atajos ────────────────────────────────────────────────────')
const atajos = atajosDeComisiones('2026-09-30')
igual(atajos[0].rango, { from: '2026-09-28', to: '2026-09-30' }, 'esta semana')
igual(atajos[1].rango, { from: '2026-09-21', to: '2026-09-27' }, 'semana pasada')
igual(atajos[2].rango, { from: '2026-09-07', to: '2026-09-30' }, 'últimas 4 semanas')
igual(atajos[4].rango, { from: '2026-08-01', to: '2026-08-31' }, 'mes pasado')
igual(rangoPorDefecto('2026-09-30'), { from: '2026-09-07', to: '2026-09-30' }, 'por defecto, 4 semanas')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
