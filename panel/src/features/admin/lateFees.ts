import { comoFila, comoLista, numero, numeroONulo, texto, textoONulo } from '@/lib/json'
import { unoDe } from '@/lib/busqueda'
import { supabase } from '@/lib/supabase'

/**
 * Los cargos por atraso de una persona, y la palanca para quitarlos.
 *
 * El estado automático pone el cargo (`late_fee_usd`) a la cuota que sigue
 * sin pagarse tras los días de gracia. Cuando el cargo está mal —el pago se
 * hizo a tiempo y la aprobación tardó, la app falló esa noche— se condona
 * desde la ficha.
 */
export type LateFee = {
  id: string
  amountUsd: number
  daysLate: number
  businessDate: string
  status: 'pending' | 'paid' | 'written_off'
  /** Relleno solo si lo condonó una persona. Uno dado por perdido no lo tiene. */
  waivedAt: string | null
  waiveReason: string | null
  /**
   * La cuota que lo originó (`installment_id`, desde 20260925133000). Nula en
   * los cargos de antes del reparto por cuota.
   */
  installmentId: string | null
  /** El número, el vencimiento y el local de esa cuota, para nombrarla. */
  sequence: number | null
  dueDate: string | null
  merchantName: string | null
}

const ESTADOS_DEL_CARGO: ReadonlyArray<LateFee['status']> = ['pending', 'paid', 'written_off']

function leerCargo(raw: unknown): LateFee {
  const r = comoFila(raw)
  return {
    id: texto(r.id),
    amountUsd: numero(r.amount_usd),
    daysLate: numero(r.days_late),
    businessDate: texto(r.business_date),
    // Un estado que no se conoce se enseña como pendiente: es el que pide mirarlo.
    status: unoDe(ESTADOS_DEL_CARGO, r.status) ?? 'pending',
    waivedAt: textoONulo(r.waived_at),
    waiveReason: textoONulo(r.waive_reason),
    installmentId: textoONulo(r.installment_id),
    sequence: numeroONulo(r.sequence),
    dueDate: textoONulo(r.due_date),
    merchantName: textoONulo(r.merchant_name),
  }
}

export async function fetchUserLateFees(userId: string): Promise<LateFee[]> {
  const { data, error } = await supabase.rpc('admin_user_late_fees', {
    p_user: userId,
  })
  if (error) throw error
  return comoLista(data).map(leerCargo)
}

/**
 * Condona un cargo pendiente.
 *
 * No es solo quitarlo de una lista: el servidor escribe el asiento contrario
 * —sin borrar el original—, lo baja del bloque de crédito para que el cupo
 * vuelva cuando toque, y avisa a la persona de que su deuda bajó.
 */
export async function waiveLateFee(feeId: string, reason: string): Promise<void> {
  const { error } = await supabase.rpc('admin_waive_late_fee', {
    p_fee_id: feeId,
    p_reason: reason,
  })
  if (error) throw error
}
