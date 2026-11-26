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
// Si algo falla, `lector_fallo`: se reintenta hasta tres veces, con dos
// minutos de espera entre una y otra, y luego va al equipo con su captura.
//
// Lee también las fotos de la cédula con las que los pacientes confirman su
// pago en cuotas (docs/00 §15.11; `lector_cedula_tomar`): la baja al bucket
// privado `patient-ids` (<perfil>/<wamid>.<ext>, la ruta la fija la base),
// Claude transcribe el número y el nombre y la base los compara
// (`lector_cedula_leida`). La orden ya está confirmada: lo que no cuadre es
// una alerta para el equipo. Los fallos, igual: tres intentos
// (`lector_cedula_fallo`). Y borra del bucket los archivos de las fotos que
// borró el reinicio de la capacitación (`lector_cedula_por_borrar`): desde SQL
// no se puede.
//
// Lee, por último, las capturas de pago de Helios Lab (docs/09 §5.3;
// `lector_lab_tomar`): a diferencia de las de WhatsApp, el médico ya las subió
// al bucket privado `lab-comprobantes` (`storage_path`), así que se bajan de
// ahí y no de 360dialog. Claude las lee con el mismo esquema e instrucciones
// que un comprobante de pago y la base decide (`lector_lab_leido`: `cuadra` o
// `para_revisar`). Los fallos, igual: tres intentos (`lector_lab_fallo`). La
// despierta también `helios_lector_despertar`, que cuenta las lecturas de Lab
// pendientes.
//
// Es pública (sin JWT): la protege la clave del encabezado `x-helios-clave`,
// que conocen esta función (LECTOR_CLAVE) y el vault (`lector_clave`).
//
// Secretos (supabase secrets set … --project-ref ahyfbnfsbyzdoyjzjvfb):
//   ANTHROPIC_API_KEY   la clave de la API de Anthropic
//   LECTOR_CLAVE        la misma que el secreto `lector_clave` del vault
//   LECTOR_PROVEEDOR    `claude` (por defecto) o `gemini`. Provisional
//                       (2026-11-26): la cuenta de Anthropic se quedó sin
//                       crédito y el lector pasa a Gemini mientras se recarga.
//                       Se cambia sin desplegar: basta con el secreto.
//   GEMINI_API_KEY      la clave de la API de Gemini (Google AI Studio)
//   GEMINI_MODEL        opcional; por defecto `gemini-3.8-flash` (Google retiró el 2.5)
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
  ESQUEMA_CEDULA,
  INSTRUCCIONES,
  INSTRUCCIONES_CEDULA,
  esCedula,
  esComprobante,
  extensionDe,
  igualSeguro,
  mimeDeLab,
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

/** Quién lee: Claude salvo que el secreto `LECTOR_PROVEEDOR` diga `gemini`. */
const PROVEEDOR = (Deno.env.get('LECTOR_PROVEEDOR') ?? 'claude').trim().toLowerCase() === 'gemini' ? 'gemini' : 'claude'
const GEMINI_KEY = Deno.env.get('GEMINI_API_KEY') ?? ''
const GEMINI_MODELO = (Deno.env.get('GEMINI_MODEL') ?? '').trim() || 'gemini-3.8-flash'

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args)
  if (error) throw new Error(`${fn}: ${error.message}`)
  return data as T
}

type Tomada = { id: string; media_id: string; mime: string; profile_id: string }
type CedulaTomada = { id: string; media_id: string; mime: string; ruta: string; guardada: boolean }
type LabTomada = { id: string; muestra_id: string; storage_path: string; mime: string }
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

/** Le pasa un adjunto al modelo (Claude o Gemini, según `PROVEEDOR`) con unas instrucciones y un esquema cerrados. */
function transcribir(bytes: Uint8Array, mime: string, instrucciones: string, esquema: unknown, pedido: string) {
  return PROVEEDOR === 'gemini'
    ? transcribirConGemini(bytes, mime, instrucciones, esquema, pedido)
    : transcribirConClaude(bytes, mime, instrucciones, esquema, pedido)
}

type RespuestaGemini = {
  candidates?: Array<{ finishReason?: string; content?: { parts?: Array<{ text?: string; thought?: boolean }> } }>
  promptFeedback?: { blockReason?: string }
  usageMetadata?: unknown
  modelVersion?: string
  error?: { message?: string }
}

/**
 * Provisional: los modelos que esta clave puede usar para leer, para anotarlos
 * junto al error y elegir otro con el secreto `GEMINI_MODEL`. Nunca falla.
 */
