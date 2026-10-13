import { comoLista, comoFila, texto, textoONulo } from '@/lib/json'
import { supabase } from '@/lib/supabase'

// ═══════════════════════════════════════════════════════════════════════════
// Los números del bot de WhatsApp de una clínica (docs/00 §15.4, contrato
// §2.7). El equipo de Helios registra el número de cada persona del personal
// que usa el bot; escribir desde ese número la identifica (sin PIN desde el
// 2026-10-13). Escribir lo exige el servidor a un super admin y queda en la
// bitácora.
// ═══════════════════════════════════════════════════════════════════════════

export type NumeroDelBot = {
  id: string
  phone: string
  userId: string
  staffName: string | null
  role: 'gerente' | 'cajero' | null
  lastInboundAt: string | null
  createdAt: string | null
  createdByName: string | null
  revokedAt: string | null
  revokeReason: string | null
}

export function leerNumeroDelBot(v: unknown): NumeroDelBot {
  const r = comoFila(v)
  return {
    id: texto(r.id),
    phone: texto(r.phone_e164),
    userId: texto(r.user_id),
    staffName: textoONulo(r.staff_name),
    role: r.role === 'gerente' || r.role === 'cajero' ? r.role : null,
    lastInboundAt: textoONulo(r.last_inbound_at),
    createdAt: textoONulo(r.created_at),
    createdByName: textoONulo(r.created_by_name),
    revokedAt: textoONulo(r.revoked_at),
    revokeReason: textoONulo(r.revoke_reason),
  }
}

/** «+584145556677» → «0414-555-66-77». */
export function telefonoLegible(e164: string): string {
  const d = e164.replace(/\D/g, '')
  const local = d.startsWith('58') ? `0${d.slice(2)}` : d
  const m = /^(0\d{3})(\d{3})(\d{2})(\d{2})$/.exec(local)
  return m ? `${m[1]}-${m[2]}-${m[3]}-${m[4]}` : e164
}

export const claveNumerosDelBot = (merchantId: string) => ['admin-numeros-del-bot', merchantId] as const

export function consultaNumerosDelBot(merchantId: string) {
  return {
    queryKey: claveNumerosDelBot(merchantId),
    queryFn: async (): Promise<NumeroDelBot[]> => {
      const { data, error } = await supabase.rpc('admin_staff_whatsapp', { p_merchant_id: merchantId })
      if (error) throw error
      return comoLista(data).map(leerNumeroDelBot)
    },
  }
}

export async function registrarNumeroDelBot(p: {
  userId: string
  merchantId: string
  phone: string
}): Promise<NumeroDelBot> {
  const { data, error } = await supabase.rpc('admin_set_staff_whatsapp', {
    p_user_id: p.userId,
    p_merchant_id: p.merchantId,
    p_phone: p.phone,
  })
  if (error) throw error
  return leerNumeroDelBot(data)
}

export async function revocarNumeroDelBot(id: string, motivo: string): Promise<void> {
  const { error } = await supabase.rpc('admin_revoke_staff_whatsapp', { p_id: id, p_reason: motivo })
  if (error) throw error
}
