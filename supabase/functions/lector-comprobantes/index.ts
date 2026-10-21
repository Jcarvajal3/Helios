// ═══════════════════════════════════════════════════════════════════════════
// Helios — lector-comprobantes: lee las capturas de pago que los pacientes
// mandan por WhatsApp (docs/03 §4.2 y §5)
//
// La despiertan el webhook de WhatsApp (al encolar una captura) y el cron
// `helios_lector_despertar` (cada minuto, si quedó algo pendiente), las dos
// por `helios_lector_despertar` en la base. Contesta 202 al momento y lee en
// segundo plano: quien la llama no espera al modelo.
//
// Por cada captura que toma (`lector_tomar`):
//   1. baja el adjunto de 360dialog y lo guarda en el bucket privado
//      `payment-receipts` (bot/<paciente>/<lectura>.<ext>), como prueba;
//   2. se lo pasa a Claude con un esquema de salida cerrado (logica.ts);
//   3. le pasa a la base lo leído (`lector_leido`), que es la que decide.
// Si algo falla, `lector_fallo`: se reintenta hasta tres veces y luego va al
// equipo.
//
// Es pública (sin JWT): la protege la clave del encabezado `x-helios-clave`,
// que conocen esta función (LECTOR_CLAVE) y el vault (`lector_clave`).
//
// Secretos (supabase secrets set … --project-ref ahyfbnfsbyzdoyjzjvfb):
//   ANTHROPIC_API_KEY   la clave de la API de Anthropic
//   LECTOR_CLAVE        la misma que el secreto `lector_clave` del vault
// En el vault: `lector_url` (la URL de esta función) y `lector_clave`.
//
// Despliegue (sin Docker):
//   supabase functions deploy lector-comprobantes --no-verify-jwt --use-api \
//     --project-ref ahyfbnfsbyzdoyjzjvfb
// ═══════════════════════════════════════════════════════════════════════════

import Anthropic from 'npm:@anthropic-ai/sdk@1'
import { createClient } from 'npm:@supabase/supabase-js@2'
import { encodeBase64 } from 'jsr:@std/encoding@1/base64'

import {
  ESQUEMA,
  INSTRUCCIONES,
  esComprobante,
  extensionDe,
  igualSeguro,
  normalizar,
  urlDeDescarga,
} from './logica.ts'

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined

const MODELO = 'claude-sonnet-5-5'
const CLAVE = Deno.env.get('LECTOR_CLAVE') ?? ''
const MAX_BYTES = 10 * 1024 * 1024
/** Lo que se lee en una despertada; lo que quede, lo recoge la siguiente. */
const MAX_POR_VUELTA = 12
const MAX_MS = 110_000

const db = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
  { auth: { persistSession: false, autoRefreshToken: false } },
)

const claude = new Anthropic({ apiKey: Deno.env.get('ANTHROPIC_API_KEY') ?? '' })

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args)
  if (error) throw new Error(`${fn}: ${error.message}`)
  return data as T
}

type Tomada = { id: string; media_id: string; mime: string; profile_id: string }
type Config = { d360_api_key: string | null; d360_base_url: string | null }

/** Baja un adjunto de 360dialog: primero su URL, luego el archivo. */
async function bajarAdjunto(mediaId: string, cfg: Config): Promise<Uint8Array> {
  if (!cfg.d360_api_key || !cfg.d360_base_url) throw new Error('Falta la configuración de 360dialog')
  const base = cfg.d360_base_url.replace(/\/+$/, '')
  const cabeceras = { 'D360-API-KEY': cfg.d360_api_key }

  const meta = await fetch(`${base}/${encodeURIComponent(mediaId)}`, { headers: cabeceras })
  if (!meta.ok) throw new Error(`360dialog no dio el adjunto (${meta.status})`)
  const { url } = (await meta.json()) as { url?: string }
  if (!url) throw new Error('360dialog no devolvió la URL del adjunto')

  const archivo = await fetch(urlDeDescarga(url, base), { headers: cabeceras })
  if (!archivo.ok) throw new Error(`No se pudo bajar el adjunto (${archivo.status})`)
  const bytes = new Uint8Array(await archivo.arrayBuffer())
  if (bytes.byteLength === 0) throw new Error('El adjunto viene vacío')
  if (bytes.byteLength > MAX_BYTES) throw new Error('El adjunto pesa más de 10 MB')
  return bytes
}

