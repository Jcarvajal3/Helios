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
//   merchant_sales_by_staff       + commission_usd
//
// Cada lector acepta también la forma de Ronda (sin los campos nuevos): así
// el panel no se cae contra una base a la que todavía no le llegó la
// migración, solo enseña menos.
//
// Lo que NO hay aquí, a propósito: el estado de pago de las cuotas del
// paciente. Cómo va esa deuda es asunto entre el paciente y Helios; a la
// clínica se le paga por fecha, haya pagado su paciente o no (plan §8.2).
// ═══════════════════════════════════════════════════════════════════════════

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
  /** La consulta: lo que se le paga a la clínica. Nunca lleva el fee. */
  merchantSaleUsd: number
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
  return {
    id: texto(r.charge_id ?? r.id),
    orderNumber: numero(r.order_number),
    businessDate: texto(r.business_date),
    confirmedAt: textoONulo(r.confirmed_at),
    merchantSaleUsd: numero(r.merchant_sale_usd),
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
  avgTicketUsd: number
  activeDays: number
}

export function leerResumen(v: unknown): ResumenDeFinanciamientos {
  const r = comoFila(v)
  return {
    scope: r.scope === 'self' ? 'self' : 'gerente',
    count: numero(r.order_count),
    saleUsd: numero(r.sale_usd),
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
 * `amountUsd`, `paidUsd` y `status` son de la TRANSFERENCIA a la clínica, no
 * del pago del paciente, y solo los ve el administrador (la base los manda
 * en null a una secretaria).
 */
export type PagoALaClinica = {
  sequence: number | null
  dueDate: string
  paidToMerchantOn: string
  amountUsd: number | null
  paidUsd: number | null
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
  merchantSaleUsd: number
  feePct: number
  feeUsd: number | null
  feeVatUsd: number | null
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

function leerPago(f: Record<string, unknown>): PagoALaClinica | null {
  const dueDate = textoONulo(f.due_date)
  const paidToMerchantOn = textoONulo(f.paid_to_merchant_on) ?? textoONulo(f.run_date)
  if (dueDate === null || paidToMerchantOn === null) return null
  return {
    sequence: numeroONulo(f.sequence),
    dueDate,
    paidToMerchantOn,
    amountUsd: numeroONulo(f.amount_usd),
    paidUsd: numeroONulo(f.paid_usd),
    status: ESTADOS_DEL_PAGO.find((e) => e === f.status) ?? null,
  }
}

export function leerDetalle(v: unknown): DetalleDeFinanciamiento {
  const r = comoFila(v)
  const sucursal = filaONula(r.branch)
  const recibo = filaONula(r.receipt)
  const lineas = filas(r.items)

  // Las mitades: `installments` si la base ya las manda con la forma nueva
  // (con `paid_to_merchant_on`), o las `payouts` de Ronda. Un adelanto al
  // vender no existe en Helios (0 % por adelantado) y no se enseña.
  const origen = Array.isArray(r.installments) ? filas(r.installments) : filas(r.payouts)
  const pagos = origen
    .filter((f) => f.kind === undefined || f.kind === 'installment')
    .map(leerPago)
    .filter((p): p is PagoALaClinica => p !== null)
    .sort((a, b) => a.dueDate.localeCompare(b.dueDate))

  const base = numero(r.merchant_sale_usd)
  const fee = numeroONulo(r.consumer_fee_usd)

  return {
    id: texto(r.charge_id ?? r.id),
    orderNumber: numero(r.order_number),
    status: ESTADOS.find((e) => e === r.status) ?? 'confirmed',
    businessDate: textoONulo(r.business_date),
    createdAt: texto(r.created_at),
    confirmedAt: textoONulo(r.confirmed_at),
    voidReason: textoONulo(r.void_reason),
    isTest: booleano(r.is_test),
    merchantSaleUsd: base,
    feePct: numeroONulo(r.consumer_fee_pct) ?? porcentajeDelServicio(base, fee),
    feeUsd: fee,
    feeVatUsd: numeroONulo(r.consumer_fee_vat_usd),
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
