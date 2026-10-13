/**
 * Pruebas de los lectores de Financiamientos y del libro para contabilidad.
 *
 *   npx tsx src/features/merchant/financiamientos.test.ts
 */
import {
  formatTotalesPorMoneda,
  hayOtraMoneda,
  leerDetalle,
  leerFilaDeFinanciamiento,
  leerPorPersona,
  leerResumen,
} from './financiamientos'
import { COLUMNAS_VENTAS, leerFilaDeVentas, usdOEur } from './ventas'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual<T>(dio: T, esperado: T, titulo: string) {
  comprueba(JSON.stringify(dio) === JSON.stringify(esperado), titulo, `dio ${JSON.stringify(dio)}`)
}

console.log('── una fila de la lista ──────────────────────────────────────')
const fila = leerFilaDeFinanciamiento({
  charge_id: 'c1',
  order_number: 1042,
  business_date: '2026-10-01',
  confirmed_at: '2026-10-01T14:00:00Z',
  amount_usd: 123.2,
  merchant_sale_usd: '100.0000',
  customer_name: 'José Pérez',
  beneficiary_name: 'Juanito Pérez',
  concept: 'Consulta',
  registered_by_name: 'Ana',
  staff_name: 'otro nombre',
  receipt_status: 'rebotado',
  staff_commission_usd: '0.50',
  cuota_1_due: '2026-10-08',
  cuota_1_run: '2026-10-12',
  cuota_2_due: '2026-10-15',
  cuota_2_run: null,
})
igual(fila.merchantSaleUsd, 100, 'la consulta, sin el fee (no lee amount_usd)')
igual(fila.registeredBy, 'Ana', 'registered_by_name manda sobre staff_name')
igual(fila.receipt, 'rebotado', 'el estado del comprobante')
igual(fila.staffCommissionUsd, 0.5, 'la comisión')
igual(fila.cuotas, [{ dueDate: '2026-10-08', paidToMerchantOn: '2026-10-12' }, null], 'sin fecha de cobro no hay cuota')

const deRonda = leerFilaDeFinanciamiento({ charge_id: 'c2', order_number: 7, staff_name: 'Luis', merchant_sale_usd: 10 })
igual(deRonda.registeredBy, 'Luis', 'forma de Ronda: staff_name')
igual(deRonda.receipt, null, 'forma de Ronda: sin comprobante')
igual(deRonda.staffCommissionUsd, null, 'forma de Ronda: sin comisión (null, no 0)')
igual([fila.moneda, fila.merchantSaleCur], ['USD', 100], 'sin currency: dólares, la misma cifra')

const filaEnEuros = leerFilaDeFinanciamiento({
  charge_id: 'c5',
  order_number: 1050,
  merchant_sale_usd: '112.6000',
  currency: 'EUR',
  merchant_sale_cur: '100.0000',
})
igual([filaEnEuros.moneda, filaEnEuros.merchantSaleCur], ['EUR', 100], 'una fila en euros: la consulta en euros')

console.log('\n── resumen y por persona ─────────────────────────────────────')
igual(leerResumen({ scope: 'self', order_count: 3, sale_usd: '150', avg_ticket_usd: 50, active_days: 2 }).scope, 'self', 'scope self')
igual(leerResumen({ order_count: 3 }).scope, 'gerente', 'sin scope: la clínica entera')
const pp = leerPorPersona({
  scope: 'gerente',
  rows: [{ user_id: 'u1', name: 'Ana', role: 'cajero', is_active: true, is_self: false, order_count: 4, sale_usd: 400, commission_usd: '2.00' }],
})
igual(pp.rows[0].commissionUsd, 2, 'la comisión por persona')
igual(leerPorPersona({ rows: [] }).scope, 'self', 'sin scope: solo lo propio')
igual(leerPorPersona({ rows: [{ user_id: 'u', role: 'inventario' }] }).rows[0].role, null, 'un rol que no existe en Helios')

