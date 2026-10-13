import { formatMoneda, leerMoneda } from '@/components/ui'
import type { Moneda } from '@/components/ui'
import { booleano, comoFila, filaONula, filas, numero, numeroONulo, texto, textoONulo } from '@/lib/json'

import { leerEstadoDelComprobante, porcentajeDelServicio } from './registro'
import type { EstadoDelComprobante } from './registro'

// ═══════════════════════════════════════════════════════════════════════════
// Los financiamientos de la clínica: la lista, sus cifras, el reparto por
// persona y la ficha de uno.
//
// Lectores puros de lo que devuelven las RPC heredadas de Ronda con la forma
// nueva de Helios (docs/01-CONTRATO-RPC §1.5):
//
//   merchant_transactions         + concept, beneficiary_name, receipt_status,
//                                   staff_commission_usd, registered_by_name
//   merchant_charge_detail        + concept, beneficiary_name, receipt,
//                                   staff_commission_usd, commission_staff_name
//   merchant_sales_by_staff       + commission_usd, sale_by_currency
//   merchant_transactions_summary + sale_by_currency
//
// Cada lector acepta también la forma de Ronda (sin los campos nuevos): así
// el panel no se cae contra una base a la que todavía no le llegó la
// migración, solo enseña menos.
//
// Lo que NO hay aquí, a propósito: el estado de pago de las cuotas del
// paciente. Cómo va esa deuda es asunto entre el paciente y Helios; a la
// clínica se le paga por fecha, haya pagado su paciente o no (plan §8.2).
//
// La moneda (2026-10-07): cada orden se cobra en dólares o en euros, y la
// fila y la ficha se enseñan en esa moneda (`merchant_sale_cur`, `*_cur`).
// El total del rango y el reparto por persona se enseñan por moneda
// («$150,00 + €100,00», `sale_by_currency`), como la lista: los euros
// pasados a dólares daban un total que no cuadraba con lo que se ve debajo.
// El equivalente en dólares (`sale_usd`) queda de pista y para el promedio.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Lo que se dice junto a una suma de consultas: que va en dólares aunque
 * alguna se cobrara en euros.
 */
export const EQUIVALENTE_EN_DOLARES =
  'Equivalente en dólares: las consultas en euros se suman pasadas a dólares, a la tasa BCV del día en que se registraron.'

/** Lo registrado en una moneda, tal como se registró. */
export type TotalEnMoneda = { moneda: Moneda; monto: number }

/** `sale_by_currency` de la base: `[{currency, sale}]`, el dólar primero. */
export function leerTotalesPorMoneda(v: unknown): TotalEnMoneda[] {
  return filas(v).map((f) => ({ moneda: leerMoneda(f.currency), monto: numero(f.sale) }))
}

/**
 * «$150,00 + €100,00»: cada moneda por su lado, como se ven las órdenes en
 * la lista. Una base que aún no manda el reparto (o un rango vacío) cae al
 * equivalente en dólares.
 */
export function formatTotalesPorMoneda(totales: TotalEnMoneda[], respaldoUsd: number): string {
  if (totales.length === 0) return formatMoneda(respaldoUsd, 'USD')
  return totales.map((t) => formatMoneda(t.monto, t.moneda)).join(' + ')
}

/** Si alguna orden del total no es en dólares: entonces se da el equivalente. */
export function hayOtraMoneda(totales: TotalEnMoneda[]): boolean {
  return totales.some((t) => t.moneda !== 'USD')
}

/**
 * Cuándo cobra la clínica una de las dos mitades de un pago en cuotas.
 *
 * `paidToMerchantOn` es el día en que Helios paga esa mitad —el siguiente al
 * vencimiento de la cuota— y lo calcula la base (`helios_settlement_run_for`):
 * el calendario de pagos vive en un solo sitio.
 */
export type CuotaDeLaClinica = { dueDate: string; paidToMerchantOn: string } | null

function cuota(due: unknown, run: unknown): CuotaDeLaClinica {
  const dueDate = textoONulo(due)
  const paidToMerchantOn = textoONulo(run)
  // Sin vencimiento no hay cuota, y sin fecha de cobro no hay nada que decir.
  if (dueDate === null || paidToMerchantOn === null) return null
  return { dueDate, paidToMerchantOn }
}

