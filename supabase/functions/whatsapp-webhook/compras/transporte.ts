// ═══════════════════════════════════════════════════════════════════════════
// Helios — Transporte del flujo de Compras
//
// El flujo (flujo.ts) no sabe si habla por WhatsApp o con el simulador del
// superadmin: depende de `TransporteCompras`. Aquí viven la interfaz, los
// constructores EXACTOS de lo que se manda a Meta (carrusel y lista) y el
// transporte de WhatsApp (las RPC `helios_whatsapp_*` + `bot_session`).
//
// Formato del carrusel interactivo (Cloud API, «Interactive media carousel
// messages», developers.facebook.com/docs/whatsapp/cloud-api/messages/
// interactive-media-carousel-messages; 360dialog: docs.360dialog.com/docs/
// messaging/message-types/interactive/media-carousel):
//   interactive.type = 'carousel'; body.text ≤ 1024; action.cards[2..10]:
//   { card_index, header:{type:'image',image:{link}}, body:{text ≤160, ≤2 saltos},
//     action:{ buttons:[{ type:'quick_reply', quick_reply:{ id, title ≤20 } }] } }
//   · todas las tarjetas con el MISMO tipo y número de botones;
//   · el `type` a nivel de tarjeta solo se manda con `cta_url`: con botones de
//     respuesta rápida NO se manda (lo rechaza Meta);
//   · 360dialog limita el id del botón a 20 caracteres.
// El `type:'button'` + `{type:'reply', reply}` del código anterior era el
// formato de los mensajes interactivos de botones, no el de las tarjetas.
// ═══════════════════════════════════════════════════════════════════════════

import { bajarAdjunto360, rutaDelComprobante } from './adjuntos.ts'
import type { AlmacenComprobantes, ConfigD360 } from './adjuntos.ts'
import type { DatosCompra, FilaLista, TarjetaCarrusel } from './tipos.ts'

export type BotonCompra = { id: string; title: string }

export type CanalCompra = 'whatsapp' | 'simulador'

export type SesionCompra = { state: string; data: Record<string, unknown>; nueva?: boolean }

export type AdjuntoCompra = { id: string; mime: string; receipt_path?: string }

/** Lo que el flujo de compras necesita del mundo exterior para hablar. */
export interface TransporteCompras {
  readonly canal: CanalCompra
  /** Texto con hasta 3 botones de respuesta. */
  enviar(texto: string, botones?: BotonCompra[]): Promise<unknown>
  /** Carrusel de 2 a 10 tarjetas con foto y un botón de respuesta cada una. */
  enviarCarrusel(cuerpo: string, tarjetas: TarjetaCarrusel[]): Promise<unknown>
  /** Lista interactiva (≤ 10 filas). */
  enviarLista(cuerpo: string, boton: string, filas: FilaLista[]): Promise<unknown>
  obtenerSesion(): Promise<SesionCompra>
  guardarSesion(estado: string, datos?: Record<string, unknown>): Promise<unknown>
  /** Guarda el comprobante y devuelve su ruta en `payment-receipts`. */
  guardarComprobante(adjunto: AdjuntoCompra, solicitudId: string): Promise<string>
}

// ── Límites de Meta ─────────────────────────────────────────────────────

export const LIMITE_CUERPO_CON_BOTONES = 1024
export const LIMITE_CUERPO_TARJETA = 160
export const LIMITE_SALTOS_TARJETA = 2
export const LIMITE_TITULO_BOTON = 20
export const LIMITE_ID_BOTON_TARJETA = 20
export const LIMITE_TITULO_FILA = 24
export const LIMITE_DESCRIPCION_FILA = 72
export const LIMITE_BOTON_LISTA = 20
export const MAXIMO_FILAS = 10

/** Corta un texto a `max` caracteres con «…». */
export function cortar(texto: string, max: number): string {
  const t = texto.trim()
  if (t.length <= max) return t
  return `${t.slice(0, Math.max(1, max - 1)).trimEnd()}…`
}

