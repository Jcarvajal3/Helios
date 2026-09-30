import { supabase } from '@/lib/supabase'
import { resizeToThumbnail } from '@/features/admin/resizeImage'
import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'
import { unoDe } from '@/lib/busqueda'
import type { PayoutMethod } from '@/features/admin/liquidaciones'
import { leerConsultasYComisiones } from '@/features/admin/clinicas/clinicas'
import type { ConsultasYComisiones } from '@/features/admin/clinicas/clinicas'

export type PlatformRole = 'operador' | 'super_admin'

export type PlatformAdmin = {
  userId: string
  role: PlatformRole
  fullName: string | null
}

/**
 * Devuelve el contexto de super admin del usuario, o null si no lo es.
 *
 * La guardia real está en la base: `is_platform_admin()` la comprueban las
 * RLS y cada RPC. Esto solo evita enseñar un panel que fallaría al usarse.
 */
export async function fetchPlatformAdmin(): Promise<PlatformAdmin | null> {
  const { data, error } = await supabase
    .from('platform_admins')
    .select('user_id, role, full_name')
    .eq('is_active', true)
    .maybeSingle()

  if (error) throw error
  if (!data) return null

  return {
    userId: data.user_id as string,
    role: data.role as PlatformRole,
    fullName: (data.full_name as string | null) ?? null,
  }
}

export type PaymentReportStatus =
  | 'reported'
  | 'in_review'
  | 'reconciled'
  | 'rejected'
  | 'duplicate'

/**
 * Los cinco estados de un pago reportado, para cuando hace falta la cola
 * entera y no un tramo de ella. También es la lista con la que se valida el
 * estado que llega del servidor.
 */
export const ESTADOS_COLA: PaymentReportStatus[] = [
  'reported',
  'in_review',
  'reconciled',
  'rejected',
  'duplicate',
]

/** Una cuota que salda este pago, dentro de su compra. */
export type QueueInstallment = {
  installmentId: string
  sequence: number
  /**
   * El importe con el que la cuota entró en la cotización, congelado ese día.
   *
   * Es contra este —y no contra `amountUsd`— contra el que concilia el
   * servidor. Que difieran significa que la cuota cambió después de cotizar y
   * que el pago se va a rechazar solo: enseñarlo evita buscar el motivo a mano.
   */
  quotedUsd: number
  /**
   * El desglose de `quotedUsd`: facturado (sin fee) y service fee + IVA
   * (= cotizado − facturado). `null` en una base sin 20260927697000.
   */
  financedUsd?: number | null
  feeUsd?: number | null
  amountUsd: number
  dueDate: string
  status: 'pending' | 'paid'
  daysOverdue: number
  /** Otros reportes que también tocaron esta cuota (rechazados incluidos). */
  otherReports: number
}

/** La compra de la que salen las cuotas: es lo que el operador reconoce. */
export type QueuePurchase = {
  chargeId: string
  orderNumber: number | null
  merchantId: string
  merchantName: string
  branchName: string
  chargeAmountUsd: number
  chargeStatus: string
  businessDate: string | null
  confirmedAt: string | null
  /** Cuántas cuotas tiene la compra para ESTE usuario: el "de 2" del "1 de 2". */
  installmentsTotal: number
  installments: QueueInstallment[]
}

export type QueueLateFee = {
  lateFeeId: string
  amountUsd: number
  daysLate: number
  businessDate: string
  installmentId: string | null
  sequence: number | null
  orderNumber: number | null
  merchantName: string | null
  /**
   * El cargo de una cuota que ya no viaja en este pago —porque se pagó antes—
   * o uno del modelo por episodio, sin cuota. Va con el siguiente pago sea cual
   * sea, así que aparece "suelto" y hay que decir por qué.
   */
  orphan: boolean
}

export type QueueItem = {
  reportId: string
  status: PaymentReportStatus
  createdAt: string
  method: string
  bank: string | null
  reference: string | null
  payerDocument: string | null
  payerPhone: string | null
  note: string | null
  /** Cuándo se aprobó o rechazó. `null` mientras espera (también «en revisión»). */
  reviewedAt: string | null
  /** Quién lo decidió, o quién lo marcó para revisar si sigue abierto. */
  reviewedByName: string | null
  amountUsd: number
  amountVes: number
  fxRate: number
  installmentCount: number
  /** Lo que suman las cuotas. El resto del importe son cargos por mora. */
  installmentsUsd: number
  /**
   * La parte del importe que NO son cuotas: los cargos por mora que viajaban en
   * la cotización, sumados (docs/00-BASES §2.4). 0 en la mayoría.
   *
   * Desde el 2026-09-02 pueden ser varios —€2 por cada cuota retrasada—, así
   * que esto es un total y no un cargo suelto. Sin enseñarlo, el importe no
   * cuadra con ninguna suma de cuotas y el operador marca como sospechoso un
   * pago perfectamente correcto.
   */
  lateFeeUsd: number
  /**
   * El desglose de `installmentsUsd`: facturado (sin fee) de todas sus cuotas
   * y service fee + IVA. `null` en una base sin 20260927697000.
   */
  installmentsFinancedUsd?: number | null
  installmentsFeeUsd?: number | null
  userId: string
  fullName: string | null
  phone: string | null
  userDocument: string | null
  userStatus: string
  userLevel: number | null
  /**
   * Cuántos OTROS reportes no rechazados comparten banco + referencia.
   * Con referencias de 6 dígitos esto es sospecha, no prueba — ver
   * docs/00-BASES §3.7.
   */
  referenceCollisions: number
  /**
   * Movimientos del estado de cuenta importado que encajan con este reporte
   * (referencia + monto + fecha, las tres a la vez).
   *
   * 1 = verificado contra el banco. 0 = no aparece, o no se ha importado el
   * estado de cuenta de ese día. Más de 1 = mirarlo a mano.
   */
  statementMatches: number
  /**
   * De esos, los que todavía pueden respaldarlo: ni respaldan ya otro pago ni
   * se descartaron. Es lo que decide si el cotejo es verde.
   */
  statementMatchesAvailable: number
  /** El movimiento del extracto que respaldó la aprobación; `null` si ninguno. */
  statementLine: MovimientoDelExtracto | null
  /** Qué salda este pago, agrupado por compra. */
  purchases: QueuePurchase[]
  lateFees: QueueLateFee[]
}