/** Una fila de la lista. */
export type FilaDeFinanciamiento = {
  id: string
  orderNumber: number
  /** Día operativo: de medianoche a medianoche en Caracas. */
  businessDate: string
  confirmedAt: string | null
  /** La moneda en la que se cobró. */
  moneda: Moneda
  /** La consulta: lo que se le paga a la clínica. Nunca lleva el fee. En dólares. */
  merchantSaleUsd: number
  /** La misma consulta en la moneda de la orden: lo que se enseña. */
  merchantSaleCur: number
  /** El titular: solo su nombre, sin cédula ni teléfono. */
  patientName: string | null
  /** Quien se atendió, si no es el titular. */
  beneficiaryName: string | null
  concept: string | null
  /**
   * Quién de la clínica lo registró. Null cuando quien mira no puede saberlo
   * (una secretaria, en los de otra; aunque hoy la base ya no se los manda).
   */
  registeredBy: string | null
  receipt: EstadoDelComprobante | null
  /** La comisión de quien lo registró. Null si la base no la manda. */
  staffCommissionUsd: number | null
  cuotas: [CuotaDeLaClinica, CuotaDeLaClinica]
  /**
   * Con la confirmación del paciente la lista trae también las órdenes que
   * esperan su Sí, las que rechazó y las que vencieron (contrato §1.5). Solo
   * las confirmadas cuentan en las cifras.
   */
  status: EstadoDelFinanciamiento
  /** Hasta cuándo espera la orden el Sí. Solo en pending y expired. */
  expiresAt: string | null
}

export function leerFilaDeFinanciamiento(v: unknown): FilaDeFinanciamiento {
  const r = comoFila(v)
  const venta = numero(r.merchant_sale_usd)
  return {
    id: texto(r.charge_id ?? r.id),
    orderNumber: numero(r.order_number),
    businessDate: texto(r.business_date),
    confirmedAt: textoONulo(r.confirmed_at),
    moneda: leerMoneda(r.currency),
    merchantSaleUsd: venta,
    // Una base sin la moneda: la orden es en dólares, la misma cifra.
    merchantSaleCur: numeroONulo(r.merchant_sale_cur) ?? venta,
    patientName: textoONulo(r.customer_name) ?? textoONulo(r.patient_name),
    beneficiaryName: textoONulo(r.beneficiary_name),
    concept: textoONulo(r.concept),
    registeredBy: textoONulo(r.registered_by_name) ?? textoONulo(r.staff_name),
    receipt: leerEstadoDelComprobante(r.receipt_status),
    staffCommissionUsd: numeroONulo(r.staff_commission_usd),
    cuotas: [cuota(r.cuota_1_due, r.cuota_1_run), cuota(r.cuota_2_due, r.cuota_2_run)],
    status: ESTADOS.find((e) => e === r.status) ?? 'confirmed',
    expiresAt: textoONulo(r.expires_at),
  }
}

/** Tope de filas por consulta, como en Ronda. Los totales van aparte y enteros. */
export const LIMITE_DE_FILAS = 500

// ── Las cifras del rango ──────────────────────────────────────────────────

export type ResumenDeFinanciamientos = {
  /**
   * De quién son las cifras. Lo dice el SERVIDOR: con `self` son las de quien
   * mira (una secretaria), no las de la clínica. Una base que no lo manda
   * cuenta la clínica entera, así que la ausencia se lee `gerente`.
   */
  scope: 'gerente' | 'self'
  count: number
  saleUsd: number
  /** Lo mismo que `saleUsd`, en la moneda de cada orden. */
  porMoneda: TotalEnMoneda[]
  avgTicketUsd: number
  activeDays: number
}

export function leerResumen(v: unknown): ResumenDeFinanciamientos {
  const r = comoFila(v)
  return {
    scope: r.scope === 'self' ? 'self' : 'gerente',
    count: numero(r.order_count),
    saleUsd: numero(r.sale_usd),
    porMoneda: leerTotalesPorMoneda(r.sale_by_currency),
    avgTicketUsd: numero(r.avg_ticket_usd),
    activeDays: numero(r.active_days),
  }
}

// ── Por persona ───────────────────────────────────────────────────────────

export type RegistroPorPersona = {
  userId: string
  name: string
  role: 'gerente' | 'cajero' | null
  isActive: boolean
  isSelf: boolean
  count: number
  saleUsd: number
  porMoneda: TotalEnMoneda[]
  /** Lo que ganó en comisiones en el rango. Null si la base no lo manda. */
  commissionUsd: number | null
  lastAt: string | null
}

export type PorPersona = { scope: 'gerente' | 'self'; rows: RegistroPorPersona[] }

