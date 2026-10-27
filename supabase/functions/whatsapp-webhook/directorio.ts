// ═══════════════════════════════════════════════════════════════════════════
// Helios — Quien escribe desde el directorio (docs/04, 2026-10-27)
//
// El botón «Escribir por WhatsApp» de una tarjeta de /directorio abre el chat
// con Helios con un mensaje que lleva el código del médico (DIR-XXXX). Aquí:
//
//   · bot_directorio_interesado guarda (o pone al día) el interesado: médico
//     + teléfono, para medir cuántos terminan siendo pacientes;
//   · se le contesta con el contacto del médico (textos_directorio.ts), o, si
//     la tarjeta ya no sale, con el enlace al directorio.
//
// Al paciente se le contesta dentro de su ventana de 24 h (acaba de
// escribir): no hace falta plantilla de Meta.
// ═══════════════════════════════════════════════════════════════════════════

import type { EventoDeMensaje } from './logica.ts'
import { mensajeContactoDelMedico, mensajeMedicoNoDisponible } from './textos_directorio.ts'

type Rpc = <T>(fn: string, args: Record<string, unknown>) => Promise<T>

/** Lo que devuelve `bot_directorio_interesado` (docs/04, «El contrato»). */
type Interesado =
  | { ok: false; motivo: 'codigo_desconocido' | 'no_publicado' }
  | {
      ok: true
      nuevo: boolean
      lead_id: string
      merchant_id: string
      name: string
      specialty: string | null
      address: string | null
      city: string | null
      whatsapp: string | null
    }

/** Devuelve qué hizo (para `whatsapp_inbound.result`). */
export async function atenderAlInteresado({
  rpc,
  mensaje,
  codigo,
}: {
  rpc: Rpc
  mensaje: EventoDeMensaje
  /** 'DIR-XXXX', de `codigoDelDirectorio`. */
  codigo: string
}): Promise<Record<string, unknown>> {
  const r = await rpc<Interesado>('bot_directorio_interesado', {
    p_phone: mensaje.from,
    p_code: codigo,
    p_message_id: mensaje.id,
  })

  const enviar = (texto: string) =>
    rpc('helios_whatsapp_patient_text', { p_to: mensaje.from, p_text: texto, p_profile_id: null, p_buttons: [] })

  if (!r?.ok) {
    await enviar(mensajeMedicoNoDisponible())
    return { accion: 'directorio', codigo, ok: false, motivo: r?.motivo ?? null }
  }

  await enviar(mensajeContactoDelMedico(r))
  return { accion: 'directorio', codigo, ok: true, nuevo: r.nuevo, lead_id: r.lead_id, merchant_id: r.merchant_id }
}
