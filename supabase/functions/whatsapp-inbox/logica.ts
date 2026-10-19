// ═══════════════════════════════════════════════════════════════════════════
// Helios — Lo que la Edge Function `whatsapp-inbox` decide sin red
//
// Qué peticiones del panel acepta, cómo las traduce a la Inbox API de
// 360dialog y cómo le cuenta al panel lo que el Inbox contestó. Sin Deno ni
// fetch, para probarlo con `npx tsx` como el webhook.
//
// Inbox API (https://docs.360dialog.com/docs/inbox/inbox-api/api-ref):
//   GET   /api/v1/chats/                 lista de chats (limit/offset, search, unread)
//   GET   /api/v1/messages/              mensajes de un chat (wa_id, before_time), del más nuevo al más viejo
//   POST  /api/v1/messages/              contestar (202 = en cola, 453 = ventana cerrada)
//   PATCH /api/v1/chats/{wa_id}/resolve/ marcar resuelto
//   GET   /api/v1/media/{id}/            un adjunto (sigue el 302 a la URL firmada)
//   GET   /api/v1/users/current/         ¿el token vale?
// Auth: `Authorization: Token <token>` de un usuario del grupo «App
// integration». La clave del canal (D360-API-KEY) no sirve aquí.
// ═══════════════════════════════════════════════════════════════════════════

/** Lo que cabe en una página. El Inbox da 100 por defecto; el panel pide menos. */
export const LIMITE_POR_DEFECTO = 30
export const LIMITE_MAXIMO = 100

/** El cuerpo de un mensaje de texto de WhatsApp no pasa de 4096 caracteres. */
export const MAX_TEXTO = 4096

/** Lo que el panel puede pedir. Todo lo demás es 404. */
export type Peticion =
  | { tipo: 'estado' }
  | {
      tipo: 'chats'
      busqueda: string | null
      sinLeer: boolean
      limite: number
      desde: number
    }
  | {
      tipo: 'mensajes'
      waId: string
      antesDe: number | null
      limite: number
      marcarRecibidos: boolean
    }
  | { tipo: 'enviar'; waId: string; texto: string }
  | { tipo: 'resolver'; waId: string; resuelto: boolean }
  | { tipo: 'adjunto'; id: string; mime: string | null }

export type PeticionInvalida = {
  error: 'ruta_desconocida' | 'peticion_invalida'
  detalle: string
}

/**
 * El wa_id es un teléfono canónico o un BSUID (identificador opaco que da
 * WhatsApp a quien oculta su número). Va en la ruta del Inbox, así que nada
 * de barras ni de rarezas: letras, dígitos, `.`, `_`, `-` y `+`, hasta 200.
 */
export function waIdValido(v: unknown): v is string {
  return typeof v === 'string' && /^[A-Za-z0-9._+-]{1,200}$/.test(v)
}

/** El id de un adjunto: numérico (los de WhatsApp) o un UUID (los subidos al Inbox). */
export function idDeAdjuntoValido(v: unknown): v is string {
  return typeof v === 'string' && /^[A-Za-z0-9-]{1,100}$/.test(v)
}

/** `image/jpeg`, `audio/ogg`… Solo tipo/subtipo, sin parámetros. */
export function mimeValido(v: unknown): v is string {
  return typeof v === 'string' && /^[a-z]+\/[a-z0-9.+-]{1,60}$/.test(v)
}

function entero(
  v: string | null,
  porDefecto: number,
  min: number,
  max: number,
): number {
  if (v === null || v === '') return porDefecto
  const n = Number(v)
  if (!Number.isInteger(n)) return porDefecto
  return Math.min(Math.max(n, min), max)
}

function si(v: string | null): boolean {
  return v === '1' || v === 'true'
}

/**
 * Lo que va después de `/whatsapp-inbox/` en la URL. Supabase la sirve como
 * `/whatsapp-inbox/…` o, según desde dónde se llame, `/functions/v1/whatsapp-inbox/…`.
 */
export function rutaRelativa(pathname: string): string[] {
  const partes = pathname.split('/').filter(Boolean)
  const i = partes.indexOf('whatsapp-inbox')
  return i === -1 ? partes : partes.slice(i + 1)
}

