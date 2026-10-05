// ═══════════════════════════════════════════════════════════════════════════
// Helios — El bot del médico (docs/00 §15.4)
//
// Esqueleto del paso E: el webhook ya reconoce los números del personal y los
// manda aquí. La conversación (PIN, cédula, datos con Claude, resumen y
// confirmación) llega en el paso F.
// ═══════════════════════════════════════════════════════════════════════════

import type { EventoDeMensaje } from './logica.ts'

/** La persona del personal dueña del número (helios_staff_whatsapp_row). */
export type Personal = {
  id: string
  phone_e164: string
  user_id: string
  staff_name: string | null
  role: 'gerente' | 'cajero' | null
  merchant_id: string
  merchant_name: string | null
  has_pin: boolean
  pin_locked: boolean
}

export type Rpc = <T>(fn: string, args: Record<string, unknown>) => Promise<T>

export async function atenderAlPersonal(_: {
  rpc: Rpc
  personal: Personal
  mensaje: EventoDeMensaje
}): Promise<unknown> {
  return { pendiente: 'el bot llega en el paso F' }
}