/**
 * La cola de conciliación, con el árbol entero detrás de cada pago.
 *
 * Sale de una RPC y no de la vista `payment_queue` porque lo que hace falta no
 * es una fila: es pago → compras → cuotas, más los cargos por mora. Un pago sin
 * saber de qué compra viene, de qué cuota y de quién no se puede aprobar; solo
 * se puede firmar.
 */
export async function fetchPaymentQueue(
  statuses: PaymentReportStatus[],
  /**
   * Acota SOLO los resueltos (aprobados, rechazados, duplicados) por el día
   * operativo en que se revisaron. Los pendientes salen enteros siempre.
   * Cualquiera de los dos extremos puede faltar; al revés, la base responde
   * «El rango de fechas está al revés».
   */
  rango: { desde?: string; hasta?: string } = {},
): Promise<QueueItem[]> {
  const { data, error } = await supabase.rpc('admin_payment_queue', {
    p_statuses: statuses,
    p_from: rango.desde ?? null,
    p_to: rango.hasta ?? null,
  })

  if (error) throw error

  return comoLista(data).map(aQueueItem)
}

/**
 * Un pago de la cola, ya tipado.
 *
 * Lo usan la cola y la ficha (`admin_payment_report` devuelve exactamente un
 * elemento de la cola), así que las dos leen el pago con la misma función y
 * no pueden divergir.
 */
export function aQueueItem(raw: unknown): QueueItem {
  const row = comoFila(raw)
  const user = comoFila(row.user)

  return {
    reportId: String(row.report_id),
    status: unoDe(ESTADOS_COLA, row.status) ?? 'reported',
    createdAt: String(row.created_at),
    method: String(row.method),
    bank: textoONulo(row.bank),
    reference: textoONulo(row.reference),
    payerDocument: textoONulo(row.payer_document),
    payerPhone: textoONulo(row.payer_phone),
    note: textoONulo(row.rejection_note),
    reviewedAt: textoONulo(row.reviewed_at),
    reviewedByName: textoONulo(row.reviewed_by_name),
    amountUsd: Number(row.amount_usd),
    amountVes: Number(row.amount_ves),
    fxRate: Number(row.fx_rate),
    installmentCount: Number(row.installment_count),
    installmentsUsd: Number(row.installments_usd),
    lateFeeUsd: numeroONulo(row.late_fee_usd) ?? 0,
    installmentsFinancedUsd: numeroONulo(row.installments_financed_usd),
    installmentsFeeUsd: numeroONulo(row.installments_fee_usd),
    userId: String(user.user_id),
    fullName: textoONulo(user.full_name),
    phone: textoONulo(user.phone_e164),
    userDocument: textoONulo(user.document_number),
    userStatus: String(user.status),
    userLevel: numeroONulo(user.level),
    referenceCollisions: Number(row.reference_collisions),
    statementMatches: Number(row.statement_matches),
    // Sin el campo (una base sin la migración 145000), todos cuentan como libres.
    statementMatchesAvailable: numeroONulo(row.statement_matches_available) ?? Number(row.statement_matches),
    statementLine: leerMovimiento(row.statement_line),
    purchases: comoLista(row.purchases).map((compra) => {
      const p = comoFila(compra)
      return {
        chargeId: String(p.charge_id),
        orderNumber: numeroONulo(p.order_number),
        merchantId: String(p.merchant_id),
        merchantName: String(p.merchant_name),
        branchName: String(p.branch_name),
        chargeAmountUsd: Number(p.charge_amount_usd),
        chargeStatus: String(p.charge_status),
        businessDate: textoONulo(p.business_date),
        confirmedAt: textoONulo(p.confirmed_at),
        installmentsTotal: Number(p.installments_total),
        installments: comoLista(p.installments).map((cuota) => {
          const i = comoFila(cuota)
          return {
            installmentId: String(i.installment_id),
            sequence: Number(i.sequence),
            quotedUsd: Number(i.quoted_usd),
            financedUsd: numeroONulo(i.financed_usd),
            feeUsd: numeroONulo(i.fee_usd),
            amountUsd: Number(i.amount_usd),
            dueDate: String(i.due_date),
            status: i.status === 'paid' ? ('paid' as const) : ('pending' as const),
            daysOverdue: Number(i.days_overdue),
            otherReports: Number(i.other_reports),
          }
        }),
      }
    }),
    lateFees: comoLista(row.late_fees).map((cargo) => {
      const f = comoFila(cargo)
      return {
        lateFeeId: String(f.late_fee_id),
        amountUsd: Number(f.amount_usd),
        daysLate: Number(f.days_late),
        businessDate: String(f.business_date),
        installmentId: textoONulo(f.installment_id),
        sequence: numeroONulo(f.sequence),
        orderNumber: numeroONulo(f.order_number),
        merchantName: textoONulo(f.merchant_name),
        orphan: Boolean(f.orphan),
      }
    }),
  }
}

export async function reconcilePayment(params: {
  reportId: string
  approve: boolean
  note?: string
  /**
   * El movimiento del extracto que respalda la aprobación. Sin él, la base
   * liga el único candidato libre si lo hay; con varios, exige el motivo de
   * «aprobar sin cotejo».
   */
  statementLineId?: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_reconcile_payment', {
    p_report_id: params.reportId,
    p_approve: params.approve,
    p_note: params.note ?? null,
    p_statement_line_id: params.statementLineId ?? null,
  })
  if (error) throw error
}

export async function flagForReview(reportId: string, note: string): Promise<void> {
  const { error } = await supabase.rpc('admin_flag_for_review', {
    p_report_id: reportId,
    p_note: note,
  })
  if (error) throw error
}

// ── Comercios ──────────────────────────────────────────────────────────────

/**
 * Las categorías de una clínica (`merchant_category`). Los valores médicos
 * los añade la migración H8 (plan §4.4); los de Ronda (`discoteca`,
 * `conciertos`) siguen en el enum de la base pero el panel no los ofrece, y
 * si llegara uno se lee como «sin categoría».
 */
export type MerchantCategory = 'clinica' | 'consultorio' | 'odontologia' | 'laboratorio' | 'imagenes' | 'otros'

export const MERCHANT_CATEGORY_LABEL: Record<MerchantCategory, string> = {
  clinica: 'Clínica',
  consultorio: 'Consultorio',
  odontologia: 'Odontología',
  laboratorio: 'Laboratorio',
  imagenes: 'Imágenes',
  otros: 'Otros',
}

