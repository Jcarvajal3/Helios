import { supabase } from '@/lib/supabase'
import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'

/**
 * Ligar un movimiento del extracto a un pago que ya se aprobó sin él.
 *
 * Pasa cuando el pago se aprueba antes de importar el extracto, o cuando la
 * referencia reportada no es la del banco (se tecleó mal, o se pegó entera y
 * el campo se quedó con las primeras cifras). Ligar no mueve dinero: el pago
 * ya se aplicó. Solo deja escrito qué movimiento lo respalda.
 *
 * Los candidatos se buscan por monto (±1 Bs) y fecha (±5 días), con cualquier
 * referencia: si la referencia coincidiera, el cotejo lo habría encontrado al
 * aprobar.
 */

/** Un movimiento que puede respaldar un pago aprobado. */
export type MovimientoParaLigar = {
  id: string
  bank: string
  movedOn: string
  reference: string
  amountVes: number
  description: string | null
  differenceVes: number
  /** La referencia del movimiento termina en la que se reportó. */
  referenciaCoincide: boolean
  descartado: boolean
  /** Con qué motivo se descartó y quién, para leerlo antes de recuperarlo. */
  motivoDelDescarte: string | null
  descartadoPor: string | null
  /** Se puede ligar: no respalda ya otro pago. */
  disponible: boolean
  usadoPor: { reportId: string; fullName: string | null } | null
}

export async function fetchMovimientosParaLigar(reportId: string): Promise<MovimientoParaLigar[]> {
  const { data, error } = await supabase.rpc('admin_link_candidates', { p_report_id: reportId })
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
      referenciaCoincide: row.reference_matches === true,
      descartado: row.status === 'descartado',
      motivoDelDescarte: textoONulo(row.discard_note),
      descartadoPor: textoONulo(row.discarded_by_name),
      disponible: row.available === true,
      usadoPor: usado ? { reportId: String(usado.report_id), fullName: textoONulo(usado.full_name) } : null,
    }
  })
}

/** Un pago aprobado sin movimiento que un abono puede respaldar. */
export type PagoParaLigar = {
  reportId: string
  userId: string
  fullName: string | null
  createdAt: string
  reviewedAt: string | null
  method: string
  bank: string | null
  reference: string | null
  amountVes: number
  amountUsd: number
  differenceVes: number
  referenciaCoincide: boolean
}

export async function fetchPagosParaLigar(lineId: string): Promise<PagoParaLigar[]> {
  const { data, error } = await supabase.rpc('admin_link_reports_for_line', { p_line_id: lineId })
  if (error) throw error

  return comoLista(data).map((fila) => {
    const row = comoFila(fila)
    return {
      reportId: String(row.report_id),
      userId: String(row.user_id),
      fullName: textoONulo(row.full_name),
      createdAt: String(row.created_at),
      reviewedAt: textoONulo(row.reviewed_at),
      method: String(row.method),
      bank: textoONulo(row.bank),
      reference: textoONulo(row.reference),
      amountVes: Number(row.amount_ves),
      amountUsd: numeroONulo(row.amount_usd) ?? 0,
      differenceVes: Number(row.difference_ves),
      referenciaCoincide: row.reference_matches === true,
    }
  })
}

/**
 * Liga los dos. El servidor exige motivo si la referencia no coincide o si el
 * movimiento estaba descartado, y rechaza un movimiento que ya respalda otro
 * pago o cuyo monto o fecha no cuadran.
 */
export async function ligarMovimiento(params: { reportId: string; lineId: string; note?: string }): Promise<void> {
  const { error } = await supabase.rpc('admin_link_statement_line', {
    p_report_id: params.reportId,
    p_line_id: params.lineId,
    p_note: params.note ?? null,
  })
  if (error) throw error
}

/** Si ligar este par pide motivo. Lo mismo que exige el servidor. */
export function pideMotivo(par: { referenciaCoincide: boolean; descartado: boolean }): boolean {
  return !par.referenciaCoincide || par.descartado
}
