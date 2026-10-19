import { infiniteQueryOptions, queryOptions } from '@tanstack/react-query'

import { SUPABASE_ANON_KEY, SUPABASE_URL, supabase } from '@/lib/supabase'
import { comoFila, textoONulo } from '@/lib/json'
import { leerChat, leerMensaje, leerPagina } from './inbox'
import type { Chat, Mensaje, Pagina } from './inbox'

// ═══════════════════════════════════════════════════════════════════════════
// Las llamadas del inbox de WhatsApp y sus claves de caché.
//
// No van a la base sino a la Edge Function `whatsapp-inbox`, que guarda el
// token del Inbox de 360dialog y comprueba que quien llama es del equipo. Se
// llama con la sesión de quien está en el panel.
//
// Todo cuelga de ['admin-whatsapp', …]: contestar invalida la lista y el chat
// de una vez.
// ═══════════════════════════════════════════════════════════════════════════

export const CLAVE_WHATSAPP = ['admin-whatsapp'] as const

/** Cada cuánto se mira si hay algo nuevo. Solo con la pestaña a la vista. */
const CADA_15_S = 15_000
const CADA_10_S = 10_000

export const POR_PAGINA = 30

/** Un fallo de la función, con el código que la pantalla sabe explicar. */
export class FalloDelInbox extends Error {
  constructor(
    readonly codigo: string,
    readonly status: number,
    readonly detalle: string | null,
  ) {
    super(MENSAJES_DE_ERROR[codigo] ?? `El inbox no respondió (${codigo}).`)
    this.name = 'FalloDelInbox'
  }
}

/** Lo que se le dice al equipo de cada fallo. */
const MENSAJES_DE_ERROR: Record<string, string> = {
  sin_sesion: 'La sesión ha caducado. Vuelve a iniciar sesión.',
  solo_personal_de_helios:
    'Esta cuenta no puede usar el inbox. Si tienes el segundo factor activo, vuelve a entrar con él.',
  sin_configurar: 'El inbox aún no está conectado con 360dialog.',
  token_invalido: '360dialog rechazó el token del Inbox. Hay que renovarlo.',
  sin_permiso_en_inbox:
    'El usuario del Inbox no tiene permiso para escribir en este chat.',
  ventana_cerrada:
    'Pasaron más de 24 horas desde su último mensaje: WhatsApp solo deja escribirle con una plantilla.',
  cola_llena:
    'El Inbox tiene demasiados mensajes en cola. Espera un momento y vuelve a intentarlo.',
  inbox_ocupado:
    '360dialog pide que esperemos un momento. Vuelve a intentarlo en unos segundos.',
  chat_desconocido: 'Ese chat no existe en el Inbox.',
  adjunto_no_existe:
    'Ese archivo ya no está disponible (WhatsApp los borra pasado un tiempo).',
  inbox_no_responde:
    '360dialog no responde ahora mismo. Vuelve a intentarlo en unos segundos.',
  base_no_responde: 'No se pudo comprobar tu acceso. Vuelve a intentarlo.',
  no_se_pudo_anotar:
    'No se pudo anotar la acción en la bitácora, así que no se mandó nada.',
  peticion_invalida: 'El inbox no entendió la petición.',
  mal_configurada: 'La función del inbox está mal configurada.',
}

/** El texto de un fallo cualquiera, para un toast o un aviso. */
export function textoDelFallo(error: unknown): string {
  if (error instanceof FalloDelInbox) return error.message
  if (error instanceof Error && error.name === 'TimeoutError')
    return MENSAJES_DE_ERROR.inbox_no_responde
  return 'No se pudo hablar con el inbox. Revisa la conexión y vuelve a intentarlo.'
}

/**
 * Una llamada a la función. `ruta` va después de `/whatsapp-inbox/`. Devuelve
 * la respuesta cruda (para un adjunto) o lanza `FalloDelInbox`.
 */
async function llamar(
  ruta: string,
  opciones: {
    metodo?: 'GET' | 'POST'
    cuerpo?: unknown
    signal?: AbortSignal
  } = {},
): Promise<Response> {
  const { data } = await supabase.auth.getSession()
  const token = data.session?.access_token
  if (!token) throw new FalloDelInbox('sin_sesion', 401, null)

  const respuesta = await fetch(
    `${SUPABASE_URL}/functions/v1/whatsapp-inbox/${ruta}`,
    {
      method: opciones.metodo ?? 'GET',
      headers: {
        Authorization: `Bearer ${token}`,
        apikey: SUPABASE_ANON_KEY,
        ...(opciones.cuerpo !== undefined
          ? { 'Content-Type': 'application/json' }
          : {}),
      },
      body:
        opciones.cuerpo !== undefined
          ? JSON.stringify(opciones.cuerpo)
          : undefined,
      signal: opciones.signal ?? AbortSignal.timeout(30_000),
    },
  )

  if (!respuesta.ok) {
    const cuerpo = comoFila(await respuesta.json().catch(() => null))
    throw new FalloDelInbox(
      textoONulo(cuerpo.error) ?? `http_${respuesta.status}`,
      respuesta.status,
      textoONulo(cuerpo.detalle),
    )
  }
  return respuesta
}

async function llamarJson(
  ruta: string,
  opciones: Parameters<typeof llamar>[1] = {},
): Promise<unknown> {
  return (await llamar(ruta, opciones)).json()
}

