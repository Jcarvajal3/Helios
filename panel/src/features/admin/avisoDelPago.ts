import { diaOperativo, formatDay, formatVes } from '@/components/ui'
import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'
import { supabase } from '@/lib/supabase'

// ═══════════════════════════════════════════════════════════════════════════
// Los avisos del BNC (SMS) de un pago registrado, para su ficha.
//
// La ficha cotejaba solo con el extracto importado. Si el extracto de ese día
// todavía no está, el SMS del BNC de ese Pago Móvil puede haber llegado ya:
// se enseña como respaldo para decidir y, si encaja entero (referencia, monto
// ±1 Bs y día), se ofrece como el motivo de aprobarlo sin cotejo
// (`admin_bank_sms_for_report`).
// ═══════════════════════════════════════════════════════════════════════════

export type AvisoDelPago = {
  id: string
  recibidoEn: string
  referencia: string | null
  montoVes: number | null
  telefono: string | null
  pagadoEn: string | null
  /** Lo que decidió el bot con el aviso (`bank_sms_notices.outcome`). */
  decision: string
  /** El aviso ya está ligado a este pago. */
  ligado: boolean
  /** El aviso está ligado a OTRO pago: no puede respaldar este. */
  ligadoAOtro: boolean
  montoEncaja: boolean
  diaEncaja: boolean
}

export function leerAvisosDelPago(raw: unknown): AvisoDelPago[] {
  return comoLista(comoFila(raw).notices).map((fila) => {
    const r = comoFila(fila)
    return {
      id: String(r.id),
      recibidoEn: String(r.received_at),
      referencia: textoONulo(r.reference),
      montoVes: numeroONulo(r.amount_ves),
      telefono: textoONulo(r.payer_phone),
      pagadoEn: textoONulo(r.paid_at),
      decision: String(r.outcome ?? ''),
      ligado: r.linked === true,
      ligadoAOtro: r.linked_other === true,
      montoEncaja: r.amount_ok === true,
      diaEncaja: r.day_ok === true,
    }
  })
}

export async function fetchAvisosDelPago(reportId: string): Promise<AvisoDelPago[]> {
  const { data, error } = await supabase.rpc('admin_bank_sms_for_report', { p_report_id: reportId })
  if (error) throw error
  return leerAvisosDelPago(data)
}

/**
 * El aviso que respalda el pago: el que encaja por referencia, monto y día y
 * no respalda ya otro pago. `null` si ninguno.
 */
export function avisoQueRespalda(avisos: ReadonlyArray<AvisoDelPago>): AvisoDelPago | null {
  return avisos.find((a) => !a.ligadoAOtro && a.montoEncaja && a.diaEncaja) ?? null
}

/** El motivo de aprobar sin cotejo cuando lo respalda el aviso del BNC. */
export function motivoConElAviso(a: AvisoDelPago): string {
  const dia = formatDay(diaOperativo(new Date(a.pagadoEn ?? a.recibidoEn)))
  const monto = a.montoVes === null ? '' : ` por ${formatVes(a.montoVes)}`
  const ref = a.referencia ? `, referencia ${a.referencia}` : ''
  return `Respaldado por el aviso (SMS) del BNC del ${dia}${monto}${ref}; el extracto de ese día aún no está importado.`
}