// $100 + €100 + $50: el total va por moneda, no los €100 pasados a dólares.
const mixto = leerResumen({
  sale_usd: '261.99',
  sale_by_currency: [{ currency: 'USD', sale: '150.00' }, { currency: 'EUR', sale: '100.00' }],
})
igual(formatTotalesPorMoneda(mixto.porMoneda, mixto.saleUsd), '$150,00 + €100,00', 'el total, cada moneda por su lado')
igual(hayOtraMoneda(mixto.porMoneda), true, 'con euros se da el equivalente')
const soloDolares = leerResumen({ sale_usd: 150, sale_by_currency: [{ currency: 'USD', sale: 150 }] })
igual(hayOtraMoneda(soloDolares.porMoneda), false, 'solo dólares: sin equivalente')
igual(formatTotalesPorMoneda(leerResumen({ sale_usd: 42 }).porMoneda, 42), '$42,00', 'base sin el reparto: el equivalente')
igual(
  leerPorPersona({ rows: [{ user_id: 'u', sale_by_currency: [{ currency: 'EUR', sale: 100 }] }] }).rows[0].porMoneda[0].moneda,
  'EUR',
  'el reparto por persona',
)

console.log('\n── la ficha ──────────────────────────────────────────────────')
const detalle = leerDetalle({
  charge_id: 'c1',
  order_number: 1042,
  status: 'confirmed',
  created_at: '2026-10-01T14:00:00Z',
  merchant_sale_usd: 100,
  amount_usd: 113.92,
  consumer_fee_usd: 12,
  consumer_fee_vat_usd: 1.92,
  is_gerente: true,
  customer_name: 'José Pérez',
  items: [{ name: 'Consulta y eco', quantity: 1, unit_price_usd: 100, line_total_usd: 100 }],
  receipt: { status: 'entregado', sent_at: '2026-10-01T14:01:00Z', last_event: 'delivered' },
  staff_commission_usd: 0.5,
  commission_staff_name: 'Ana',
  payouts: [
    { kind: 'installment', sequence: 2, due_date: '2026-10-15', run_date: '2026-10-16', amount_usd: 50, status: 'pending' },
    { kind: 'advance', sequence: null, due_date: '2026-10-01', run_date: '2026-10-02', amount_usd: 0 },
    { kind: 'installment', sequence: 1, due_date: '2026-10-08', run_date: '2026-10-09', amount_usd: 50, status: 'paid', paid_usd: 50 },
  ],
  // Aunque la base mandara el estado de pago del paciente, no pasa.
  installment_status: 'overdue',
})
igual(detalle.pagos.map((p) => p.sequence), [1, 2], 'las dos mitades en orden, sin el adelanto')
igual(detalle.pagos[0].paidToMerchantOn, '2026-10-09', 'run_date se lee como paid_to_merchant_on (el día siguiente al vencimiento)')
igual(detalle.concept, 'Consulta y eco', 'sin concept suelto, el nombre de la única línea')
igual(detalle.receipt, { status: 'entregado', sentAt: '2026-10-01T14:01:00Z', lastEvent: 'delivered' }, 'el comprobante')
igual(detalle.feePct, 12, 'el porcentaje de la comisión de servicio sale de sus cifras')
comprueba(!JSON.stringify(detalle).includes('overdue'), 'el estado de pago del paciente no llega a la ficha')

const nueva = leerDetalle({
  charge_id: 'c3',
  order_number: 1,
  created_at: 'x',
  merchant_sale_usd: 40,
  concept: 'Control',
  installments: [
    { sequence: 1, due_date: '2026-10-08', paid_to_merchant_on: '2026-10-09' },
    { sequence: 2, due_date: '2026-10-15', paid_to_merchant_on: '2026-10-16' },
  ],
  receipt_status: 'pendiente',
})
igual(nueva.pagos.length, 2, 'forma nueva: installments con paid_to_merchant_on')
igual(nueva.pagos[1].amountUsd, null, 'secretaria: sin importe de la transferencia')
igual(nueva.receipt?.status, 'pendiente', 'receipt_status suelto')
igual(nueva.status, 'confirmed', 'sin status: confirmado')
igual(detalle.pagos[0].amountCur, 50, 'forma de Ronda: el importe en la moneda, el de dólares')