/** En el orden en que se ofrecen al dar de alta o editar una clínica. */
export const CATEGORIAS_CLINICA: ReadonlyArray<MerchantCategory> = [
  'clinica',
  'consultorio',
  'odontologia',
  'laboratorio',
  'imagenes',
  'otros',
]

/** Una categoría de la base, o `null` si no es de las de Helios. */
export function comoCategoria(v: unknown): MerchantCategory | null {
  return CATEGORIAS_CLINICA.find((c) => c === v) ?? null
}

export type MerchantRow = {
  id: string
  name: string
  legalName: string | null
  taxId: string | null
  status: 'active' | 'paused' | 'terminated'
  createdAt: string
  staffCount: number
  salesCount: number
  /** Los últimos 30 días. El total histórico no distingue al local que vende
   *  todas las noches del que vendió mucho hace un año y ya no abre. */
  sales30d: number
  financed30d: number
  /** La categoría médica, la ciudad y el logo (opcional). `handle` y
   *  `socialUrl` son columnas heredadas de Ronda, de la app que Helios no
   *  tiene: se leen pero no se enseñan ni se editan. */
  category: MerchantCategory | null
  city: string | null
  handle: string | null
  logoUrl: string | null
  socialUrl: string | null
  /** Comercio de prueba: todo lo que se venda en él queda fuera de las cifras. */
  isTest: boolean
}

export async function fetchMerchants(): Promise<MerchantRow[]> {
  const { data, error } = await supabase
    .from('merchant_directory')
    .select('*')
    .order('created_at', { ascending: false })

  if (error) throw error

  return data.map((row) => ({
    id: row.id as string,
    name: row.name as string,
    legalName: (row.legal_name as string | null) ?? null,
    taxId: (row.tax_id as string | null) ?? null,
    status: row.status as MerchantRow['status'],
    createdAt: row.created_at as string,
    staffCount: Number(row.staff_count),
    salesCount: Number(row.sales_count),
    sales30d: Number(row.sales_30d ?? 0),
    financed30d: Number(row.financed_30d ?? 0),
    isTest: Boolean(row.is_test),
    category: comoCategoria(row.category),
    city: (row.city as string | null) ?? null,
    handle: (row.handle as string | null) ?? null,
    logoUrl: (row.logo_url as string | null) ?? null,
    socialUrl: (row.social_url as string | null) ?? null,
  }))
}

export async function createMerchant(params: {
  name: string
  /** Obligatorio desde 2026-08-25. La base lo exige igual. */
  taxId: string
  legalName?: string
  category?: MerchantCategory
  city?: string
  logoUrl?: string
  /** Los de Helios (contrato §2.5). */
  specialty?: string
  mppsNumber?: string
  phone?: string
  email?: string
  address?: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_create_merchant', {
    p_name: params.name,
    p_legal_name: params.legalName ?? null,
    p_tax_id: params.taxId,
    p_category: params.category ?? null,
    p_city: params.city ?? null,
    // Helios no tiene app: sin usuario en redes ni red social.
    p_handle: null,
    p_logo_url: params.logoUrl ?? null,
    p_social_url: null,
    p_specialty: params.specialty ?? null,
    p_mpps_number: params.mppsNumber ?? null,
    p_phone: params.phone ?? null,
    p_email: params.email ?? null,
    p_address: params.address ?? null,
  })
  if (error) throw error
}

// El alta y la baja de personal viven en `features/merchant/staff.ts`: las
// hacen el equipo de Ronda Y el gerente del local, así que no son del cliente
// de admin.

// ── Pagos al comercio ──────────────────────────────────────────────────────

/**
 * Lo que se le debe a cada comercio, con el cierre del lunes delante.
 *
 * `accruedUsd` son filas reales de `settlements`; `upcomingUsd` es la cuota que
 * todavía no ha vencido y por tanto no existe en ninguna tabla. Se piden a una
 * RPC y no a la vista `merchant_payables` porque la previsión necesita leer
 * `installments` y la vista es `security_invoker`: la misma consulta desde el
 * panel del comercio volvería en cero sin dar error.
 */
export type MerchantPayable = {
  merchantId: string
  merchantName: string
  taxId: string | null
  /** Local de prueba: su fila se ve, con etiqueta, pero no suma en las cifras. */
  isTest: boolean
  /** Día operativo de hoy, de 10 AM a 10 AM. */
  todayDate: string
  /** El lunes del próximo cierre. Hoy mismo, si hoy es lunes. */
  nextRunDate: string
  /** Lo que hay que transferirle en ese cierre. */
  nextRunUsd: number
  accruedUsd: number
  accruedCount: number
  /** Cierres que ya pasaron y siguen sin transferirse. Eso sí es un atraso. */
  overdueUsd: number
  oldestDueDate: string | null
  /** Cuotas por vencer: se le deberán, pero todavía no toca. */
  upcomingUsd: number
  totalPendingUsd: number
  /** Cuándo salió la última transferencia, y de cuánto. Es la primera pregunta
   *  del gerente que llama. */
  lastPayoutOn: string | null
  lastPayoutUsd: number | null
  /**
   * Lo del próximo cierre partido en consultas y comisiones del personal
   * (contrato §2.5). `null` si la base no lo manda.
   */
  desglose?: ConsultasYComisiones | null
}

export async function fetchMerchantPayables(): Promise<MerchantPayable[]> {
  const { data, error } = await supabase.rpc('admin_merchant_payables')

  if (error) throw error

  return (data as Array<Record<string, unknown>>).map((row) => ({
    merchantId: row.merchant_id as string,
    merchantName: row.merchant_name as string,
    taxId: (row.tax_id as string | null) ?? null,
    isTest: Boolean(row.is_test),
    todayDate: String(row.today_date),
    nextRunDate: String(row.next_run_date),
    nextRunUsd: Number(row.next_run_usd ?? 0),
    accruedUsd: Number(row.accrued_usd ?? 0),
    accruedCount: Number(row.accrued_count ?? 0),
    overdueUsd: Number(row.overdue_usd ?? 0),
    oldestDueDate: (row.oldest_due_date as string | null) ?? null,
    upcomingUsd: Number(row.upcoming_usd ?? 0),
    totalPendingUsd: Number(row.total_pending_usd ?? 0),
    lastPayoutOn: (row.last_payout_on as string | null) ?? null,
    lastPayoutUsd: row.last_payout_usd == null ? null : Number(row.last_payout_usd),
    desglose: leerConsultasYComisiones(row),
  }))
}

