// ═══════════════════════════════════════════════════════════════════════════
// Helios — Lo que el webhook de WhatsApp entiende de cada mensaje (docs/00
// §15.3). Módulo puro, sin red ni base: lo prueba `logica.test.ts`
// (`npx tsx supabase/functions/whatsapp-webhook/logica.test.ts`).
// ═══════════════════════════════════════════════════════════════════════════

/** Un estado de entrega de un mensaje que mandó Helios. */
export type EventoDeEstado = {
  kind: 'status'
  id: string
  status: string
  error: Record<string, unknown> | null
  timestamp: string | null
}

/** Un mensaje que alguien le escribió a Helios. */
export type EventoDeMensaje = {
  kind: 'message'
  id: string
  from: string
  type: string
  /** Lo que se lee: el texto, o el título del botón que pulsó. */
  texto: string | null
  /** El id del botón que pulsó (de una plantilla o de un mensaje interactivo). */
  boton: string | null
  /** Una foto o un documento: su id en 360dialog y su tipo (para el lector de comprobantes). */
  adjunto: { id: string; mime: string } | null
  raw: Record<string, unknown>
}

export type Evento = EventoDeEstado | EventoDeMensaje

function fila(v: unknown): Record<string, unknown> | null {
  return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null
}

function lista(v: unknown): unknown[] {
  return Array.isArray(v) ? v : []
}

function texto(v: unknown): string | null {
  return typeof v === 'string' && v.trim() !== '' ? v : null
}

/**
 * Los eventos de un cuerpo del webhook. Acepta el formato de la Cloud API
 * (`entry[].changes[].value`, el de 360dialog) y, por si acaso, el de la API
 * on-premise (`messages` y `statuses` en la raíz).
 */
export function extraerEventos(body: unknown): Evento[] {
  const raiz = fila(body)
  if (!raiz) return []

  const valores: Record<string, unknown>[] = Array.isArray(raiz.entry)
    ? lista(raiz.entry).flatMap((e) =>
        lista(fila(e)?.changes)
          .map((c) => fila(fila(c)?.value))
          .filter((v): v is Record<string, unknown> => v !== null),
      )
    : [raiz]

  const eventos: Evento[] = []
  for (const valor of valores) {
    for (const s of lista(valor.statuses)) {
      const st = fila(s)
      const id = texto(st?.id)
      const status = texto(st?.status)
      if (!st || !id || !status) continue
      eventos.push({
        kind: 'status',
        id,
        status,
        error: fila(lista(st.errors)[0]),
        timestamp: texto(st.timestamp),
      })
    }

    for (const m of lista(valor.messages)) {
      const msg = fila(m)
      const id = texto(msg?.id)
      const from = texto(msg?.from)
      if (!msg || !id || !from) continue
      const type = texto(msg.type) ?? 'desconocido'
      const interactivo = fila(msg.interactive)
      const respuesta = fila(interactivo?.button_reply) ?? fila(interactivo?.list_reply)
      const boton = fila(msg.button)
      const media = fila(msg.image) ?? fila(msg.document)
      const mediaId = texto(media?.id)

      eventos.push({
        kind: 'message',
        id,
        from,
        type,
        texto:
          texto(fila(msg.text)?.body) ?? texto(respuesta?.title) ?? texto(boton?.text) ?? null,
        boton: texto(respuesta?.id) ?? texto(boton?.payload) ?? null,
        adjunto: mediaId ? { id: mediaId, mime: texto(media?.mime_type) ?? '' } : null,
        raw: msg,
      })
    }
  }
  return eventos
}

/** La hora de un estado de WhatsApp (segundos Unix como texto) en ISO, o null. */
export function horaDelEstado(timestamp: string | null): string | null {
  if (!timestamp || !/^\d+$/.test(timestamp)) return null
  return new Date(Number(timestamp) * 1000).toISOString()
}

export type Decision = { chargeId: string; decision: 'si' | 'no' }

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
const BOTON = new RegExp(`^(confirmar|rechazar):(${UUID})$`, 'i')

/** El botón de la pregunta al paciente: `confirmar:<id>` o `rechazar:<id>`. */
export function decisionDelBoton(id: string | null | undefined): Decision | null {
  const m = BOTON.exec((id ?? '').trim())
  if (!m) return null
  return { chargeId: m[2].toLowerCase(), decision: m[1].toLowerCase() === 'confirmar' ? 'si' : 'no' }
}

/** Minúsculas, sin acentos, sin signos ni emojis, con un espacio entre palabras. */
export function normalizar(t: string): string {
  return t
    .normalize('NFD')
    .replace(/\p{M}/gu, '')
    .toLowerCase()
    .replace(/[^a-z0-9ñ ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

const SI = new Set(['si', 'si acepto', 'acepto'])
const NO = new Set(['no', 'no acepto'])

/**
 * Un «sí» o un «no» escrito, de una lista cerrada (docs/00 §15.3): nada más se
 * interpreta. «Sí, acepto», «SI», «sí!» valen; «si claro pero…» no.
 */
export function decisionDelTexto(t: string | null | undefined): 'si' | 'no' | null {
  if (!t) return null
  const n = normalizar(t)
  if (SI.has(n)) return 'si'
  if (NO.has(n)) return 'no'
  return null
}

/** Comparación en tiempo constante, para el secreto de la URL. */
export function igualSeguro(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a)
  const eb = new TextEncoder().encode(b)
  let diff = ea.length ^ eb.length
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) {
    diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0)
  }
  return diff === 0
}