// La forma de hoy: las fechas en `installments` y los importes en `payouts`,
// cada uno en la moneda de la orden; la comisión del personal en dólares.
const enEuros = leerDetalle({
  charge_id: 'c4',
  order_number: 1050,
  created_at: 'x',
  is_gerente: true,
  currency: 'EUR',
  merchant_sale_usd: 112.6,
  merchant_sale_cur: 100,
  consumer_fee_usd: 13.51,
  consumer_fee_vat_usd: 2.16,
  consumer_fee_cur: 12,
  consumer_fee_vat_cur: 1.92,
  installments: [
    { sequence: 1, due_date: '2026-10-14', run_date: '2026-10-15', paid_to_merchant_on: null },
    { sequence: 2, due_date: '2026-10-21', run_date: '2026-10-22', paid_to_merchant_on: null },
  ],
  payouts: [
    { kind: 'staff_commission', sequence: null, due_date: '2026-10-08', amount_usd: 0.5, currency: 'USD', amount_cur: 0.5 },
    { kind: 'installment', sequence: 2, due_date: '2026-10-21', amount_usd: 56.3, paid_usd: 0, status: 'pending', currency: 'EUR', amount_cur: 50, paid_cur: 0 },
    { kind: 'installment', sequence: 1, due_date: '2026-10-14', amount_usd: 56.3, paid_usd: 28, status: 'partial', currency: 'EUR', amount_cur: 50, paid_cur: 25 },
  ],
})
igual(
  [enEuros.moneda, enEuros.merchantSaleCur, enEuros.feeCur, enEuros.feeVatCur],
  ['EUR', 100, 12, 1.92],
  'la ficha en euros',
)
igual(
  enEuros.pagos.map((p) => [p.sequence, p.paidToMerchantOn, p.moneda, p.amountCur, p.paidCur, p.status]),
  [
    [1, '2026-10-15', 'EUR', 50, 25, 'partial'],
    [2, '2026-10-22', 'EUR', 50, 0, 'pending'],
  ],
  'cada mitad con el importe de su transferencia, en euros, y sin la comisión del personal',
)

console.log('\n── el libro para contabilidad ────────────────────────────────')
igual(usdOEur({ sale_usd: 10, sale_eur: 99 }, 'sale'), 10, 'prefiere _usd')
igual(usdOEur({ sale_eur: '12.5' }, 'sale'), 12.5, 'acepta _eur de Ronda')
igual(usdOEur({}, 'sale'), null, 'sin ninguno, null')

const venta = leerFilaDeVentas({
  order_number: 1042,
  charge_id: 'c1',
  business_date: '2026-10-01',
  cashier: 'Ana',
  status: 'confirmed',
  base_eur: 100,
  vat_eur: 0,
  sale_eur: 100,
  consumer_fee_eur: 12,
  charged_to_customer_eur: 113.92,
  net_to_merchant_eur: 100,
  settled_eur: 50,
  paid_eur: 0,
  receipt_status: 'enviado',
})
igual(venta.saleUsd, 100, 'la consulta desde sale_eur')
igual(venta.netToMerchantUsd, 100, 'el neto desde net_to_merchant_eur')
igual(venta.registeredBy, 'Ana', 'quien registró desde cashier')
comprueba(!JSON.stringify(venta).includes('113.92'), 'el total con la comisión de servicio del paciente no se lee')
const cabeceras = COLUMNAS_VENTAS.map((c) => c.header.toLowerCase()).join('|')
comprueba(
  !/cliente|consumer|servicio helios|comisi[oó]n de servicio/.test(cabeceras),
  'ninguna columna habla de la comisión de servicio del paciente',
)
comprueba(!/financ|lunes/.test(cabeceras), 'ninguna columna habla de financiamientos ni de lunes')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