/** `staff_commission`: la comisión del personal de la clínica (plan §6), que se paga en la misma transferencia. */
export type SettlementReason = 'advance' | 'scheduled_installment' | 'on_collection' | 'staff_commission'

export type SettlementStatus = 'pending' | 'partial' | 'paid'

export type Settlement = {
  id: string
  reason: SettlementReason
  status: SettlementStatus
  /** Lo que se devengó. En una parcial NO es lo que falta: eso es `pendingUsd`. */
  amountUsd: number
  paidUsd: number
  /** Lo que queda por transferir de esta línea. Es lo que se suma y lo que se paga. */
  pendingUsd: number
  /** El número de la orden del consumo, que es como lo llama el local. */
  orderNumber: number | null
  dueDate: string
  /** Ya le tocaba cobrar. Al comercio se le liquida por fecha, se retrase o
   *  no el usuario (docs/05 §3). */
  isDue: boolean
  /**
   * Entra en el cierre del lunes que viene.
   *
   * No es lo mismo que `isDue` y por eso existe: el lunes del cierre, lo
   * vencido incluye el tramo que vence ESE lunes, que pertenece a la semana
   * siguiente. Marcarlo sería adelantarle al comercio una semana entera.
   */
  inNextRun: boolean
  /** El lunes concreto en que se paga esta liquidación. */
  runDate: string
}

/**
 * Las liquidaciones de un comercio.
 *
 * Sin `runDate`, lo que se le debe hoy venga del cierre que venga —lo que
 * necesita la tarea del lunes—. Con `runDate`, las de ese cierre y solo ésas,
 * incluidas las ya transferidas: un cierre saldado tiene que poder contar qué
 * pasó, no quedarse en blanco.
 */
export async function fetchMerchantSettlements(
  merchantId: string,
  runDate?: string,
): Promise<Settlement[]> {
  const { data, error } = await supabase.rpc('admin_merchant_settlements', {
    p_merchant_id: merchantId,
    p_run_date: runDate ?? null,
  })
  if (error) throw error

  return (data as Array<Record<string, unknown>>).map((row) => ({
    id: String(row.id),
    reason: row.reason as SettlementReason,
    status: row.status as SettlementStatus,
    amountUsd: Number(row.amount_usd),
    paidUsd: Number(row.paid_usd ?? 0),
    pendingUsd: Number(row.pending_usd ?? 0),
    orderNumber: row.order_number == null ? null : Number(row.order_number),
    dueDate: String(row.due_date),
    isDue: Boolean(row.is_due),
    inNextRun: Boolean(row.in_next_run),
    runDate: String(row.run_date),
  }))
}

/**
 * Un cierre de caja con filas: el lunes, lo que se generó esa semana, lo que
 * salió del banco y lo que quedó a deber.
 *
 * El eje es `helios_settlement_run_for(due_date)`: cada liquidación pertenece a
 * un cierre y solo a uno, el primer lunes posterior a su vencimiento.
 */
export type SettlementRun = {
  runDate: string
  generadoUsd: number
  transferidoUsd: number
  pendienteUsd: number
  lineas: number
  comercios: number
  primerVencimiento: string
  ultimoVencimiento: string
  /** El cierre que viene. Lo dice el servidor, que es quien sabe qué día operativo es. */
  isNext: boolean
  /** Un lunes que ya pasó: lo que quede sin pagar aquí es atraso de verdad. */
  isPast: boolean
  /** Lo de los locales de prueba, contado aparte y nunca dentro de lo de arriba. */
  pendientePruebaUsd: number
  lineasPrueba: number
}

export async function fetchSettlementRuns(): Promise<SettlementRun[]> {
  const { data, error } = await supabase.rpc('admin_settlement_runs')
  if (error) throw error

  return (data as Array<Record<string, unknown>>).map((row) => ({
    runDate: String(row.run_date),
    generadoUsd: Number(row.generado_usd ?? 0),
    transferidoUsd: Number(row.transferido_usd ?? 0),
    pendienteUsd: Number(row.pendiente_usd ?? 0),
    lineas: Number(row.lineas ?? 0),
    comercios: Number(row.comercios ?? 0),
    primerVencimiento: String(row.primer_vencimiento),
    ultimoVencimiento: String(row.ultimo_vencimiento),
    isNext: Boolean(row.is_next),
    isPast: Boolean(row.is_past),
    pendientePruebaUsd: Number(row.pendiente_prueba_usd ?? 0),
    lineasPrueba: Number(row.lineas_prueba ?? 0),
  }))
}

/** Un comercio dentro de un cierre concreto. Sin proyección: lo que fue. */
export type RunPayable = {
  merchantId: string
  merchantName: string
  taxId: string | null
  isTest: boolean
  generadoUsd: number
  transferidoUsd: number
  pendienteUsd: number
  lineas: number
  primerVencimiento: string
}

export async function fetchRunPayables(runDate: string): Promise<RunPayable[]> {
  const { data, error } = await supabase.rpc('admin_run_payables', {
    p_run_date: runDate,
  })
  if (error) throw error

  return (data as Array<Record<string, unknown>>).map((row) => ({
    merchantId: row.merchant_id as string,
    merchantName: row.merchant_name as string,
    taxId: (row.tax_id as string | null) ?? null,
    isTest: Boolean(row.is_test),
    generadoUsd: Number(row.generado_usd ?? 0),
    transferidoUsd: Number(row.transferido_usd ?? 0),
    pendienteUsd: Number(row.pendiente_usd ?? 0),
    lineas: Number(row.lineas ?? 0),
    primerVencimiento: String(row.primer_vencimiento),
  }))
}

// Los medios y sus nombres viven en `liquidaciones.ts`, que es puro y se
// prueba; aquí se reexportan para no mover a quien ya los importa de aquí.
export { METODOS_DE_PAGO } from '@/features/admin/liquidaciones'
export type { PayoutMethod } from '@/features/admin/liquidaciones'