export function leerPorPersona(v: unknown): PorPersona {
  const r = comoFila(v)
  return {
    // Al revés que el resumen: sin `scope` se asume lo menos, la fila propia.
    scope: r.scope === 'gerente' ? 'gerente' : 'self',
    rows: filas(r.rows).map((f) => ({
      userId: texto(f.user_id),
      name: textoONulo(f.name) ?? 'Sin nombre',
      role: f.role === 'gerente' || f.role === 'cajero' ? f.role : null,
      isActive: booleano(f.is_active),
      isSelf: booleano(f.is_self),
      count: numero(f.order_count),
      saleUsd: numero(f.sale_usd),
      porMoneda: leerTotalesPorMoneda(f.sale_by_currency),
      commissionUsd: numeroONulo(f.commission_usd),
      lastAt: textoONulo(f.last_sale_at),
    })),
  }
}

// ── La ficha de uno ───────────────────────────────────────────────────────

export type EstadoDelFinanciamiento =
  | 'pending'
  | 'confirmed'
  | 'declined'
  | 'expired'
  | 'voided'
  | 'reverted'

/**
 * Una de las dos mitades en que Helios le paga el pago en cuotas a la
 * clínica, con la fecha de vencimiento de la cuota del paciente que la
 * origina. Sin el estado de esa cuota: eso es del paciente con Helios.
 *
 * `amount*`, `paid*` y `status` son de la TRANSFERENCIA a la clínica, no
 * del pago del paciente, y solo los ve el administrador (la base los manda
 * en null a una secretaria). Los `Cur` van en `moneda`, la de la orden: lo
 * que se enseña.
 */
export type PagoALaClinica = {
  sequence: number | null
  dueDate: string
  paidToMerchantOn: string
  moneda: Moneda
  amountUsd: number | null
  paidUsd: number | null
  amountCur: number | null
  paidCur: number | null
  status: 'pending' | 'paid' | 'partial' | 'cancelled' | null
}

export type ComprobanteDeFinanciamiento = {
  status: EstadoDelComprobante | null
  sentAt: string | null
  /** El último evento del proveedor de correo, tal cual («delivered», «bounced»). */
  lastEvent: string | null
}

export type DetalleDeFinanciamiento = {
  id: string
  orderNumber: number
  status: EstadoDelFinanciamiento
  businessDate: string | null
  createdAt: string
  confirmedAt: string | null
  voidReason: string | null
  isTest: boolean
  /** La moneda en la que se cobró; los `Cur` van en ella. */
  moneda: Moneda
  merchantSaleUsd: number
  merchantSaleCur: number
  feePct: number
  feeUsd: number | null
  feeVatUsd: number | null
  feeCur: number | null
  feeVatCur: number | null
  isGerente: boolean
  branchName: string | null
  patientName: string | null
  beneficiaryName: string | null
  concept: string | null
  registeredBy: string | null
  receipt: ComprobanteDeFinanciamiento | null
  staffCommissionUsd: number | null
  commissionStaffName: string | null
  pagos: PagoALaClinica[]
}

const ESTADOS: readonly EstadoDelFinanciamiento[] = [
  'pending',
  'confirmed',
  'declined',
  'expired',
  'voided',
  'reverted',
]
const ESTADOS_DEL_PAGO = ['pending', 'paid', 'partial', 'cancelled'] as const

/**
 * Una mitad. Las fechas salen de `f`; el importe y el estado, de su
 * transferencia (`t`, la línea de `payouts`), que con la forma de Ronda es
 * la misma fila.
 */
function leerPago(
  f: Record<string, unknown>,
  t: Record<string, unknown> | undefined,
  monedaDeLaOrden: Moneda,
): PagoALaClinica | null {
  const dueDate = textoONulo(f.due_date)
  const paidToMerchantOn = textoONulo(f.paid_to_merchant_on) ?? textoONulo(f.run_date)
  if (dueDate === null || paidToMerchantOn === null) return null
  const amountUsd = numeroONulo(t?.amount_usd)
  const paidUsd = numeroONulo(t?.paid_usd)
  return {
    sequence: numeroONulo(f.sequence),
    dueDate,
    paidToMerchantOn,
    moneda: t?.currency ? leerMoneda(t.currency) : monedaDeLaOrden,
    amountUsd,
    paidUsd,
    amountCur: numeroONulo(t?.amount_cur) ?? amountUsd,
    paidCur: numeroONulo(t?.paid_cur) ?? paidUsd,
    status: ESTADOS_DEL_PAGO.find((e) => e === t?.status) ?? null,
  }
}