/** Cuerpo de tarjeta: ≤160 caracteres y ≤2 saltos de línea. */
export function cuerpoDeTarjeta(texto: string): string {
  const lineas = texto.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)
  // Más de 3 líneas = más de 2 saltos: lo que sobra se junta con la última.
  const juntas =
    lineas.length > LIMITE_SALTOS_TARJETA + 1
      ? [...lineas.slice(0, LIMITE_SALTOS_TARJETA), lineas.slice(LIMITE_SALTOS_TARJETA).join(' ')]
      : lineas
  return cortar(juntas.join('\n'), LIMITE_CUERPO_TARJETA)
}

export type TarjetaMeta = {
  card_index: number
  header: { type: 'image'; image: { link: string } }
  body: { text: string }
  action: { buttons: Array<{ type: 'quick_reply'; quick_reply: { id: string; title: string } }> }
}

/** Las tarjetas tal como las pide la Cloud API (`interactive.action.cards`). */
export function construirTarjetasMeta(tarjetas: TarjetaCarrusel[]): TarjetaMeta[] {
  if (tarjetas.length < 2 || tarjetas.length > MAXIMO_FILAS) {
    throw new Error('El carrusel necesita entre 2 y 10 tarjetas')
  }
  return tarjetas.map((t, card_index) => {
    if (!t.image_url) throw new Error('Toda tarjeta del carrusel necesita foto')
    if (t.button_id.length > LIMITE_ID_BOTON_TARJETA) throw new Error('El id del botón de la tarjeta pasa de 20 caracteres')
    return {
      card_index,
      header: { type: 'image', image: { link: t.image_url } },
      body: { text: cuerpoDeTarjeta(t.body) },
      action: {
        buttons: [{ type: 'quick_reply', quick_reply: { id: t.button_id, title: cortar(t.button_title, LIMITE_TITULO_BOTON) } }],
      },
    }
  })
}

export type SeccionLista = { title: string; rows: Array<{ id: string; title: string; description: string }> }

/** Las secciones de una lista interactiva (una sola, ≤10 filas). */
export function construirSeccionesLista(titulo: string, filas: FilaLista[]): SeccionLista[] {
  if (filas.length < 1) throw new Error('La lista necesita al menos una fila')
  return [
    {
      title: cortar(titulo, 24),
      rows: filas.slice(0, MAXIMO_FILAS).map((f) => ({
        id: f.id.slice(0, 200),
        title: cortar(f.title, LIMITE_TITULO_FILA),
        description: cortar(f.description, LIMITE_DESCRIPCION_FILA),
      })),
    },
  ]
}

/** Los botones de un mensaje: ≤3 y con títulos de ≤20 caracteres. */
export function botonesValidos(botones: BotonCompra[]): BotonCompra[] {
  return botones.slice(0, 3).map((b) => ({ id: b.id, title: cortar(b.title, LIMITE_TITULO_BOTON) }))
}

/**
 * Cómo viaja un texto: un cuerpo con botones no pasa de 1024 caracteres; si es
 * más largo, el texto va solo y los botones, aparte bajo «Elige una opción:».
 * Sin botones el límite es 4096. Lo comparten WhatsApp y el simulador para que
 * este muestre exactamente lo que recibiría el médico.
 */
export const LIMITE_TEXTO_SIN_BOTONES = 4096
export const TEXTO_ELIGE_OPCION = 'Elige una opción:'
export type ParteDeMensaje = { texto: string; botones: BotonCompra[] }

