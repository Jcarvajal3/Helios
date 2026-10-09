// ═══════════════════════════════════════════════════════════════════════════
// Helios — El webhook de WhatsApp (docs/00 §15.3, docs/01 §5.2)
//
// 360dialog manda aquí cada mensaje que llega al número de Helios y cada
// estado de entrega de lo que Helios mandó. Es la única pieza con runtime
// propio: todo lo demás vive en la base, y aquí solo se enruta.
//
//   1. Estados de entrega            → helios_whatsapp_status
//   2. El botón de la pregunta       → helios_patient_decision
//   3. Un número del personal        → el bot del médico (bot.ts)
//   4. «Sí» / «No» escrito por un paciente con UNA orden esperando
//                                    → helios_patient_decision
//   5. Todo lo demás                 → el bot del paciente (paciente.ts); si
//                                      se calla, lo atiende una persona desde la
//                                      app WhatsApp Business (coexistencia)
//
// La URL lleva un secreto propio (?token=…, WHATSAPP_WEBHOOK_TOKEN). Sin él,
// 401. Cada mensaje se guarda primero (helios_whatsapp_inbound) y su wamid es
// único: un reintento de 360dialog no repite nada. Si la base falla, 500 para
// que 360dialog reintente.
//
// Despliegue (sin Docker):
//   supabase functions deploy whatsapp-webhook --no-verify-jwt --use-api \
//     --project-ref ahyfbnfsbyzdoyjzjvfb
// ═══════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2'

import { atenderAlPersonal } from './bot.ts'
import { atenderAlPaciente } from './paciente.ts'
import type { Personal } from './bot.ts'
import {
  decisionDelBoton,
  decisionDelTexto,
  extraerEventos,
  horaDelEstado,
  igualSeguro,
} from './logica.ts'
import type { EventoDeMensaje } from './logica.ts'

const TOKEN = Deno.env.get('WHATSAPP_WEBHOOK_TOKEN') ?? ''

const db = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
  { auth: { persistSession: false, autoRefreshToken: false } },
)

/** Una RPC; lanza si la base falla (el webhook responde 500 y 360dialog reintenta). */
async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args)
  if (error) {
    // El código viaja con el error: el bot solo le enseña al médico los
    // errores de negocio (`ERRORES_DE_NEGOCIO` en bot.ts), no los internos.
    throw Object.assign(new Error(`${fn}: ${error.message}`), { code: error.code })
  }
  return data as T
}

type Recibido = {
  ok: boolean
  duplicate?: boolean
  staff?: Personal | null
  pending_charge_id?: string | null
}

async function mensaje(m: EventoDeMensaje): Promise<void> {
  const r = await rpc<Recibido>('helios_whatsapp_inbound', {
    p_message_id: m.id,
    p_from: m.from,
    p_type: m.type,
    p_payload: m.raw,
  })
  if (!r.ok || r.duplicate) return

  const listo = (route: 'paciente' | 'personal' | 'nadie', result: unknown = null) =>
    rpc('helios_whatsapp_inbound_done', { p_message_id: m.id, p_route: route, p_result: result })

  // 2. El botón de la pregunta lleva el id de la orden.
  const boton = decisionDelBoton(m.boton)
  if (boton) {
    const res = await rpc('helios_patient_decision', {
      p_charge_id: boton.chargeId,
      p_decision: boton.decision,
      p_from_phone: m.from,
      p_wa_message_id: m.id,
    })
    await listo('paciente', res)
    return
  }

  // 3. El personal: el bot.
  if (r.staff) {
    const res = await atenderAlPersonal({ rpc, personal: r.staff, mensaje: m })
    await listo('personal', res)
    return
  }

  // 4. Un «sí» o un «no» escrito, si hay UNA orden esperando a ese teléfono.
  const escrito = decisionDelTexto(m.texto)
  if (escrito && r.pending_charge_id) {
    const res = await rpc('helios_patient_decision', {
      p_charge_id: r.pending_charge_id,
      p_decision: escrito,
      p_from_phone: m.from,
      p_wa_message_id: m.id,
    })
    await listo('paciente', res)
    return
  }

  // 5. El bot del paciente; si se calla, lo atiende una persona desde la app.
  const res = await atenderAlPaciente({ rpc, mensaje: m })
  await listo(res ? 'paciente' : 'nadie', res)
}

Deno.serve(async (req) => {
  const url = new URL(req.url)
  if (TOKEN === '' || !igualSeguro(url.searchParams.get('token') ?? '', TOKEN)) {
    return new Response('No autorizado', { status: 401 })
  }
  if (req.method !== 'POST') {
    return new Response('ok')
  }

  let body: unknown
  try {
    body = await req.json()
  } catch {
    return new Response('JSON inválido', { status: 400 })
  }

  try {
    for (const e of extraerEventos(body)) {
      if (e.kind === 'status') {
        await rpc('helios_whatsapp_status', {
          p_wa_message_id: e.id,
          p_status: e.status,
          p_error: e.error,
          p_at: horaDelEstado(e.timestamp),
        })
      } else {
        await mensaje(e)
      }
    }
  } catch (err) {
    console.error('whatsapp-webhook', err)
    return new Response('Error', { status: 500 })
  }

  // Lo que se encoló (las respuestas del bot, la bienvenida tras un «Sí»)
  // sale ya, sin esperar al cron de 10 s. Si falla, el cron lo manda.
  try {
    const r = await rpc<{ errores?: unknown[] }>('helios_dispatch_whatsapp_batch', { p_limit: 10 })
    // Los fallos pasajeros (se reintentan solos): la causa queda en el log.
    if (r?.errores?.length) console.warn('whatsapp-webhook despacho, fallos pasajeros', JSON.stringify(r.errores))
  } catch (err) {
    console.error('whatsapp-webhook despacho', err)
  }

  return new Response('ok')
})
