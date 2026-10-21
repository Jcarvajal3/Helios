import {
  booleano,
  comoFila,
  comoLista,
  filaONula,
  numeroONulo,
  textoONulo,
} from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// El inbox de WhatsApp: lo que el panel entiende de un chat y de un mensaje
// del Inbox de 360dialog (los pasa tal cual la Edge Function `whatsapp-inbox`).
//
// Un mensaje trae `waba_payload`: el mensaje de WhatsApp como lo manda Meta
// (`type` y un objeto con el nombre del tipo: `text.body`, `image.id`…). Aquí
// se reduce a lo que se pinta: un texto, un adjunto o una línea que dice qué
// era. Sin red, para probarlo con `npx tsx`.
// ═══════════════════════════════════════════════════════════════════════════

export type Chat = {
  /** El id con el que se le habla al Inbox: un teléfono o un BSUID (opaco). */
  waId: string
  /** El teléfono, si WhatsApp lo comparte. Puede no venir. */
  telefono: string | null
  /** El nombre de su perfil de WhatsApp, o `null`. */
  nombre: string | null
  iniciales: string
  /** Mensajes que el equipo aún no ha abierto. */
  sinLeer: number
  resuelto: boolean
  /** Hasta cuándo se le puede escribir texto libre (ms). `null` si no se sabe. */
  ventanaHasta: number | null
  ultimo: Mensaje | null
  etiquetas: string[]
  /** Quién es para Helios, si la base lo sabe (`admin_whatsapp_inbox_contacts`). */
  quien: QuienEs | null
}

/**
 * Un médico (o su secretaria): un número registrado para el bot. Un paciente:
 * un perfil con ese teléfono. Si es las dos cosas, gana médico, como en el bot.
 */
export type QuienEs =
  | {
      tipo: 'medico'
      nombre: string | null
      /** `cajero` es la secretaria; `gerente`, el administrador (el médico). */
      rol: string | null
      merchantId: string | null
      clinica: string | null
    }
  | { tipo: 'paciente'; nombre: string | null; profileId: string | null }

/** El filtro de la lista: solo los chats de un lado. */
export type FiltroDeQuien = 'medicos' | 'pacientes'

export function leerQuien(v: unknown): QuienEs | null {
  const q = filaONula(v)
  if (!q) return null
  if (q.tipo === 'medico')
    return {
      tipo: 'medico',
      nombre: textoONulo(q.nombre),
      rol: textoONulo(q.rol),
      merchantId: textoONulo(q.merchant_id),
      clinica: textoONulo(q.clinica),
    }
  if (q.tipo === 'paciente')
    return {
      tipo: 'paciente',
      nombre: textoONulo(q.nombre),
      profileId: textoONulo(q.profile_id),
    }
  return null
}

/** La pastilla del chat: «Médico», «Secretaria» o «Paciente». */
export function rotuloDeQuien(q: QuienEs): string {
  if (q.tipo === 'paciente') return 'Paciente'
  return q.rol === 'cajero' ? 'Secretaria' : 'Médico'
}

export type Adjunto = {
  tipo: 'imagen' | 'audio' | 'video' | 'documento' | 'sticker'
  /** El id del adjunto en el Inbox. Sin él (un adjunto mandado por enlace) no se puede pedir. */
  id: string | null
  /** Si se mandó por enlace, el enlace. */
  enlace: string | null
  mime: string | null
  nombreDeArchivo: string | null
}

export type Mensaje = {
  id: string
  /** Lo mandó Helios (el inbox, el bot o una plantilla). */
  deHelios: boolean
  /** Cuándo, en ms. */
  hora: number | null
  /** Lo que se lee: el texto, el pie de foto o la descripción del tipo. */
  texto: string | null
  /** Cuando no es texto, qué era: «Ubicación», «Plantilla: aviso_cuota»… */
  rotulo: string | null
  adjunto: Adjunto | null
  /** Quién del Inbox lo mandó, si fue a mano. */
  autor: string | null
  estado: 'enviado' | 'entregado' | 'leido' | null
}

const ADJUNTOS: Record<string, Adjunto['tipo']> = {
  image: 'imagen',
  audio: 'audio',
  voice: 'audio',
  video: 'video',
  document: 'documento',
  sticker: 'sticker',
}

/** Un instante POSIX (segundos, en número o en texto) en ms. */
function aMs(v: unknown): number | null {
  const n = numeroONulo(v)
  return n === null || n <= 0 ? null : Math.round(n * 1000)
}