export async function reportMerchantPayout(params: {
  merchantId: string
  settlementIds: string[]
  method: PayoutMethod
  reference?: string
  amountVes?: number
  fxRate?: number
  note?: string
  /** Menos que lo marcado: se reparte de la liquidación más antigua a la más
   *  nueva y la última que alcanza queda parcial. Sin esto se paga todo. */
  amountUsd?: number
  /** Cuándo salió del banco, que no es cuándo se registra. */
  paidOn?: string
  receiptPath?: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_report_merchant_payout', {
    p_merchant_id: params.merchantId,
    p_settlement_ids: params.settlementIds,
    p_method: params.method,
    p_reference: params.reference ?? null,
    p_amount_ves: params.amountVes ?? null,
    p_fx_rate: params.fxRate ?? null,
    p_note: params.note ?? null,
    p_amount_usd: params.amountUsd ?? null,
    p_paid_on: params.paidOn ?? null,
    p_receipt_path: params.receiptPath ?? null,
  })
  if (error) throw error
}

/**
 * Sube el comprobante de una transferencia a un local.
 *
 * El bucket es privado: dentro hay datos bancarios de un tercero. Solo el
 * panel escribe y solo el panel lee, y la lectura va siempre por un enlace
 * firmado que caduca.
 *
 * Devuelve la ruta, no una URL: lo que se guarda en la fila es la ruta, y el
 * enlace se pide en el momento de mirarlo.
 */
export async function uploadPayoutReceipt(params: {
  merchantId: string
  file: File
}): Promise<string> {
  const ext = params.file.name.split('.').pop()?.toLowerCase() ?? 'bin'
  const path = `${params.merchantId}/${Date.now()}.${ext}`

  const { error } = await supabase.storage
    .from('merchant-receipts')
    .upload(path, params.file, { contentType: params.file.type, upsert: false })

  if (error) throw error
  return path
}

/**
 * El histórico de transferencias a locales.
 *
 * Existía en la base desde agosto —`merchant_payouts`, con su medio, su
 * referencia, su fecha de banco y su comprobante— y no había forma de mirarlo:
 * el panel solo sabía escribir ahí. Lo único que se veía era «última
 * transferencia», en una columna de la tabla.
 *
 * `paidOn` es cuándo salió del banco y `businessDate` cuándo se registró en el
 * panel. Son distintas cada vez que alguien registra el lunes lo del viernes,
 * y la que se coteja contra el extracto es la primera.
 */
export type Payout = {
  id: string
  merchantId: string
  merchantName: string
  isTest: boolean
  paidOn: string
  businessDate: string
  createdAt: string
  amountUsd: number
  amountVes: number | null
  fxRate: number | null
  method: PayoutMethod
  reference: string | null
  note: string | null
  tieneComprobante: boolean
  /** Quién la registró. Null si esa cuenta ya no es del equipo. */
  actorName: string | null
  /** Cuántas liquidaciones cubrió y entre qué vencimientos. */
  lineas: number
  primerVencimiento: string | null
  ultimoVencimiento: string | null
  /** Consultas y comisiones del personal, si la base las manda. */
  desglose?: ConsultasYComisiones | null
}

export type PayoutFilters = {
  merchantId?: string | null
  from?: string | null
  to?: string | null
  method?: PayoutMethod | null
  limit?: number
}

export async function fetchMerchantPayouts(filters: PayoutFilters = {}): Promise<Payout[]> {
  const { data, error } = await supabase.rpc('admin_merchant_payouts', {
    p_merchant_id: filters.merchantId ?? null,
    p_from: filters.from ?? null,
    p_to: filters.to ?? null,
    p_method: filters.method ?? null,
    p_limit: filters.limit ?? 200,
  })
  if (error) throw error

  return (data as Array<Record<string, unknown>>).map(mapPayout)
}

function mapPayout(row: Record<string, unknown>): Payout {
  return {
    id: String(row.id),
    merchantId: row.merchant_id as string,
    merchantName: row.merchant_name as string,
    isTest: Boolean(row.is_test),
    paidOn: String(row.paid_on),
    businessDate: String(row.business_date),
    createdAt: String(row.created_at),
    amountUsd: Number(row.amount_usd ?? 0),
    amountVes: row.amount_ves == null ? null : Number(row.amount_ves),
    fxRate: row.fx_rate == null ? null : Number(row.fx_rate),
    method: row.method as PayoutMethod,
    reference: (row.reference as string | null) ?? null,
    note: (row.note as string | null) ?? null,
    tieneComprobante: Boolean(row.tiene_comprobante),
    actorName: (row.actor_name as string | null) ?? null,
    lineas: Number(row.lineas ?? 0),
    primerVencimiento: (row.primer_vencimiento as string | null) ?? null,
    ultimoVencimiento: (row.ultimo_vencimiento as string | null) ?? null,
    desglose: leerConsultasYComisiones(row),
  }
}

/** Una liquidación cubierta por una transferencia. */
export type PayoutItem = {
  settlementId: string
  reason: SettlementReason
  status: SettlementStatus
  /** Lo que ESTE pago le aplicó. Con un pago parcial no es su importe. */
  appliedUsd: number
  settlementUsd: number
  paidUsd: number
  pendingUsd: number
  dueDate: string
  runDate: string
  chargeId: string | null
  orderNumber: number | null
  chargeDate: string | null
}

export type PayoutDetail = {
  id: string
  paidOn: string
  businessDate: string
  createdAt: string
  amountUsd: number
  amountVes: number | null
  fxRate: number | null
  method: PayoutMethod
  reference: string | null
  note: string | null
  receiptPath: string | null
  actorName: string | null
  merchant: {
    id: string
    name: string
    taxId: string | null
    isTest: boolean
    status: 'active' | 'paused' | 'terminated'
  }
  items: PayoutItem[]
  /** Consultas y comisiones del personal: de la base, o de las líneas. */
  desglose?: ConsultasYComisiones | null
}

