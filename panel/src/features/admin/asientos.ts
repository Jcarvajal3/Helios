import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'
import { supabase } from '@/lib/supabase'

// Los asientos del libro, con su contraparte y el saldo de caja después de
// cada uno. Lo lee Caja y contabilidad (`Libro.tsx`); los nombres de las
// cuentas y de los tipos de asiento están en `contabilidad.ts`.

export type LedgerLine = {
  account: string
  ownerId: string | null
  debit: number
  credit: number
}

export type LedgerTransaction = {
  transactionId: string
  type: string
  businessDate: string
  memo: string | null
  createdAt: string
  actorName: string | null
  /** Lo que movió la caja, en bolívares a la tasa de SU día operativo. */
  amountVes: number | null
  fxRate: number | null
  /** El saldo de caja después de este asiento. Acumulado sobre la historia
   *  entera, no sobre las filas que caben en pantalla. */
  cashBalance: number
  counterpartyKind: 'persona' | 'comercio' | null
  counterpartyId: string | null
  counterpartyName: string | null
  lines: LedgerLine[]
}

export async function fetchLedgerEntries(params: {
  limit?: number
  type?: string | null
  from?: string | null
  to?: string | null
  userId?: string | null
  merchantId?: string | null
}): Promise<LedgerTransaction[]> {
  const { data, error } = await supabase.rpc('admin_ledger_entries', {
    p_limit: params.limit ?? 100,
    p_type: params.type ?? null,
    p_from: params.from ?? null,
    p_to: params.to ?? null,
    p_user_id: params.userId ?? null,
    p_merchant_id: params.merchantId ?? null,
  })
  if (error) throw error

  return comoLista(data).map((fila) => {
    const row = comoFila(fila)
    const contraparte = row.counterparty_kind
    return {
      transactionId: String(row.transaction_id),
      type: String(row.type),
      businessDate: String(row.business_date),
      memo: textoONulo(row.memo),
      createdAt: String(row.created_at),
      actorName: textoONulo(row.actor_name),
      amountVes: numeroONulo(row.amount_ves),
      fxRate: numeroONulo(row.fx_rate),
      cashBalance: Number(row.cash_balance ?? 0),
      counterpartyKind:
        contraparte === 'persona' || contraparte === 'comercio' ? contraparte : null,
      counterpartyId: textoONulo(row.counterparty_id),
      counterpartyName: textoONulo(row.counterparty_name),
      lines: comoLista(row.lines).map((linea) => {
        const l = comoFila(linea)
        return {
          account: String(l.account),
          ownerId: textoONulo(l.owner_id),
          debit: Number(l.debit),
          credit: Number(l.credit),
        }
      }),
    }
  })
}
