import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'
import { supabase } from '@/lib/supabase'
import { leerProyectadoFrenteAReal } from '@/features/admin/proyectadoFrenteAReal'
import type { ProyectadoFrenteAReal } from '@/features/admin/proyectadoFrenteAReal'

// Lo que se espera que entre y salga de la caja en las próximas semanas, y el
// saldo real del banco apuntado a mano frente al del libro. Lo leen el
// cierre y Dinero.

export type ForecastWeek = {
  weekStart: string
  weekEnd: string
  /** Lo que vence, sin ajustar. */
  expectedGrossUsd: number
  /** Lo mismo, multiplicado por el cobro a tiempo histórico. */
  expectedInUsd: number
  expectedOutUsd: number
  netUsd: number
}

export type CashForecast = {
  businessDate: string
  cashNowUsd: number
  weeks: number
  /** Null cuando no hay historia suficiente para ajustar. */
  onTimeFactor: number | null
  graceDays: number
  rows: ForecastWeek[]
}

export async function fetchCashForecast(weeks = 4): Promise<CashForecast> {
  const { data, error } = await supabase.rpc('admin_cash_forecast', { p_weeks: weeks })
  if (error) throw error

  const raw = comoFila(data)
  return {
    businessDate: String(raw.business_date),
    cashNowUsd: Number(raw.cash_now_usd),
    weeks: Number(raw.weeks),
    onTimeFactor: numeroONulo(raw.on_time_factor),
    graceDays: Number(raw.grace_days),
    rows: comoLista(raw.rows).map((semana) => {
      const r = comoFila(semana)
      return {
        weekStart: String(r.week_start),
        weekEnd: String(r.week_end),
        expectedGrossUsd: Number(r.expected_gross_usd),
        expectedInUsd: Number(r.expected_in_usd),
        expectedOutUsd: Number(r.expected_out_usd),
        netUsd: Number(r.net_usd),
      }
    }),
  }
}

/** Las semanas que se comparan con lo que pasó. */
export const SEMANAS_COMPARADAS = 8

/**
 * Lo proyectado cada lunes frente a lo que pasó, semana a semana. Vacío hasta
 * la primera foto.
 */
export async function fetchProyectadoFrenteAReal(
  semanas = SEMANAS_COMPARADAS,
): Promise<ProyectadoFrenteAReal> {
  const { data, error } = await supabase.rpc('admin_forecast_vs_actual', { p_weeks: semanas })
  if (error) throw error
  return leerProyectadoFrenteAReal(data)
}

/**
 * El saldo real del banco frente al del libro.
 *
 * La diferencia es exactamente lo que no se registró: un pago sin conciliar,
 * una comisión bancaria, una transferencia hecha y no anotada.
 */
export type BankBalanceCheck = {
  checkedOn: string
  balanceVes: number | null
  balanceUsd: number
  fxRate: number | null
  ledgerUsd: number
  differenceUsd: number
  note: string | null
  recordedByName: string
  createdAt: string
}

export async function fetchBankBalances(limit = 26): Promise<BankBalanceCheck[]> {
  const { data, error } = await supabase.rpc('admin_bank_balance_history', {
    p_limit: limit,
  })
  if (error) throw error

  return comoLista(data).map((fila) => {
    const row = comoFila(fila)
    return {
      checkedOn: String(row.checked_on),
      balanceVes: numeroONulo(row.balance_ves),
      balanceUsd: Number(row.balance_usd),
      fxRate: numeroONulo(row.fx_rate),
      ledgerUsd: Number(row.ledger_usd),
      differenceUsd: Number(row.difference_usd),
      note: textoONulo(row.note),
      recordedByName: String(row.recorded_by_name),
      createdAt: String(row.created_at),
    }
  })
}

export async function recordBankBalance(params: {
  balanceVes?: number
  balanceUsd?: number
  checkedOn?: string
  note?: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_record_bank_balance', {
    p_balance_ves: params.balanceVes ?? null,
    p_balance_usd: params.balanceUsd ?? null,
    p_checked_on: params.checkedOn ?? null,
    p_note: params.note ?? null,
  })
  if (error) throw error
}