export async function fetchPayoutDetail(payoutId: string): Promise<PayoutDetail> {
  const { data, error } = await supabase.rpc('admin_payout_detail', {
    p_payout_id: payoutId,
  })
  if (error) throw error

  const raw = data as Record<string, any>
  const items: PayoutItem[] = ((raw.items ?? []) as Array<Record<string, any>>).map((item) => ({
    settlementId: String(item.settlement_id),
    reason: item.reason as SettlementReason,
    status: item.status as SettlementStatus,
    appliedUsd: Number(item.applied_usd ?? 0),
    settlementUsd: Number(item.settlement_usd ?? 0),
    paidUsd: Number(item.paid_usd ?? 0),
    pendingUsd: Number(item.pending_usd ?? 0),
    dueDate: String(item.due_date),
    runDate: String(item.run_date),
    chargeId: item.charge_id ?? null,
    orderNumber: item.order_number == null ? null : Number(item.order_number),
    chargeDate: item.charge_date ?? null,
  }))

  return {
    id: String(raw.id),
    paidOn: String(raw.paid_on),
    businessDate: String(raw.business_date),
    createdAt: String(raw.created_at),
    amountUsd: Number(raw.amount_usd ?? 0),
    amountVes: raw.amount_ves == null ? null : Number(raw.amount_ves),
    fxRate: raw.fx_rate == null ? null : Number(raw.fx_rate),
    method: raw.method as PayoutMethod,
    reference: raw.reference ?? null,
    note: raw.note ?? null,
    receiptPath: raw.receipt_path ?? null,
    actorName: raw.actor_name ?? null,
    merchant: {
      id: String(raw.merchant?.id),
      name: String(raw.merchant?.name),
      taxId: raw.merchant?.tax_id ?? null,
      isTest: Boolean(raw.merchant?.is_test),
      status: raw.merchant?.status as 'active' | 'paused' | 'terminated',
    },
    items,
    desglose: leerConsultasYComisiones(
      raw,
      items.map((i) => ({ reason: i.reason, amountUsd: i.appliedUsd })),
    ),
  }
}

/** Enlace firmado para mirar un comprobante. Caduca en diez minutos. */
export async function payoutReceiptUrl(path: string): Promise<string> {
  const { data, error } = await supabase.storage
    .from('merchant-receipts')
    .createSignedUrl(path, 600)
  if (error) throw error
  return data.signedUrl
}

// ── Estados de cuenta ──────────────────────────────────────────────────────

export type StatementLine = {
  moved_on: string
  reference: string
  amount_ves: number
  description?: string
}

export type ImportResult = {
  received: number
  inserted: number
  duplicates: number
}

export async function importStatement(
  bank: string,
  lines: StatementLine[],
  fileName?: string,
  rowsRead?: number,
): Promise<ImportResult> {
  const { data, error } = await supabase.rpc('admin_import_statement', {
    p_bank: bank,
    p_lines: lines,
    p_file_name: fileName ?? null,
    p_rows_read: rowsRead ?? null,
  })
  if (error) throw error

  const raw = data as Record<string, unknown>
  return {
    received: Number(raw.received),
    inserted: Number(raw.inserted),
    duplicates: Number(raw.duplicates),
  }
}

/**
 * Quién subió qué archivo y cuándo.
 *
 * `daysSinceLast` es null cuando nunca se importó nada: la pantalla tiene que
 * distinguir "hace mucho" de "nunca", que se resuelven distinto.
 */
export type StatementImport = {
  id: string
  bank: string
  fileName: string | null
  rowsRead: number
  deposits: number
  inserted: number
  duplicates: number
  importedAt: string
  importedByName: string
}

export async function fetchStatementImports(limit = 30): Promise<{
  lastImportAt: string | null
  daysSinceLast: number | null
  rows: StatementImport[]
}> {
  const { data, error } = await supabase.rpc('admin_statement_imports', {
    p_limit: limit,
  })
  if (error) throw error

  const raw = data as Record<string, any>
  return {
    lastImportAt: raw.last_import_at ?? null,
    daysSinceLast: raw.days_since_last == null ? null : Number(raw.days_since_last),
    rows: (raw.rows ?? []).map((r: Record<string, any>) => ({
      id: String(r.id),
      bank: String(r.bank),
      fileName: r.file_name ?? null,
      rowsRead: Number(r.rows_read),
      deposits: Number(r.deposits),
      inserted: Number(r.inserted),
      duplicates: Number(r.duplicates),
      importedAt: String(r.imported_at),
      importedByName: String(r.imported_by_name),
    })),
  }
}

/** Un movimiento del extracto importado, tal cual lo trae el banco. */
export type MovimientoDelExtracto = {
  id: string
  bank: string
  movedOn: string
  reference: string
  amountVes: number
  description: string | null
}

function leerMovimiento(v: unknown): MovimientoDelExtracto | null {
  if (v === null || v === undefined) return null
  const r = comoFila(v)
  return {
    id: String(r.id),
    bank: String(r.bank),
    movedOn: String(r.moved_on),
    reference: String(r.reference),
    amountVes: Number(r.amount_ves),
    description: textoONulo(r.description),
  }
}

export type StatementMatch = MovimientoDelExtracto & {
  differenceVes: number
  /** Se puede elegir para respaldar este pago. */
  disponible: boolean
  /** Es el que ya respalda a este pago. */
  ligado: boolean
  /** Se descartó como ajeno a los usuarios. */
  descartado: boolean
  /** El pago al que ya respalda, si es otro. */
  usadoPor: { reportId: string; userId: string; fullName: string | null } | null
}

/**
 * Los movimientos del extracto que tienen la referencia del pago.
 *
 * Por defecto, los que además cuadran en monto (±1 Bs, lo mismo que cuenta
 * `statement_matches` en la cola). Con `toleranciaVes` se ensancha el monto:
 * es la forma de encontrar la referencia que sí está en el banco pero por
 * otra cifra, que con la tolerancia normal no sale nunca.
 */
export async function fetchStatementMatches(
  reportId: string,
  toleranciaVes?: number,
): Promise<StatementMatch[]> {
  const { data, error } = await supabase.rpc('admin_statement_matches', {
    p_report_id: reportId,
    ...(toleranciaVes === undefined ? {} : { p_tolerance_ves: toleranciaVes }),
  })
  if (error) throw error

  return comoLista(data).map((fila) => {
    const row = comoFila(fila)
    const usado = row.used_by === null || row.used_by === undefined ? null : comoFila(row.used_by)
    return {
      id: String(row.id),
      bank: String(row.bank),
      movedOn: String(row.moved_on),
      reference: String(row.reference),
      amountVes: Number(row.amount_ves),
      description: textoONulo(row.description),
      differenceVes: Number(row.difference_ves),
      // Sin el campo (una base sin la migración 145000), libre como antes.
      disponible: row.available !== false,
      ligado: row.linked === true,
      descartado: row.discarded === true,
      usadoPor: usado
        ? { reportId: String(usado.report_id), userId: String(usado.user_id), fullName: textoONulo(usado.full_name) }
        : null,
    }
  })
}