/** Le pasa la captura a Claude y devuelve lo que leyó, el modelo que respondió y su consumo. */
async function leer(bytes: Uint8Array, mime: string) {
  const data = encodeBase64(bytes)
  const adjunto =
    mime === 'application/pdf'
      ? { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data } }
      : { type: 'image', source: { type: 'base64', media_type: mime, data } }

  // `fallbacks: 'default'`: si el clasificador de seguridad declina, el
  // servidor reintenta con otro modelo dentro de la misma llamada.
  const params = {
    model: MODELO,
    max_tokens: 4000,
    betas: ['server-side-fallback-2026-07-01'],
    fallbacks: 'default',
    system: INSTRUCCIONES,
    output_config: { effort: 'low', format: { type: 'json_schema', schema: ESQUEMA } },
    messages: [
      { role: 'user', content: [adjunto, { type: 'text', text: 'Transcribe los datos de este comprobante.' }] },
    ],
  }
  const respuesta = await claude.beta.messages.create(
    params as unknown as Parameters<typeof claude.beta.messages.create>[0],
  ) as Anthropic.Beta.Messages.BetaMessage

  if (respuesta.stop_reason === 'refusal') throw new Error('El modelo declinó leer la captura')
  if (respuesta.stop_reason === 'max_tokens') throw new Error('La lectura se cortó (max_tokens)')

  const texto = respuesta.content.find((b) => b.type === 'text')
  if (!texto || texto.type !== 'text') throw new Error('El modelo no devolvió texto')
  const leido: unknown = JSON.parse(texto.text)
  if (!esComprobante(leido)) throw new Error('La respuesta del modelo no tiene la forma esperada')

  return { leido, modelo: respuesta.model, consumo: respuesta.usage }
}

async function procesar(t: Tomada, cfg: Config): Promise<void> {
  try {
    const bytes = await bajarAdjunto(t.media_id, cfg)

    const ruta = `bot/${t.profile_id}/${t.id}.${extensionDe(t.mime)}`
    const subida = await db.storage
      .from('payment-receipts')
      .upload(ruta, bytes, { contentType: t.mime, upsert: true })
    if (subida.error) throw new Error(`No se pudo guardar la captura: ${subida.error.message}`)

    const { leido, modelo, consumo } = await leer(bytes, t.mime)
    const r = await rpc<{ status?: string }>('lector_leido', {
      p_id: t.id,
      p_receipt_path: ruta,
      p_extraction: leido,
      p_datos: normalizar(leido),
      p_model: modelo,
      p_usage: consumo,
    })
    console.log('lector: leída', { id: t.id, status: r?.status })
  } catch (err) {
    const mensaje = err instanceof Error ? err.message : String(err)
    console.error('lector: no se pudo leer', { id: t.id, mensaje })
    try {
      await rpc('lector_fallo', { p_id: t.id, p_error: mensaje })
    } catch (e) {
      console.error('lector: tampoco se pudo anotar el fallo', e)
    }
  }
}

/** Lee lo pendiente, de tres en tres, hasta vaciar la cola o agotar el tiempo. */
async function vuelta(): Promise<void> {
  const inicio = Date.now()
  let leidas = 0
  try {
    const cfg = await rpc<Config>('lector_config', {})
    while (leidas < MAX_POR_VUELTA && Date.now() - inicio < MAX_MS) {
      const tomadas = await rpc<Tomada[]>('lector_tomar', { p_limit: 3 })
      if (!tomadas || tomadas.length === 0) break
      await Promise.all(tomadas.map((t) => procesar(t, cfg)))
      leidas += tomadas.length
    }
    // Los mensajes que dejó la base (pedir la referencia, el duplicado) salen ya.
    if (leidas > 0) await rpc('helios_dispatch_whatsapp_batch', { p_limit: 10 })
  } catch (err) {
    console.error('lector: vuelta', err)
  }
}

Deno.serve((req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })
  if (CLAVE === '' || !igualSeguro(req.headers.get('x-helios-clave') ?? '', CLAVE)) {
    return new Response('unauthorized', { status: 401 })
  }

  const trabajo = vuelta()
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(trabajo)
  return new Response('leyendo', { status: 202 })
})
