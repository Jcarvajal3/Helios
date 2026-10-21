import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'
import { supabase } from '@/lib/supabase'

// El saldo real del banco apuntado a mano frente al del libro. Lo leen el
// cierre y Métricas › Caja. (La proyección vive en `metricas/caja`.)

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