async function modelosDisponibles(): Promise<string> {
  try {
    const r = await fetch('https://generativelanguage.googleapis.com/v1beta/models?pageSize=200', {
      headers: { 'x-goog-api-key': GEMINI_KEY },
      signal: AbortSignal.timeout(5_000),
    })
    if (!r.ok) return ''
    const { models } = (await r.json()) as { models?: Array<{ name?: string; supportedGenerationMethods?: string[] }> }
    const nombres = (models ?? [])
      .filter((m) => m.supportedGenerationMethods?.includes('generateContent'))
      .map((m) => (m.name ?? '').replace(/^models\//, ''))
      .filter((n) => /gemini/.test(n) && !/(tts|image|audio|live|embedding)/.test(n))
    return nombres.length ? ` · Modelos disponibles: ${nombres.join(', ')}` : ''
  } catch {
    return ''
  }
}

/** Una llamada a `generateContent`, con 30 s como mucho: con tres, la vuelta sigue cabiendo en el tiempo de la función. */
function llamarAGemini(data: string, mime: string, instrucciones: string, esquema: unknown, pedido: string): Promise<Response> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(GEMINI_MODELO)}:generateContent`
  // Transcribir no necesita pensar mucho: los Gemini 3 aceptan `thinkingLevel`
  // y con «low» responden en segundos. Y con un tope de tiempo: si no, la
  // función se corta sin anotar el fallo y la lectura se queda «leyendo».
  const pensar = /^gemini-3/.test(GEMINI_MODELO) ? { thinkingConfig: { thinkingLevel: 'low' } } : {}
  return fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-goog-api-key': GEMINI_KEY },
    signal: AbortSignal.timeout(30_000),
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: instrucciones }] },
      contents: [{ role: 'user', parts: [{ inlineData: { mimeType: mime, data } }, { text: pedido }] }],
      generationConfig: { temperature: 0, responseMimeType: 'application/json', responseJsonSchema: esquema, ...pensar },
    }),
  })
}

/**
 * Lo mismo con Gemini (API REST de Google AI Studio): el adjunto va en línea,
 * las instrucciones como `systemInstruction` y el esquema como
 * `responseJsonSchema`, así que devuelve el mismo JSON que Claude y la base no
 * nota la diferencia (salvo en `model` y `usage`).
 */
async function transcribirConGemini(bytes: Uint8Array, mime: string, instrucciones: string, esquema: unknown, pedido: string) {
  if (GEMINI_KEY === '') throw new Error('Falta el secreto GEMINI_API_KEY')
  const data = encodeBase64(bytes)

  // «Alta demanda» (503), cuota (429) o un 500 de Google son pasajeros: se
  // reintenta en la misma llamada (a los 3 y a los 8 s) antes de darla por
  // fallida, que si no gasta uno de los tres intentos del lector cada vez.
  const ESPERAS_MS = [0, 3_000, 8_000]
  let http: Response | null = null
  let respuesta: RespuestaGemini = {}
  try {
    for (const espera of ESPERAS_MS) {
      if (espera > 0) await new Promise((r) => setTimeout(r, espera))
      http = await llamarAGemini(data, mime, instrucciones, esquema, pedido)
      respuesta = (await http.json().catch(() => ({}))) as RespuestaGemini
      if (![429, 500, 503].includes(http.status)) break
      console.warn('lector: Gemini ocupado, se reintenta', { status: http.status })
    }
  } catch (err) {
    const mensaje = err instanceof Error ? err.message : String(err)
    throw new Error(`Gemini (${GEMINI_MODELO}): ${mensaje}${await modelosDisponibles()}`)
  }
  if (!http || !http.ok) {
    throw new Error(`Gemini ${http?.status ?? '?'} (${GEMINI_MODELO}): ${(respuesta.error?.message ?? '').slice(0, 200)}${await modelosDisponibles()}`)
  }

  const candidato = respuesta.candidates?.[0]
  if (!candidato) throw new Error(`Gemini no devolvió respuesta (${respuesta.promptFeedback?.blockReason ?? 'sin motivo'})`)
  if (candidato.finishReason === 'MAX_TOKENS') throw new Error('La lectura se cortó (MAX_TOKENS)')
  if (candidato.finishReason && candidato.finishReason !== 'STOP') {
    throw new Error(`El modelo declinó leer el adjunto (${candidato.finishReason})`)
  }
  const texto = (candidato.content?.parts ?? []).filter((p) => !p.thought).map((p) => p.text ?? '').join('')
  if (texto.trim() === '') throw new Error('El modelo no devolvió texto')
  const leido: unknown = JSON.parse(texto)
  return { leido, modelo: respuesta.modelVersion ?? GEMINI_MODELO, consumo: respuesta.usageMetadata ?? null }
}

/** Le pasa un adjunto a Claude con unas instrucciones y un esquema cerrados; devuelve el JSON, el modelo y su consumo. */
async function transcribirConClaude(bytes: Uint8Array, mime: string, instrucciones: string, esquema: unknown, pedido: string) {
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
    system: instrucciones,
    output_config: { effort: 'low', format: { type: 'json_schema', schema: esquema } },
    messages: [
      { role: 'user', content: [adjunto, { type: 'text', text: pedido }] },
    ],
  }
  const respuesta = await claude.beta.messages.create(
    params as unknown as Parameters<typeof claude.beta.messages.create>[0],
  ) as Anthropic.Beta.Messages.BetaMessage

  if (respuesta.stop_reason === 'refusal') throw new Error('El modelo declinó leer el adjunto')
  if (respuesta.stop_reason === 'max_tokens') throw new Error('La lectura se cortó (max_tokens)')

  const texto = respuesta.content.find((b) => b.type === 'text')
  if (!texto || texto.type !== 'text') throw new Error('El modelo no devolvió texto')
  const leido: unknown = JSON.parse(texto.text)
  return { leido, modelo: respuesta.model, consumo: respuesta.usage }
}

/** Le pasa la captura a Claude y devuelve lo que leyó, el modelo que respondió y su consumo. */
async function leer(bytes: Uint8Array, mime: string) {
  const r = await transcribir(bytes, mime, INSTRUCCIONES, ESQUEMA, 'Transcribe los datos de este comprobante.')
  if (!esComprobante(r.leido)) throw new Error('La respuesta del modelo no tiene la forma esperada')
  return { ...r, leido: r.leido }
}

/**
 * Una foto de cédula: la baja de 360dialog y la sube al bucket (o, si ya se
 * subió en un intento anterior, la lee de ahí), y le pasa a la base lo que
 * leyó el modelo.
 */
async function procesarCedula(t: CedulaTomada, cfg: Config): Promise<void> {
  try {
    let bytes: Uint8Array
    if (t.guardada) {
      const bajada = await db.storage.from('patient-ids').download(t.ruta)
      if (bajada.error) throw new Error(`No se pudo leer la cédula del bucket: ${bajada.error.message}`)
      bytes = new Uint8Array(await bajada.data.arrayBuffer())
    } else {
      bytes = await bajarAdjunto(t.media_id, cfg)
      const subida = await db.storage
        .from('patient-ids')
        .upload(t.ruta, bytes, { contentType: t.mime, upsert: true })
      if (subida.error) throw new Error(`No se pudo guardar la cédula: ${subida.error.message}`)
      // El reinicio de la capacitación la borró mientras se subía: no queda nada.
      if (!(await rpc<boolean>('lector_cedula_guardada', { p_id: t.id }))) {
        const borrado = await db.storage.from('patient-ids').remove([t.ruta])
        if (borrado.error) console.error('lector: no se pudo borrar la cédula huérfana', { id: t.id, mensaje: borrado.error.message })
        return
      }
    }

    const r = await transcribir(bytes, t.mime, INSTRUCCIONES_CEDULA, ESQUEMA_CEDULA, 'Transcribe los datos de esta cédula.')
    if (!esCedula(r.leido)) throw new Error('La respuesta del modelo no tiene la forma esperada')
    const status = await rpc<string>('lector_cedula_leida', {
      p_id: t.id,
      p_extraction: r.leido,
      p_model: r.modelo,
      p_usage: r.consumo,
    })
    console.log('lector: cédula leída', { id: t.id, status })
  } catch (err) {
    const mensaje = err instanceof Error ? err.message : String(err)
    console.error('lector: no se pudo leer la cédula', { id: t.id, mensaje })
    try {
      await rpc('lector_cedula_fallo', { p_id: t.id, p_error: mensaje })
    } catch (e) {
      console.error('lector: tampoco se pudo anotar el fallo de la cédula', e)
    }
  }
}

/**
 * Una captura de pago de Helios Lab: la baja del bucket `lab-comprobantes`,
 * la lee con el mismo esquema que un comprobante y le pasa a la base lo leído.
 */
async function procesarLab(t: LabTomada): Promise<void> {
  try {
    const mime = mimeDeLab(t.mime)
    if (!mime) throw new Error(`Tipo de archivo no soportado (${t.mime})`)
    const bajada = await db.storage.from('lab-comprobantes').download(t.storage_path)
    if (bajada.error) throw new Error(`No se pudo leer la captura del bucket: ${bajada.error.message}`)
    const bytes = new Uint8Array(await bajada.data.arrayBuffer())
    if (bytes.byteLength === 0) throw new Error('El archivo viene vacío')
    if (bytes.byteLength > MAX_BYTES) throw new Error('El archivo pesa más de 10 MB')

    const { leido } = await leer(bytes, mime)
    const r = await rpc<{ pago_estado?: string }>('lector_lab_leido', { p_id: t.id, p_lectura: leido })
    console.log('lector: captura de Lab leída', { id: t.id, muestra: t.muestra_id, pago: r?.pago_estado })
  } catch (err) {
    const mensaje = err instanceof Error ? err.message : String(err)
    console.error('lector: no se pudo leer la captura de Lab', { id: t.id, mensaje })
    try {
      await rpc('lector_lab_fallo', { p_id: t.id, p_error: mensaje })
    } catch (e) {
      console.error('lector: tampoco se pudo anotar el fallo de Lab', e)
    }
  }
}

async function procesar(t: Tomada, cfg: Config): Promise<void> {
  // La ruta de la captura una vez guardada: va también con un fallo, para
  // que el equipo la vea.
  let guardada: string | null = null
  try {
    const bytes = await bajarAdjunto(t.media_id, cfg)

    const ruta = `bot/${t.profile_id}/${t.id}.${extensionDe(t.mime)}`
    const subida = await db.storage
      .from('payment-receipts')
      .upload(ruta, bytes, { contentType: t.mime, upsert: true })
    if (subida.error) throw new Error(`No se pudo guardar la captura: ${subida.error.message}`)
    guardada = ruta

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
      await rpc('lector_fallo', { p_id: t.id, p_error: mensaje, p_receipt_path: guardada })
    } catch (e) {
      console.error('lector: tampoco se pudo anotar el fallo', e)
    }
  }
}

/**
 * Borra del bucket los archivos de las fotos que borró el reinicio de la
 * capacitación. Si falla, se reintenta en una vuelta posterior: lo que se tomó
 * vuelve a estar disponible a los dos minutos.
 */
async function borrarCedulas(): Promise<void> {
  try {
    while (true) {
      const filas = await rpc<Array<{ id: string; ruta: string }>>('lector_cedula_por_borrar', { p_limit: 50 })
      if (!filas || filas.length === 0) return
      const { error } = await db.storage.from('patient-ids').remove(filas.map((f) => f.ruta))
      if (error) throw new Error(error.message)
      await rpc('lector_cedula_borrada', { p_ids: filas.map((f) => f.id) })
    }
  } catch (err) {
    console.error('lector: no se pudieron borrar las cédulas', err)
  }
}

/** Lee lo pendiente, de tres en tres, hasta vaciar la cola o agotar el tiempo: primero las cédulas, luego las capturas y al final las de Lab. */
async function vuelta(): Promise<void> {
  const inicio = Date.now()
  let leidas = 0
  await borrarCedulas()
  try {
    const cfg = await rpc<Config>('lector_config', {})
    while (leidas < MAX_POR_VUELTA && Date.now() - inicio < MAX_MS) {
      const cedulas = await rpc<CedulaTomada[]>('lector_cedula_tomar', { p_limit: 3 })
      if (!cedulas || cedulas.length === 0) break
      await Promise.all(cedulas.map((t) => procesarCedula(t, cfg)))
      leidas += cedulas.length
    }
    leidas = 0
    while (leidas < MAX_POR_VUELTA && Date.now() - inicio < MAX_MS) {
      const tomadas = await rpc<Tomada[]>('lector_tomar', { p_limit: 3 })
      if (!tomadas || tomadas.length === 0) break
      await Promise.all(tomadas.map((t) => procesar(t, cfg)))
      leidas += tomadas.length
    }
    // Los mensajes que dejó la base (pedir la referencia, el duplicado) salen ya.
    if (leidas > 0) await rpc('helios_dispatch_whatsapp_batch', { p_limit: 10 })
    // Helios Lab: sin WhatsApp de por medio, no hay mensajes que despachar.
    let lab = 0
    while (lab < MAX_POR_VUELTA && Date.now() - inicio < MAX_MS) {
      const filas = await rpc<LabTomada[]>('lector_lab_tomar', { p_limit: 3 })
      if (!filas || filas.length === 0) break
      await Promise.all(filas.map((t) => procesarLab(t)))
      lab += filas.length
    }
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
