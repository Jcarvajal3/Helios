import { supabase } from '@/lib/supabase'

/**
 * Lo que Ronda le debe al local y lo que ya le transfirió.
 *
 * Las dos cosas son distintas y el modelo las separa a propósito
 * (20260822120000): al vender **se devenga** una obligación, y solo cuando
 * alguien de Ronda transfiere de verdad **sale el dinero**. Por eso esta
 * pantalla tiene dos mitades y no una.
 *
 * Todo lo de aquí lo lee solo el rol `gerente`: es la RLS de `settlements`,
 * no una decisión del panel.
 */

export type SettlementReason = 'advance' | 'scheduled_installment' | 'on_collection'

export const SETTLEMENT_REASON_LABEL: Record<SettlementReason, string> = {
  advance: 'Adelanto al vender',
  scheduled_installment: 'Cuota por fecha',
  on_collection: 'Por cobranza',
}

export type MerchantSettlementTerms = {
  upfrontPct: number
  perInstallmentPct: number
  commissionPct: number
  policy: 'scheduled' | 'on_collection'
}

export async function fetchSettlementTerms(
  merchantId: string,
): Promise<MerchantSettlementTerms | null> {
  const { data, error } = await supabase
    .from('merchant_settlement_terms')
    .select('upfront_pct, per_installment_pct, commission_pct, policy')
    .eq('merchant_id', merchantId)
    .maybeSingle()

  if (error) throw error
  if (!data) return null

  return {
    upfrontPct: Number(data.upfront_pct),
    perInstallmentPct: Number(data.per_installment_pct),
    commissionPct: Number(data.commission_pct),
    policy: data.policy as MerchantSettlementTerms['policy'],
  }
}

/**
 * Lo que se le debe al local, partido en lo que ya nació y lo que nacerá.
 *
 * Las dos mitades son de naturaleza distinta y por eso vienen separadas:
 * `accruedUsd` son filas reales de `settlements` —cuotas ya vencidas—, y
 * `upcomingUsd` es la cuota que todavía no ha vencido y que por tanto no
 * existe en ninguna tabla. Sumar solo la primera le enseñaría al dueño la
 * mitad de lo que se le debe, y parecería una respuesta legítima.
 *
 * Viene de una RPC y no de la vista `merchant_payables` porque la previsión
 * necesita leer `installments`, que el personal del comercio no puede leer.
 * Contra la vista `security_invoker` las cifras volverían en cero sin error.
 */
export type SettlementOutlook = {
  /** Día operativo de hoy: de 10 AM a 10 AM (docs/06 §1). */
  todayDate: string
  /** El lunes del próximo cierre de caja. Hoy mismo, si hoy es lunes. */
  nextRunDate: string
  /** Lo que entra en ese cierre: todo lo vencido antes de sus 10 AM. */
  nextRunUsd: number
  /** Devengado y sin transferir. */
  accruedUsd: number
  accruedCount: number
  /** Cierres que ya pasaron y siguen sin transferirse. */
  overdueUsd: number
  oldestDueDate: string | null
  /** Cuotas por vencer: la 2 de casi cualquier venta reciente. */
  upcomingUsd: number
  totalPendingUsd: number
}

export async function fetchSettlementOutlook(): Promise<SettlementOutlook> {
  // Sin `merchantId`: la RPC lo resuelve desde la sesión, así que un gerente
  // no puede pedir la caja del local de al lado ni por error.
  const { data, error } = await supabase.rpc('merchant_settlement_outlook')

  if (error) throw error

  const row = (data ?? {}) as Record<string, unknown>

  return {
    todayDate: String(row.today_date),
    nextRunDate: String(row.next_run_date),
    nextRunUsd: Number(row.next_run_usd ?? 0),
    accruedUsd: Number(row.accrued_usd ?? 0),
    accruedCount: Number(row.accrued_count ?? 0),
    overdueUsd: Number(row.overdue_usd ?? 0),
    oldestDueDate: (row.oldest_due_date as string | null) ?? null,
    upcomingUsd: Number(row.upcoming_usd ?? 0),
    totalPendingUsd: Number(row.total_pending_usd ?? 0),
  }
}

export type PendingSettlement = {
  id: string
  reason: SettlementReason
  amountUsd: number
  dueDate: string
  businessDate: string
}

export async function fetchPendingSettlements(
  merchantId: string,
): Promise<PendingSettlement[]> {
  const { data, error } = await supabase
    .from('settlements')
    .select('id, reason, amount_usd, due_date, business_date')
    .eq('merchant_id', merchantId)
    .eq('status', 'pending')
    .order('due_date', { ascending: true })

  if (error) throw error

  return data.map((row) => ({
    id: row.id as string,
    reason: row.reason as SettlementReason,
    amountUsd: Number(row.amount_usd),
    dueDate: row.due_date as string,
    businessDate: row.business_date as string,
  }))
}

export type MerchantPayout = {
  id: string
  amountUsd: number
  amountVes: number | null
  method: string
  reference: string | null
  note: string | null
  businessDate: string
  createdAt: string
  /** Cuántas liquidaciones cubrió esa transferencia. */
  itemCount: number
}

export const PAYOUT_METHOD_LABEL: Record<string, string> = {
  pago_movil: 'Pago Móvil',
  transferencia: 'Transferencia',
  zelle: 'Zelle',
  usdt: 'USDT',
  efectivo: 'Efectivo',
  boveda: 'Cubierto por la garantía',
}

export async function fetchPayouts(merchantId: string): Promise<MerchantPayout[]> {
  const { data, error } = await supabase
    .from('merchant_payouts')
    .select(
      'id, amount_usd, amount_ves, method, reference, note, business_date, created_at, merchant_payout_items(count)',
    )
    .eq('merchant_id', merchantId)
    .order('created_at', { ascending: false })

  if (error) throw error

  type Row = {
    id: string
    amount_usd: string
    amount_ves: string | null
    method: string
    reference: string | null
    note: string | null
    business_date: string
    created_at: string
    merchant_payout_items: Array<{ count: number }>
  }

  return (data as unknown as Row[]).map((row) => ({
    id: row.id,
    amountUsd: Number(row.amount_usd),
    amountVes: row.amount_ves === null ? null : Number(row.amount_ves),
    method: row.method,
    reference: row.reference,
    note: row.note,
    businessDate: row.business_date,
    createdAt: row.created_at,
    itemCount: Number(row.merchant_payout_items[0]?.count ?? 0),
  }))
}

/** Qué liquidaciones cubrió una transferencia concreta. */
export async function fetchPayoutDetail(payoutId: string): Promise<PendingSettlement[]> {
  const { data, error } = await supabase
    .from('merchant_payout_items')
    .select('amount_usd, settlements(id, reason, due_date, business_date)')
    .eq('payout_id', payoutId)

  if (error) throw error

  type Row = {
    amount_usd: string
    settlements: {
      id: string
      reason: SettlementReason
      due_date: string
      business_date: string
    } | null
  }

  return (data as unknown as Row[])
    .filter((row) => row.settlements !== null)
    .map((row) => ({
      id: row.settlements!.id,
      reason: row.settlements!.reason,
      amountUsd: Number(row.amount_usd),
      dueDate: row.settlements!.due_date,
      businessDate: row.settlements!.business_date,
    }))
    .sort((a, b) => a.dueDate.localeCompare(b.dueDate))
}