// ── Editar comercios ───────────────────────────────────────────────────────

export type SettlementPolicy = 'scheduled' | 'on_collection'

export type MerchantTerms = {
  upfrontPct: number
  perInstallmentPct: number
  commissionPct: number
  policy: SettlementPolicy
  /**
   * La comisión por financiamiento que se le paga al personal de esta
   * clínica (plan §6). `null`: usa el parámetro global `staff_commission_usd`.
   */
  staffCommissionUsd: number | null
}

export type MerchantStaff = {
  userId: string
  name: string | null
  email: string | null
  /** Solo lo tienen las cuentas antiguas creadas antes de 2026-08-22, cuando
   *  el alta de personal buscaba por teléfono en vez de crear la cuenta. */
  phone: string | null
  role: 'gerente' | 'cajero' | 'inventario'
  branch: string | null
}

export type MerchantProfile = {
  category: MerchantCategory | null
  city: string | null
  handle: string | null
  logoUrl: string | null
  socialUrl: string | null
  /** El RIF se edita aquí para poder completar los comercios dados de alta
   *  antes de que fuera obligatorio. Vacío deja el que ya tenía. */
  taxId: string | null
}

/**
 * Los datos médicos y de contacto de una clínica (contrato §2.5). Se ponen en
 * el alta; la ficha los enseña. TODO(contrato): no hay RPC para editarlos
 * después (`admin_set_merchant_profile` no los recibe).
 */
export type DatosDeLaClinica = {
  specialty: string | null
  mppsNumber: string | null
  phone: string | null
  email: string | null
  address: string | null
}

export type MerchantDetail = {
  profile: MerchantProfile
  datos: DatosDeLaClinica
  terms: MerchantTerms
  staff: MerchantStaff[]
  /** Lo devengado y todavía sin transferir. Cerrar un comercio con esto por
   *  encima de cero está bloqueado en el servidor. */
  pendingUsd: number
}

export async function fetchMerchantDetail(merchantId: string): Promise<MerchantDetail> {
  const { data, error } = await supabase.rpc('admin_merchant_detail', {
    p_merchant_id: merchantId,
  })
  if (error) throw error

  const raw = data as Record<string, any>
  return {
    profile: {
      category: comoCategoria(raw.profile.category),
      city: (raw.profile.city as string | null) ?? null,
      handle: (raw.profile.handle as string | null) ?? null,
      logoUrl: (raw.profile.logo_url as string | null) ?? null,
      socialUrl: (raw.profile.social_url as string | null) ?? null,
      taxId: (raw.profile.tax_id as string | null) ?? null,
    },
    datos: {
      specialty: textoONulo(raw.profile.specialty),
      mppsNumber: textoONulo(raw.profile.mpps_number),
      phone: textoONulo(raw.profile.phone),
      email: textoONulo(raw.profile.email),
      address: textoONulo(raw.profile.address),
    },
    terms: {
      upfrontPct: Number(raw.terms.upfront_pct),
      perInstallmentPct: Number(raw.terms.per_installment_pct),
      commissionPct: Number(raw.terms.commission_pct),
      policy: raw.terms.policy as SettlementPolicy,
      staffCommissionUsd: numeroONulo(raw.terms.staff_commission_usd),
    },
    staff: (raw.staff as Array<Record<string, unknown>>).map((s) => ({
      userId: String(s.user_id),
      name: (s.name as string | null) ?? null,
      email: (s.email as string | null) ?? null,
      phone: (s.phone as string | null) ?? null,
      role: s.role as MerchantStaff['role'],
      branch: (s.branch as string | null) ?? null,
    })),
    pendingUsd: Number(raw.pending_usd),
  }
}

export async function setMerchantProfile(params: {
  merchantId: string
  profile: MerchantProfile
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_merchant_profile', {
    p_merchant_id: params.merchantId,
    p_category: params.profile.category,
    p_city: params.profile.city,
    p_handle: params.profile.handle,
    p_logo_url: params.profile.logoUrl,
    p_social_url: params.profile.socialUrl,
    p_tax_id: params.profile.taxId,
  })
  if (error) throw error
}

/**
 * Sube el logo del comercio al bucket `merchant-logos` y devuelve su URL
 * pública.
 *
 * Antes esto era un campo de texto donde se pegaba la URL de un CDN ajeno.
 * El problema no era la comodidad: el día que esa imagen desaparecía, la
 * tarjeta del local se quedaba vacía en la app y nadie se enteraba. Ahora la
 * imagen es nuestra.
 *
 * El nombre del archivo lleva la marca de tiempo a propósito. Con un nombre
 * fijo, reemplazar el logo no se vería: el navegador —y el CDN de Storage—
 * seguirían sirviendo el viejo desde su caché.
 */
export async function uploadMerchantLogo(params: {
  /** Id del comercio, o uno nuevo si todavía no existe (alta). */
  folder: string
  file: File
}): Promise<string> {
  // Se sube el thumbnail, no el original. Nadie va a ver ese logo a más de
  // 512 px, y quien lo descarga es un teléfono en el wifi de un bar.
  const thumbnail = await resizeToThumbnail(params.file)
  const path = `${params.folder}/logo-${Date.now()}.${thumbnail.extension}`

  const { error } = await supabase.storage
    .from('merchant-logos')
    .upload(path, thumbnail.blob, { contentType: thumbnail.blob.type, upsert: false })

  if (error) throw error

  const { data } = supabase.storage.from('merchant-logos').getPublicUrl(path)
  return data.publicUrl
}

export async function setMerchantStatus(params: {
  merchantId: string
  status: MerchantRow['status']
  note?: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_merchant_status', {
    p_merchant_id: params.merchantId,
    p_status: params.status,
    p_note: params.note ?? null,
  })
  if (error) throw error
}

export async function setSettlementTerms(params: {
  merchantId: string
  terms: MerchantTerms
  /** Desde cuándo. Nunca en el pasado: los consumos anteriores conservan las
   *  suyas, que es justo lo que arregla esto. */
  effectiveFrom?: string
  note?: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_settlement_terms', {
    p_merchant_id: params.merchantId,
    p_upfront_pct: params.terms.upfrontPct,
    p_per_installment_pct: params.terms.perInstallmentPct,
    p_commission_pct: params.terms.commissionPct,
    p_policy: params.terms.policy,
    p_staff_commission_usd: params.terms.staffCommissionUsd,
    p_effective_from: params.effectiveFrom ?? null,
    p_note: params.note ?? null,
  })
  if (error) throw error
}