export type EstadoDelInbox = { configurado: boolean; conectado: boolean }

/**
 * ¿Están los secretos y vale el token? Se mira una vez al entrar. Un 404 sin
 * código nuestro es que la función aún no está desplegada: es lo mismo que
 * no estar configurado.
 */
export function consultaEstadoDelInbox() {
  return queryOptions({
    queryKey: [...CLAVE_WHATSAPP, 'estado'],
    queryFn: async ({ signal }): Promise<EstadoDelInbox> => {
      const crudo = await llamarJson('estado', { signal }).catch(
        (error: unknown) => {
          if (error instanceof FalloDelInbox && error.status === 404)
            return null
          throw error
        },
      )
      const e = comoFila(crudo)
      return {
        configurado: e.configurado === true,
        conectado: e.conectado === true,
      }
    },
    staleTime: 5 * 60_000,
    retry: false,
  })
}

/** La lista de chats, del más reciente al más viejo, de `POR_PAGINA` en `POR_PAGINA`. */
export function consultaChats(f: { q: string | null; sinLeer: boolean }) {
  return infiniteQueryOptions({
    queryKey: [...CLAVE_WHATSAPP, 'chats', f.q, f.sinLeer],
    queryFn: async ({ pageParam, signal }): Promise<Pagina<Chat>> => {
      const q = new URLSearchParams({
        limite: String(POR_PAGINA),
        desde: String(pageParam),
      })
      if (f.q) q.set('q', f.q)
      if (f.sinLeer) q.set('sin_leer', '1')
      return leerPagina(await llamarJson(`chats?${q}`, { signal }), leerChat)
    },
    initialPageParam: 0,
    getNextPageParam: (ultima, paginas) => {
      const vistos = paginas.reduce((n, p) => n + p.filas.length, 0)
      return ultima.filas.length === POR_PAGINA && vistos < ultima.total
        ? vistos
        : undefined
    },
    refetchInterval: CADA_15_S,
  })
}

/** Un chat suelto: para la cabecera cuando se entra por enlace y no está en la lista. */
export function consultaChat(waId: string) {
  return queryOptions({
    queryKey: [...CLAVE_WHATSAPP, 'chat', waId],
    queryFn: async ({ signal }): Promise<Chat | null> => {
      const q = new URLSearchParams({ limite: '1', q: waId })
      const pagina = leerPagina(
        await llamarJson(`chats?${q}`, { signal }),
        leerChat,
      )
      return pagina.filas.find((c) => c.waId === waId) ?? null
    },
  })
}

/**
 * Los mensajes de un chat, del más nuevo hacia atrás. La primera página los
 * marca como recibidos en el Inbox (deja de contar como «sin leer»); las
 * siguientes se piden con `antes_de` = el más viejo que ya se tiene.
 */
export function consultaMensajes(waId: string) {
  return infiniteQueryOptions({
    queryKey: [...CLAVE_WHATSAPP, 'mensajes', waId],
    queryFn: async ({ pageParam, signal }): Promise<Pagina<Mensaje>> => {
      const q = new URLSearchParams({ wa_id: waId, limite: String(POR_PAGINA) })
      if (pageParam === null) q.set('marcar', '1')
      else q.set('antes_de', String(pageParam))
      return leerPagina(
        await llamarJson(`mensajes?${q}`, { signal }),
        leerMensaje,
      )
    },
    initialPageParam: null as number | null,
    getNextPageParam: (ultima) => {
      if (ultima.filas.length < POR_PAGINA) return undefined
      const horas = ultima.filas
        .map((m) => m.hora)
        .filter((h): h is number => h !== null)
      return horas.length > 0
        ? Math.floor(Math.min(...horas) / 1000)
        : undefined
    },
    refetchInterval: CADA_10_S,
  })
}

/** Contesta con texto libre. El Inbox lo pone en cola (202): aún no está entregado. */
export async function enviarTexto(waId: string, texto: string): Promise<void> {
  await llamar('mensajes', { metodo: 'POST', cuerpo: { wa_id: waId, texto } })
}

export async function marcarResuelto(
  waId: string,
  resuelto: boolean,
): Promise<void> {
  await llamar('resolver', {
    metodo: 'POST',
    cuerpo: { wa_id: waId, resuelto },
  })
}

/** Un adjunto como blob, para pintarlo con una URL local (un `<img>` no manda el token). */
export async function descargarAdjunto(
  id: string,
  mime: string | null,
  signal?: AbortSignal,
): Promise<Blob> {
  // El mime de WhatsApp puede traer parámetros («audio/ogg; codecs=opus»): la
  // función solo acepta tipo/subtipo.
  const limpio = mime?.split(';')[0].trim() ?? null
  const q = limpio ? `?${new URLSearchParams({ mime: limpio })}` : ''
  const respuesta = await llamar(`adjunto/${encodeURIComponent(id)}${q}`, {
    signal,
  })
  return respuesta.blob()
}

export function consultaAdjunto(id: string, mime: string | null) {
  return queryOptions({
    queryKey: [...CLAVE_WHATSAPP, 'adjunto', id],
    queryFn: ({ signal }) => descargarAdjunto(id, mime, signal),
    // Un adjunto no cambia: se pide una vez por sesión.
    staleTime: Infinity,
    gcTime: 10 * 60_000,
    retry: (intentos, error) =>
      !(error instanceof FalloDelInbox && error.status === 404) && intentos < 2,
  })
}
