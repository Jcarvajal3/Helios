// ═══════════════════════════════════════════════════════════════════════════
// Helios — Transporte del simulador de compras (superadmin)
//
// Lo mismo que el de WhatsApp, pero todo queda en la base del simulador: los
// mensajes salientes con `sim_compra_mensaje` (forma canónica del payload,
// contrato §4) y la sesión con `sim_compra_sesion*`. NUNCA toca
// `helios_whatsapp_*` ni 360dialog.
// ═══════════════════════════════════════════════════════════════════════════

import { construirSeccionesLista, partirMensaje, cortar, cuerpoDeTarjeta, LIMITE_TITULO_BOTON } from './transporte.ts'
import type { RpcTransporte, SesionCompra, TransporteCompras } from './transporte.ts'

export function crearTransporteSimulador({ rpc, phone }: { rpc: RpcTransporte; phone: string }): TransporteCompras {
  const saliente = (kind: 'text' | 'buttons' | 'carousel' | 'list', body: string, payload: Record<string, unknown> = {}) =>
    rpc('sim_compra_mensaje', {
      p_phone: phone,
      p_direction: 'out',
      p_kind: kind,
      p_body: body,
      p_payload: payload,
    })

  return {
    canal: 'simulador',
    // Mismo corte que WhatsApp (`partirMensaje`): lo que ve el administrador es lo que vería el médico.
    async enviar(texto, botones = []) {
      let ultimo: unknown
      for (const parte of partirMensaje(texto, botones)) {
        ultimo =
          parte.botones.length === 0
            ? await saliente('text', parte.texto)
            : await saliente('buttons', parte.texto, { buttons: parte.botones })
      }
      return ultimo
    },
    async enviarCarrusel(cuerpo, tarjetas) {
      if (tarjetas.length < 2 || tarjetas.length > 10) throw new Error('El carrusel necesita entre 2 y 10 tarjetas')
      return saliente('carousel', cuerpo.slice(0, 1024), {
        cards: tarjetas.map((t) => ({
          image_url: t.image_url,
          body: cuerpoDeTarjeta(t.body),
          button: { id: t.button_id, title: cortar(t.button_title, LIMITE_TITULO_BOTON) },
        })),
      })
    },
    async enviarLista(cuerpo, boton, filas) {
      return saliente('list', cuerpo.slice(0, 1024), {
        button: cortar(boton, 20),
        sections: construirSeccionesLista('Tus compras', filas),
      })
    },
    obtenerSesion: () => rpc<SesionCompra>('sim_compra_sesion', { p_phone: phone }),
    guardarSesion: (estado, datos = {}) =>
      rpc('sim_compra_sesion_guardar', { p_phone: phone, p_state: estado, p_data: datos }),
    // El panel ya subió el comprobante: la ruta llega tal cual.
    async guardarComprobante(adjunto) {
      if (!adjunto.receipt_path) throw new Error('El adjunto del simulador no trae `receipt_path`')
      return adjunto.receipt_path
    },
  }
}
