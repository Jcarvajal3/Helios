import { supabase } from '@/lib/supabase'
import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'
import type { DecisionBot, EstadoPago, ModoBot, PagoDelAviso, RevisionBot } from './avisosBnc'

/** Las llamadas del bot de avisos. La lógica pura vive en `avisosBnc.ts`. */

const ESTADOS: readonly EstadoPago[] = ['reported', 'in_review', 'reconciled', 'rejected', 'duplicate']

function modoDe(v: unknown): ModoBot {
  return v === 'activo' || v === 'apagado' ? v : 'sombra'
}

function pagoDe(row: Record<string, unknown>): PagoDelAviso | null {
  if (row.report_id === null || row.report_id === undefined) return null
  const estado = ESTADOS.find((e) => e === row.report_status) ?? 'reported'
  return {
    id: String(row.report_id),
    userId: String(row.user_id),
    persona: textoONulo(row.user_name) ?? 'Sin nombre',
    referencia: String(row.report_reference ?? row.reference ?? ''),
    telefono: textoONulo(row.report_phone),
    reportadoEn: String(row.reported_at),
    estado,
    revisadoEn: textoONulo(row.reviewed_at),
    revisadoPor: textoONulo(row.reviewed_by_name),
    motivoRechazo: textoONulo(row.rejection_note),
    montoVes: Number(row.report_amount_ves),
    montoUsd: Number(row.report_amount_usd),
  }
}

export async function fetchRevisionBot(desde: string, hasta: string): Promise<RevisionBot> {
  const { data, error } = await supabase.rpc('admin_bank_sms_review', { p_from: desde, p_to: hasta })
  if (error) throw error

  const r = comoFila(data)
  return {
    modo: modoDe(r.mode),
    modoDesde: textoONulo(r.mode_updated_at),
    modoPor: textoONulo(r.mode_updated_by_name),
    remitenteFijado: textoONulo(r.allowed_sender),
    primerAviso: textoONulo(r.first_notice_at),
    avisos: comoLista(r.notices).map((fila) => {
      const row = comoFila(fila)
      const prefijo = textoONulo(row.payer_phone_prefix)
      const final = textoONulo(row.payer_phone_last4)
      return {
        id: String(row.id),
        recibidoEn: String(row.received_at),
        texto: String(row.body),
        remitente: textoONulo(row.sender),
        referencia: textoONulo(row.reference),
        montoVes: numeroONulo(row.amount_ves),
        telefono: prefijo && final ? `${prefijo}***${final}` : null,
        pagadoEn: textoONulo(row.paid_at),
        decision: String(row.outcome) as DecisionBot,
        modo: row.mode === null || row.mode === undefined ? null : modoDe(row.mode),
        decididoEn: textoONulo(row.decided_at),
        nota: textoONulo(row.note),
        emparejadoPorBot: row.bot_paired === true,
        pago: pagoDe(row),
      }
    }),
    sinAviso: comoLista(r.without_notice).map((fila) => {
      const row = comoFila(fila)
      return {
        id: String(row.report_id),
        userId: String(row.user_id),
        persona: textoONulo(row.user_name) ?? 'Sin nombre',
        referencia: String(row.reference),
        reportadoEn: String(row.reported_at),
        revisadoEn: textoONulo(row.reviewed_at),
        revisadoPor: textoONulo(row.reviewed_by_name),
        montoVes: Number(row.report_amount_ves),
        montoUsd: Number(row.report_amount_usd),
      }
    }),
  }
}

export async function cambiarModoBot(modo: ModoBot, motivo: string): Promise<void> {
  const { error } = await supabase.rpc('admin_set_bank_sms_mode', { p_mode: modo, p_note: motivo })
  if (error) throw error
}