/** El histórico de condiciones de un comercio, para explicar una venta vieja. */
export type TermsHistoryRow = {
  id: string
  upfrontPct: number
  perInstallmentPct: number
  commissionPct: number
  policy: SettlementPolicy
  /** `null`: el global de su momento. */
  staffCommissionUsd: number | null
  effectiveFrom: string
  note: string | null
  createdAt: string
  /** Falso si todavía no ha entrado en vigor. */
  isCurrentOrPast: boolean
  createdByName: string
}

export async function fetchMerchantTermsHistory(
  merchantId: string,
): Promise<TermsHistoryRow[]> {
  const { data, error } = await supabase.rpc('admin_merchant_terms_history', {
    p_merchant_id: merchantId,
  })
  if (error) throw error

  return (data as Array<Record<string, unknown>>).map((row) => ({
    id: String(row.id),
    upfrontPct: Number(row.upfront_pct),
    perInstallmentPct: Number(row.per_installment_pct),
    commissionPct: Number(row.commission_pct),
    policy: row.policy as SettlementPolicy,
    staffCommissionUsd: numeroONulo(row.staff_commission_usd),
    effectiveFrom: String(row.effective_from),
    note: (row.note as string | null) ?? null,
    createdAt: String(row.created_at),
    isCurrentOrPast: Boolean(row.is_current_or_past),
    createdByName: String(row.created_by_name),
  }))
}

/**
 * Las cifras de un local: volumen de la ventana, su cartera entera y su punto
 * de empate.
 *
 * El empate depende de su modalidad: por cobranza no se le adelanta nada, así
 * que lo único que se pierde en un impago es el fee y el umbral es mucho más
 * alto. Es la diferencia que el local compra cuando negocia.
 */
export type MerchantStats = {
  windowDays: number
  chargeCount: number
  /** Consumo de la ventana, sin el service fee. */
  financedUsd: number
  distinctUsers: number
  avgTicketUsd: number
  /**
   * Su cartera al cierre de hoy o, con `semana`, al cierre de esa semana.
   * Lo que se paga en cuotas (`…Usd` a secas) viene con sus dos partes
   * (`…FinancedUsd` + `…FeeUsd`): no se enseña nunca sin ellas. Las partes
   * son `null` si la base todavía no las manda (anterior a 20260927501000):
   * entonces no se inventan.
   */
  portfolio: {
    /** El día que hizo de «hoy» para decidir qué estaba vencido. */
    diaDeReferencia: string | null
    billedUsd: number
    paidUsd: number
    overdueUsd: number
    overdueFinancedUsd: number | null
    overdueFeeUsd: number | null
    /** Lo vivo (vencido + por vencer), sin lo dado por perdido. */
    openUsd: number
    openFinancedUsd: number | null
    openFeeUsd: number | null
    writtenOffUsd: number
    arrearsPct: number
    badDebtPct: number
    onTimePct: number | null
    dueCount: number
    onTimeCount: number
    overdueCount: number
  }
  breakEven: {
    policy: SettlementPolicy
    feeUsd: number
    atRiskUsd: number
    breakEvenPct: number | null
  }
}

/**
 * La respuesta de `admin_merchant_stats`, leída campo a campo: lo que falte
 * es cero o nulo, nunca un `NaN`. Lo vivo, si la base no lo manda, es lo
 * emitido menos lo pagado y lo perdido; sus partes no se deducen.
 */
export function leerMerchantStats(data: unknown): MerchantStats {
  const raw = comoFila(data)
  const p = comoFila(raw.portfolio)
  const b = comoFila(raw.break_even)
  const n = (v: unknown) => numeroONulo(v) ?? 0

  const billedUsd = n(p.billed_usd)
  const paidUsd = n(p.paid_usd)
  const writtenOffUsd = n(p.written_off_usd)
  const openUsd = numeroONulo(p.open_usd) ?? billedUsd - paidUsd - writtenOffUsd
  const overdueUsd = n(p.overdue_usd)

  return {
    windowDays: n(raw.window_days),
    chargeCount: n(raw.charge_count),
    financedUsd: n(raw.financed_usd),
    distinctUsers: n(raw.distinct_users),
    avgTicketUsd: n(raw.avg_ticket_usd),
    portfolio: {
      diaDeReferencia: textoONulo(p.dia_de_referencia),
      billedUsd,
      paidUsd,
      overdueUsd,
      overdueFinancedUsd: numeroONulo(p.overdue_financed_usd),
      overdueFeeUsd: numeroONulo(p.overdue_fee_usd),
      openUsd,
      openFinancedUsd: numeroONulo(p.open_financed_usd),
      openFeeUsd: numeroONulo(p.open_fee_usd),
      writtenOffUsd,
      arrearsPct: n(p.arrears_pct),
      badDebtPct: n(p.bad_debt_pct),
      onTimePct: numeroONulo(p.on_time_pct),
      dueCount: n(p.due_count),
      onTimeCount: n(p.on_time_count),
      overdueCount: n(p.overdue_count),
    },
    breakEven: {
      policy: unoDe(['scheduled', 'on_collection'] as const, b.policy) ?? 'scheduled',
      feeUsd: n(b.fee_usd),
      atRiskUsd: n(b.at_risk_usd),
      breakEvenPct: numeroONulo(b.break_even_pct),
    },
  }
}

/**
 * Los argumentos de `admin_merchant_stats`. Con `semana` (un lunes), lo
 * vendido es el de esa semana y la cartera, la de su cierre.
 */
export function argumentosDeMerchantStats(
  merchantId: string,
  days = 30,
  semana?: string,
): { p_merchant_id: string; p_days: number; p_semana?: string } {
  return semana
    ? { p_merchant_id: merchantId, p_days: days, p_semana: semana }
    : { p_merchant_id: merchantId, p_days: days }
}

export async function fetchMerchantStats(
  merchantId: string,
  days = 30,
  semana?: string,
): Promise<MerchantStats> {
  const { data, error } = await supabase.rpc(
    'admin_merchant_stats',
    argumentosDeMerchantStats(merchantId, days, semana),
  )
  if (error) throw error
  return leerMerchantStats(data)
}