/** Lo que dice un mensaje de WhatsApp, sea cual sea su tipo. */
export function leerContenido(
  payload: unknown,
): Pick<Mensaje, 'texto' | 'rotulo' | 'adjunto'> {
  const p = comoFila(payload)
  const tipo = textoONulo(p.type) ?? 'desconocido'
  const cuerpo = comoFila(p[tipo])

  if (tipo === 'text')
    return { texto: textoONulo(cuerpo.body), rotulo: null, adjunto: null }

  if (tipo in ADJUNTOS) {
    return {
      texto: textoONulo(cuerpo.caption),
      rotulo: null,
      adjunto: {
        tipo: ADJUNTOS[tipo],
        id: textoONulo(cuerpo.id),
        enlace: textoONulo(cuerpo.link),
        mime: textoONulo(cuerpo.mime_type),
        nombreDeArchivo: textoONulo(cuerpo.filename),
      },
    }
  }

  switch (tipo) {
    case 'button':
      // La respuesta rápida de una plantilla.
      return { texto: textoONulo(cuerpo.text), rotulo: 'Botón', adjunto: null }
    case 'interactive': {
      const respuesta =
        filaONula(cuerpo.button_reply) ?? filaONula(cuerpo.list_reply)
      if (respuesta)
        return {
          texto: textoONulo(respuesta.title),
          rotulo: 'Botón',
          adjunto: null,
        }
      // Uno nuestro, con botones: el texto va en `body.text`.
      return {
        texto: textoONulo(comoFila(cuerpo.body).text),
        rotulo: 'Con botones',
        adjunto: null,
      }
    }
    case 'template':
      return {
        texto: null,
        rotulo: `Plantilla: ${textoONulo(cuerpo.name) ?? 'sin nombre'}`,
        adjunto: null,
      }
    case 'reaction':
      return {
        texto: textoONulo(cuerpo.emoji),
        rotulo: 'Reacción',
        adjunto: null,
      }
    case 'location': {
      const nombre = textoONulo(cuerpo.name) ?? textoONulo(cuerpo.address)
      const lat = numeroONulo(cuerpo.latitude)
      const lon = numeroONulo(cuerpo.longitude)
      const donde =
        lat !== null && lon !== null
          ? `${lat.toFixed(5)}, ${lon.toFixed(5)}`
          : null
      return {
        texto: [nombre, donde].filter(Boolean).join(' · ') || null,
        rotulo: 'Ubicación',
        adjunto: null,
      }
    }
    case 'contacts': {
      const nombres = comoLista(p.contacts)
        .map((c) => textoONulo(comoFila(comoFila(c).name).formatted_name))
        .filter((n): n is string => n !== null)
      return {
        texto: nombres.join(', ') || null,
        rotulo: 'Contacto',
        adjunto: null,
      }
    }
    case 'unsupported':
      return {
        texto: null,
        rotulo: 'Mensaje que WhatsApp no deja ver aquí',
        adjunto: null,
      }
    default:
      return { texto: null, rotulo: `Mensaje de tipo «${tipo}»`, adjunto: null }
  }
}

export function leerMensaje(v: unknown): Mensaje {
  const m = comoFila(v)
  const payload = comoFila(m.waba_payload)
  const estados = comoFila(m.waba_statuses)
  const remitente = filaONula(m.sender)
  const autor = remitente
    ? [textoONulo(remitente.first_name), textoONulo(remitente.last_name)]
        .filter(Boolean)
        .join(' ') || textoONulo(remitente.username)
    : null

  return {
    id: textoONulo(m.id) ?? textoONulo(payload.id) ?? '',
    deHelios: booleano(m.from_us),
    hora: aMs(payload.timestamp) ?? aMs(estados.sent) ?? aMs(m.since_time),
    ...leerContenido(payload),
    autor,
    estado: aMs(estados.read)
      ? 'leido'
      : aMs(estados.delivered)
        ? 'entregado'
        : aMs(estados.sent)
          ? 'enviado'
          : null,
  }
}

export function leerChat(v: unknown): Chat {
  const c = comoFila(v)
  const contacto = comoFila(c.contact)
  const perfil = comoFila(comoFila(contacto.waba_payload).profile)
  const ultimo = filaONula(c.last_message)
  const waId = textoONulo(contacto.wa_id) ?? textoONulo(c.wa_id) ?? ''

  return {
    waId,
    telefono: textoONulo(contacto.phone_number) ?? textoONulo(c.phone_number),
    nombre: textoONulo(perfil.name),
    iniciales: textoONulo(contacto.initials) ?? '·',
    sinLeer: numeroONulo(c.new_messages) ?? 0,
    resuelto: booleano(contacto.resolved),
    ventanaHasta: aMs(contacto.messaging_window_expires_at),
    ultimo: ultimo ? leerMensaje(ultimo) : null,
    etiquetas: comoLista(c.tags)
      .map((t) => textoONulo(comoFila(t).name))
      .filter((t): t is string => t !== null),
    quien: leerQuien(c.helios),
  }
}

/**
 * Una página del Inbox, como la deja la Edge Function. `siguiente` es el
 * `desde` de la próxima, o `null` si no hay más: con un filtro de médicos o
 * pacientes, `total` cuenta todos los chats y no sirve para paginar.
 */
export type Pagina<T> = { total: number; filas: T[]; siguiente: number | null }

export function leerPagina<T>(
  v: unknown,
  leer: (fila: unknown) => T,
): Pagina<T> {
  const p = comoFila(v)
  return {
    total: numeroONulo(p.count) ?? 0,
    filas: comoLista(p.results).map(leer),
    siguiente: numeroONulo(p.siguiente),
  }
}

/** ¿Se le puede escribir texto libre ahora? Fuera de la ventana, solo una plantilla. */
export function ventanaAbierta(
  chat: Pick<Chat, 'ventanaHasta'>,
  ahora = Date.now(),
): boolean {
  return chat.ventanaHasta !== null && chat.ventanaHasta > ahora
}

/** La línea de la lista: el último mensaje en una frase. */
export function vistaPrevia(m: Mensaje | null): string {
  if (!m) return 'Sin mensajes'
  const que =
    m.texto ??
    m.rotulo ??
    (m.adjunto
      ? {
          imagen: 'Foto',
          audio: 'Nota de voz',
          video: 'Video',
          documento: 'Documento',
          sticker: 'Sticker',
        }[m.adjunto.tipo]
      : '')
  return m.deHelios ? `Tú: ${que}` : que
}

/** Cómo se llama el chat en la lista: el nombre del perfil o, si no hay, el teléfono. */
export function nombreDelChat(
  chat: Pick<Chat, 'nombre' | 'telefono' | 'waId'>,
  formatoTelefono: (t: string) => string,
): string {
  return (
    chat.nombre ?? (chat.telefono ? formatoTelefono(chat.telefono) : chat.waId)
  )
}