export function partirMensaje(cuerpo: string, botones: BotonCompra[] = []): ParteDeMensaje[] {
  const validos = botonesValidos(botones)
  if (validos.length === 0) return [{ texto: cuerpo.slice(0, LIMITE_TEXTO_SIN_BOTONES), botones: [] }]
  if (cuerpo.length > LIMITE_CUERPO_CON_BOTONES) {
    return [
      { texto: cuerpo.slice(0, LIMITE_TEXTO_SIN_BOTONES), botones: [] },
      { texto: TEXTO_ELIGE_OPCION, botones: validos },
    ]
  }
  return [{ texto: cuerpo, botones: validos }]
}

/** Una fila de lista escrita como texto numerado (cuando no hay lista interactiva). */
export function filasComoTexto(filas: FilaLista[]): string {
  return filas.map((f, i) => `${i + 1}. ${f.title}${f.description ? ` · ${f.description}` : ''}`).join('\n')
}

// ── Transporte de WhatsApp ──────────────────────────────────────────────

export type RpcTransporte = <T>(fn: string, args: Record<string, unknown>) => Promise<T>

export type PersonalTransporte = { phone_e164: string; user_id: string }

export type OpcionesTransporteWhatsApp = {
  rpc: RpcTransporte
  personal: PersonalTransporte
  /** Dónde se guardan los comprobantes (el bucket `payment-receipts`). */
  almacen?: AlmacenComprobantes
  fetchFn?: typeof fetch
}

export function crearTransporteWhatsApp({ rpc, personal, almacen, fetchFn }: OpcionesTransporteWhatsApp): TransporteCompras {
  const tel = personal.phone_e164

  const enviar = async (cuerpo: string, botones: BotonCompra[] = []) => {
    let ultimo: unknown
    for (const parte of partirMensaje(cuerpo, botones)) {
      ultimo = await rpc('helios_whatsapp_text', {
        p_to: tel,
        p_text: parte.texto,
        p_staff_user_id: personal.user_id,
        p_buttons: parte.botones,
      })
    }
    return ultimo
  }
  const texto = (cuerpo: string) => enviar(cuerpo)

  return {
    canal: 'whatsapp',
    enviar,
    async enviarCarrusel(cuerpo, tarjetas) {
      return rpc('helios_whatsapp_carousel', {
        p_to: tel,
        p_body: cuerpo.slice(0, 1024),
        p_cards: construirTarjetasMeta(tarjetas),
        p_staff_user_id: personal.user_id,
      })
    },
    // Lista interactiva por `helios_whatsapp_list`. Si la RPC falla (límites,
    // ventana cerrada, red) la lista sale como texto numerado y el flujo acepta
    // el número escrito; el fallo queda en el log.
    async enviarLista(cuerpo, boton, filas) {
      try {
        return await rpc('helios_whatsapp_list', {
          p_to: tel,
          p_body: cuerpo.slice(0, 1024),
          p_button: cortar(boton, LIMITE_BOTON_LISTA),
          p_sections: construirSeccionesLista('Opciones', filas),
          p_staff_user_id: personal.user_id,
        })
      } catch (err) {
        console.error('compras: helios_whatsapp_list falló; la lista sale como texto', (err as { code?: unknown } | null)?.code)
        return texto(`${cuerpo}\n\n${filasComoTexto(filas.slice(0, MAXIMO_FILAS))}\n\nResponde con el número.`)
      }
    },
    obtenerSesion: () => rpc<SesionCompra>('bot_session', { p_phone: tel }),
    guardarSesion: (estado, datos = {}) =>
      rpc('bot_session_save', { p_phone: tel, p_state: estado, p_data: datos as DatosCompra }),
    async guardarComprobante(adjunto, solicitudId) {
      if (!almacen) throw new Error('No hay dónde guardar el comprobante')
      const cfg = await rpc<ConfigD360>('lector_config', {})
      const bytes = await bajarAdjunto360(adjunto.id, cfg, fetchFn)
      const ruta = rutaDelComprobante(solicitudId, adjunto.id, adjunto.mime)
      await almacen.subir(ruta, bytes, adjunto.mime || 'image/jpeg')
      return ruta
    },
  }
}