export function leerDetalle(v: unknown): DetalleDeFinanciamiento {
  const r = comoFila(v)
  const sucursal = filaONula(r.branch)
  const recibo = filaONula(r.receipt)
  const lineas = filas(r.items)

  const moneda = leerMoneda(r.currency)

  // Las mitades: `installments` si la base ya las manda con la forma nueva
  // (con `paid_to_merchant_on`), o las `payouts` de Ronda. Un adelanto al
  // vender no existe en Helios (0 % por adelantado) y no se enseña. Con la
  // forma nueva, el importe de cada mitad está en su línea de `payouts`, la
  // de la misma cuota.
  const transferencias = filas(r.payouts).filter((t) => t.kind === 'installment')
  const nueva = Array.isArray(r.installments)
  const origen = nueva ? filas(r.installments) : filas(r.payouts)
  const pagos = origen
    .filter((f) => f.kind === undefined || f.kind === 'installment')
    .map((f) =>
      leerPago(
        f,
        nueva
          ? transferencias.find(
              (t) => numeroONulo(t.sequence) !== null && numeroONulo(t.sequence) === numeroONulo(f.sequence),
            )
          : f,
        moneda,
      ),
    )
    .filter((p): p is PagoALaClinica => p !== null)
    .sort((a, b) => a.dueDate.localeCompare(b.dueDate))

  const base = numero(r.merchant_sale_usd)
  const fee = numeroONulo(r.consumer_fee_usd)
  const feeVat = numeroONulo(r.consumer_fee_vat_usd)

  return {
    id: texto(r.charge_id ?? r.id),
    orderNumber: numero(r.order_number),
    status: ESTADOS.find((e) => e === r.status) ?? 'confirmed',
    businessDate: textoONulo(r.business_date),
    createdAt: texto(r.created_at),
    confirmedAt: textoONulo(r.confirmed_at),
    voidReason: textoONulo(r.void_reason),
    isTest: booleano(r.is_test),
    moneda,
    merchantSaleUsd: base,
    merchantSaleCur: numeroONulo(r.merchant_sale_cur) ?? base,
    feePct: numeroONulo(r.consumer_fee_pct) ?? porcentajeDelServicio(base, fee),
    feeUsd: fee,
    feeVatUsd: feeVat,
    feeCur: numeroONulo(r.consumer_fee_cur) ?? fee,
    feeVatCur: numeroONulo(r.consumer_fee_vat_cur) ?? feeVat,
    isGerente: booleano(r.is_gerente),
    branchName: sucursal ? textoONulo(sucursal.name) : null,
    patientName: textoONulo(r.customer_name) ?? textoONulo(r.patient_name),
    beneficiaryName: textoONulo(r.beneficiary_name),
    // En Helios el concepto es la única línea del financiamiento: si la base
    // no lo manda suelto, es el nombre de esa línea.
    concept: textoONulo(r.concept) ?? (lineas.length === 1 ? textoONulo(lineas[0].name) : null),
    registeredBy: textoONulo(r.registered_by_name) ?? textoONulo(r.staff_name),
    receipt: recibo
      ? {
          status: leerEstadoDelComprobante(recibo.status),
          sentAt: textoONulo(recibo.sent_at),
          lastEvent: textoONulo(recibo.last_event),
        }
      : textoONulo(r.receipt_status)
        ? { status: leerEstadoDelComprobante(r.receipt_status), sentAt: null, lastEvent: null }
        : null,
    staffCommissionUsd: numeroONulo(r.staff_commission_usd),
    commissionStaffName: textoONulo(r.commission_staff_name),
    pagos,
  }
}

/** Cómo se ve el estado del pago en cuotas en su ficha. */
export const ESTADO_DEL_FINANCIAMIENTO: Record<
  EstadoDelFinanciamiento,
  { texto: string; tone: 'success' | 'warning' | 'error' | 'neutral' }
> = {
  confirmed: { texto: 'Confirmado', tone: 'success' },
  pending: { texto: 'Esperando al paciente', tone: 'warning' },
  declined: { texto: 'Rechazado', tone: 'error' },
  expired: { texto: 'Vencido', tone: 'neutral' },
  voided: { texto: 'Anulado', tone: 'error' },
  reverted: { texto: 'Revertido', tone: 'neutral' },
}

/** El estado de la transferencia de una mitad a la clínica. */
export const ESTADO_DEL_PAGO: Record<
  NonNullable<PagoALaClinica['status']>,
  { texto: string; tone: 'success' | 'warning' | 'neutral' }
> = {
  pending: { texto: 'Por transferir', tone: 'warning' },
  partial: { texto: 'Transferida en parte', tone: 'warning' },
  paid: { texto: 'Transferida', tone: 'success' },
  cancelled: { texto: 'Cancelada', tone: 'neutral' },
}
