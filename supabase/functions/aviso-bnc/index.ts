// ═══════════════════════════════════════════════════════════════════════════
// Helios — aviso-bnc: el SMS de pago móvil del BNC, desde el iPhone del CEO
//
// Helios y Ronda cobran en la misma cuenta del BNC. Cada SMS de «Pago Movil
// Recibido» dispara un Atajo del iPhone del CEO que lo manda aquí (y a Ronda).
// Es pública —el iPhone no tiene sesión de Supabase— y lo único que la separa
// de que cualquiera nos mande un pago inventado es la clave del encabezado
// `x-helios-clave` (secreto AVISO_BNC_CLAVE), que solo conocen este servidor y
// ese Atajo. Nada del cuerpo se mira antes de comprobarla.
//
// Lo demás (leer el texto, cotejarlo, aprobar o no) vive en la base:
// `helios_bank_sms_ingest` (20261015100000).
//
// Despliegue (sin Docker):
//   supabase functions deploy aviso-bnc --no-verify-jwt --use-api \
//     --project-ref ahyfbnfsbyzdoyjzjvfb
// ═══════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2'

/** Un SMS del BNC cabe holgado; más que esto no es un SMS. */
const MAX_BODY = 2000

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

/**
 * El Atajo manda JSON `{ "texto": "…", "remitente": "…" }`. Se admite también
 * el texto plano (sin remitente), por si alguien lo configura con «Archivo» en
 * vez de «JSON».
 */
function leerAviso(raw: string, contentType: string): { texto: string | null; remitente: string | null } {
  if (contentType.includes('application/json')) {
    try {
      const body = JSON.parse(raw) as Record<string, unknown>
      const texto = body.texto ?? body.text ?? body.mensaje
      const remitente = body.remitente ?? body.sender
      return {
        texto: typeof texto === 'string' ? texto : null,
        remitente: typeof remitente === 'string' ? remitente : null,
      }
    } catch {
      return { texto: null, remitente: null }
    }
  }
  return { texto: raw, remitente: null }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })

  const clave = Deno.env.get('AVISO_BNC_CLAVE')
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

  if (!clave || !supabaseUrl || !serviceKey) {
    console.error('faltan variables de entorno')
    return new Response('not configured', { status: 500 })
  }

  const recibida = req.headers.get('x-helios-clave') ?? ''
  if (!timingSafeEqual(recibida, clave)) {
    console.warn('aviso-bnc: clave inválida')
    return new Response('unauthorized', { status: 401 })
  }

  // --- A partir de aquí el cuerpo es de fiar ------------------------------

  const raw = await req.text()
  const aviso = leerAviso(raw, req.headers.get('content-type') ?? '')
  const texto = aviso.texto?.trim()
  if (!texto) return new Response('falta el texto', { status: 400 })
  if (texto.length > MAX_BODY) return new Response('texto demasiado largo', { status: 413 })

  const admin = createClient(supabaseUrl, serviceKey)
  const { data, error } = await admin.rpc('helios_bank_sms_ingest', {
    p_body: texto,
    p_sender: aviso.remitente,
  })

  if (error) {
    console.error('aviso-bnc: no se pudo guardar', error.message)
    return new Response('error', { status: 500 })
  }

  return Response.json(data)
})
