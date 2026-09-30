import { supabase } from '@/lib/supabase'
import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'

/**
 * Los abonos del banco que nadie ha reclamado.
 *
 * El estado de cuenta se importa para cotejar: dado un pago que alguien
 * reportó, comprobar que existe. Esto es la pregunta contraria — qué dinero
 * entró y no está asignado a nadie — y es la que encuentra a la persona que
 * transfirió y no reportó.
 */
export type UnmatchedDeposit = {
  id: string
  bank: string
  /** Fecha del movimiento según el banco. */
  movedOn: string
  reference: string
  amountVes: number
  /** El equivalente a la tasa del día del abono, no a la de hoy. */
  amountUsd: number | null
  description: string | null
  importedAt: string
}

export async function fetchUnmatchedDeposits(limit = 100): Promise<UnmatchedDeposit[]> {
  const { data, error } = await supabase.rpc('admin_unmatched_deposits', {
    p_limit: limit,
  })
  if (error) throw error

  return (data as Array<Record<string, unknown>>).map((row) => ({
    id: String(row.id),
    bank: String(row.bank),
    movedOn: String(row.moved_on),
    reference: String(row.reference),
    amountVes: Number(row.amount_ves),
    amountUsd: row.amount_usd == null ? null : Number(row.amount_usd),
    description: (row.description as string | null) ?? null,
    importedAt: String(row.imported_at),
  }))
}

/**
 * Aplica un abono a las cuotas de una persona.
 *
 * El servidor crea la misma cotización y el mismo reporte que habría creado
 * ella desde la app y llama a la conciliación de siempre: el asiento, el saldo,
 * el aviso y la bitácora salen idénticos a los de un pago normal.
 */
export async function assignDeposit(params: {
  lineId: string
  userId: string
  installmentIds: string[]
  note?: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_assign_deposit', {
    p_line_id: params.lineId,
    p_user_id: params.userId,
    p_installment_ids: params.installmentIds,
    p_note: params.note ?? null,
  })
  if (error) throw error
}

/** Lo saca de la lista: un depósito propio, una devolución. No mueve el libro. */
export async function discardDeposit(lineId: string, reason: string): Promise<void> {
  const { error } = await supabase.rpc('admin_discard_deposit', {
    p_line_id: lineId,
    p_reason: reason,
  })
  if (error) throw error
}

/** Un abono que alguien sacó de la lista porque no era de un usuario. */
export type DiscardedDeposit = UnmatchedDeposit & {
  importedByName: string
  discardedAt: string
  discardedByName: string
  /** El motivo que se escribió al descartarlo. */
  reason: string
}

/**
 * Los abonos descartados, del más reciente al más viejo.
 *
 * Descartar no escribe asiento: si el motivo resulta estar mal, esta lista es
 * el único sitio donde se ve qué se descartó, quién y por qué.
 */
export async function fetchDiscardedDeposits(limit = 100): Promise<DiscardedDeposit[]> {
  const { data, error } = await supabase.rpc('admin_discarded_deposits', { p_limit: limit })
  if (error) throw error

  return comoLista(data).map((fila) => {
    const row = comoFila(fila)
    return {
      id: String(row.id),
      bank: String(row.bank),
      movedOn: String(row.moved_on),
      reference: String(row.reference),
      amountVes: Number(row.amount_ves),
      amountUsd: numeroONulo(row.amount_usd),
      description: textoONulo(row.description),
      importedAt: String(row.imported_at),
      importedByName: String(row.imported_by_name),
      discardedAt: String(row.discarded_at),
      discardedByName: String(row.discarded_by_name),
      reason: String(row.reason),
    }
  })
}