/** Traduce la petición del panel. `cuerpo` ya viene leído como JSON (o `null`). */
export function leerPeticion(
  metodo: string,
  url: URL,
  cuerpo: unknown,
): Peticion | PeticionInvalida {
  const [ruta, param, ...sobra] = rutaRelativa(url.pathname)
  const q = url.searchParams
  const invalida = (detalle: string): PeticionInvalida => ({
    error: 'peticion_invalida',
    detalle,
  })

  if (sobra.length > 0)
    return { error: 'ruta_desconocida', detalle: url.pathname }

  if (metodo === 'GET' && ruta === 'estado' && !param) return { tipo: 'estado' }

  if (metodo === 'GET' && ruta === 'chats' && !param) {
    const busqueda = (q.get('q') ?? '').trim().slice(0, 100)
    return {
      tipo: 'chats',
      busqueda: busqueda === '' ? null : busqueda,
      sinLeer: si(q.get('sin_leer')),
      limite: entero(q.get('limite'), LIMITE_POR_DEFECTO, 1, LIMITE_MAXIMO),
      desde: entero(q.get('desde'), 0, 0, 1_000_000),
    }
  }

  if (metodo === 'GET' && ruta === 'mensajes' && !param) {
    const waId = q.get('wa_id')
    if (!waIdValido(waId)) return invalida('wa_id')
    const antes = q.get('antes_de')
    const antesDe = antes === null || antes === '' ? null : Number(antes)
    if (antesDe !== null && !(Number.isFinite(antesDe) && antesDe > 0))
      return invalida('antes_de')
    return {
      tipo: 'mensajes',
      waId,
      antesDe: antesDe === null ? null : Math.floor(antesDe),
      limite: entero(q.get('limite'), LIMITE_POR_DEFECTO, 1, LIMITE_MAXIMO),
      marcarRecibidos: si(q.get('marcar')),
    }
  }

  if (metodo === 'POST' && ruta === 'mensajes' && !param) {
    const c = (cuerpo ?? {}) as Record<string, unknown>
    if (!waIdValido(c.wa_id)) return invalida('wa_id')
    const texto = typeof c.texto === 'string' ? c.texto.trim() : ''
    if (texto === '') return invalida('texto')
    if (texto.length > MAX_TEXTO) return invalida('texto_largo')
    return { tipo: 'enviar', waId: c.wa_id, texto }
  }

  if (metodo === 'POST' && ruta === 'resolver' && !param) {
    const c = (cuerpo ?? {}) as Record<string, unknown>
    if (!waIdValido(c.wa_id)) return invalida('wa_id')
    if (typeof c.resuelto !== 'boolean') return invalida('resuelto')
    return { tipo: 'resolver', waId: c.wa_id, resuelto: c.resuelto }
  }

  if (metodo === 'GET' && ruta === 'adjunto') {
    if (!idDeAdjuntoValido(param)) return invalida('id')
    const mime = q.get('mime')
    return { tipo: 'adjunto', id: param, mime: mimeValido(mime) ? mime : null }
  }

  return { error: 'ruta_desconocida', detalle: `${metodo} ${url.pathname}` }
}

/** La petición al Inbox que corresponde. `base` es la dirección del Inbox, sin barra final. */
export type PeticionAlInbox = {
  metodo: 'GET' | 'POST' | 'PATCH'
  url: string
  cuerpo?: Record<string, unknown>
}

export function peticionAlInbox(base: string, p: Peticion): PeticionAlInbox {
  const raiz = base.replace(/\/+$/, '')
  switch (p.tipo) {
    case 'estado':
      return { metodo: 'GET', url: `${raiz}/api/v1/users/current/` }
    case 'chats': {
      const q = new URLSearchParams({
        limit: String(p.limite),
        offset: String(p.desde),
      })
      if (p.busqueda) q.set('search', p.busqueda)
      if (p.sinLeer) q.set('unread', 'true')
      return { metodo: 'GET', url: `${raiz}/api/v1/chats/?${q}` }
    }
    case 'mensajes': {
      const q = new URLSearchParams({ wa_id: p.waId, limit: String(p.limite) })
      if (p.antesDe !== null) q.set('before_time', String(p.antesDe))
      if (p.marcarRecibidos) q.set('mark_as_received', '1')
      return { metodo: 'GET', url: `${raiz}/api/v1/messages/?${q}` }
    }
    case 'enviar':
      return {
        metodo: 'POST',
        url: `${raiz}/api/v1/messages/`,
        cuerpo: { wa_id: p.waId, type: 'text', text: { body: p.texto } },
      }
    case 'resolver':
      return {
        metodo: 'PATCH',
        url: `${raiz}/api/v1/chats/${encodeURIComponent(p.waId)}/resolve/`,
        cuerpo: { resolved: p.resuelto },
      }
    case 'adjunto': {
      const q = new URLSearchParams()
      if (p.mime) {
        const [tipo, subtipo] = p.mime.split('/')
        q.set('mime_type_type', tipo)
        q.set('mime_type_subtype', subtipo)
      }
      const s = q.toString()
      return {
        metodo: 'GET',
        url: `${raiz}/api/v1/media/${encodeURIComponent(p.id)}/${s ? `?${s}` : ''}`,
      }
    }
  }
}

/** Lo que el panel sabe explicar. */
export type CodigoDeError =
  | 'ventana_cerrada'
  | 'token_invalido'
  | 'sin_permiso_en_inbox'
  | 'cola_llena'
  | 'chat_desconocido'
  | 'adjunto_no_existe'
  | 'inbox_ocupado'
  | 'inbox_no_responde'
  | 'peticion_invalida'

/**
 * El error que se le cuenta al panel a partir de lo que contestó el Inbox.
 * `null` si fue bien. `esEstado` distingue el 403 de «el token no vale»
 * (al comprobarlo) del de «no puedes escribir en este chat».
 */
export function errorDelInbox(
  status: number,
  esEstado = false,
): { status: number; error: CodigoDeError } | null {
  if (status >= 200 && status < 300) return null
  if (status === 401) return { status: 502, error: 'token_invalido' }
  if (status === 403)
    return {
      status: 502,
      error: esEstado ? 'token_invalido' : 'sin_permiso_en_inbox',
    }
  if (status === 404) return { status: 404, error: 'adjunto_no_existe' }
  if (status === 452) return { status: 404, error: 'chat_desconocido' }
  if (status === 453) return { status: 409, error: 'ventana_cerrada' }
  if (status === 423) return { status: 429, error: 'cola_llena' }
  if (status === 429) return { status: 429, error: 'inbox_ocupado' }
  if (status === 400) return { status: 400, error: 'peticion_invalida' }
  return { status: 502, error: 'inbox_no_responde' }
}

/**
 * Una página del Inbox sin `next`/`previous`: son URLs con la dirección del
 * Inbox, que al panel no le hacen falta (pagina con `desde`).
 */
export function pagina(crudo: unknown): { count: number; results: unknown[] } {
  const c = (crudo ?? {}) as Record<string, unknown>
  return {
    count: typeof c.count === 'number' ? c.count : 0,
    results: Array.isArray(c.results) ? c.results : [],
  }
}
