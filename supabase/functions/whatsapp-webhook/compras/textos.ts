// ═══════════════════════════════════════════════════════════════════════════
// Helios — Textos, etiquetas y botones del flujo de Compras en Amazon
//
// Todo en español de Venezuela, dinero al estilo venezolano (`dinero`,
// `bolivares` de datos.ts), cero vocabulario prohibido (CLAUDE.md), a lo más
// un emoji por mensaje y títulos de botón de ≤ 20 caracteres (los comprueba
// compras.test.ts).
// ═══════════════════════════════════════════════════════════════════════════

import { diaCorto, diaYHoraCaracas } from '../datos.ts'
import type { BotonCompra } from './transporte.ts'
import type { MetodoEnvio } from './tipos.ts'

export { cortar as truncar } from './transporte.ts'

/** Los únicos estados reales de `purchase_requests.status`, en palabras. */
export const ETIQUETA_ESTADO: Record<string, string> = {
  revision_aduanal: 'En revisión aduanal',
  esperando_pago: 'Esperando tu pago',
  pago_reportado: 'Verificando tu pago',
  pagado: 'Pago confirmado',
  comprado_amazon: 'Comprado en Amazon',
  en_almacen_usa: 'En nuestro almacén en EE. UU.',
  en_transito: 'En camino a Venezuela',
  en_aduana: 'En aduana',
  listo_entrega: 'Listo para entrega',
  entregado: 'Entregado',
  cancelado: 'Cancelada',
}

export function etiquetaEstado(status: unknown): string {
  return ETIQUETA_ESTADO[String(status ?? '')] ?? 'En proceso'
}

/** «#C-1024» a partir de 1024, «C-1024» o «#C-1024». */
export function formatoNumeroCompra(valor: unknown): string {
  const s = String(valor ?? '').trim()
  if (s === '') return '#C-0000'
  if (s.startsWith('#')) return s
  if (/^C-/i.test(s)) return `#${s.toUpperCase()}`
  if (/^\d+$/.test(s)) return `#C-${s}`
  return `#${s}`
}

export const ETA_ENVIO: Record<MetodoEnvio, string> = {
  aereo: '7–12 días',
  maritimo: '3–5 semanas',
}

export function nombreEnvio(envio: MetodoEnvio): string {
  return envio === 'maritimo' ? 'Marítimo' : 'Aéreo'
}

/** «jue 26/11 16:30» (hora de Caracas) para un instante ISO; '' si no hay. */
export function fechaHora(iso: string | null | undefined): string {
  const f = diaYHoraCaracas(iso ?? null)
  return f ? `${diaCorto(f.fecha)} ${f.hora}` : ''
}

/** «jue 26/11» (Caracas) para un instante ISO; '' si no hay. */
export function fechaCorta(iso: string | null | undefined): string {
  const f = diaYHoraCaracas(iso ?? null)
  return f ? diaCorto(f.fecha) : ''
}

// ── Botones (títulos de ≤ 20 caracteres) ────────────────────────────────

export const B_MIS: BotonCompra = { id: 'compra:mis', title: 'Mis compras' }
export const B_BUSCAR: BotonCompra = { id: 'compra:buscar', title: 'Nueva búsqueda' }
export const B_MENU: BotonCompra = { id: 'compra:menu', title: 'Volver al menú' }
export const B_PERSONA: BotonCompra = { id: 'compra:persona', title: 'Hablar con alguien' }
export const B_CANCELAR_COMPRA: BotonCompra = { id: 'compra:cancelar_pedir', title: 'Cancelar compra' }

export const BOTONES_BUSCAR: BotonCompra[] = [B_MIS, B_MENU]
export const BOTONES_DESPUES_ACCION: BotonCompra[] = [B_MIS, B_BUSCAR, B_MENU]
export const BOTONES_ERROR_CATALOGO: BotonCompra[] = [B_PERSONA, B_BUSCAR, B_MIS]
export const BOTONES_ENVIO: BotonCompra[] = [
  { id: 'compra:envio:aereo', title: 'Envío aéreo' },
  { id: 'compra:envio:maritimo', title: 'Envío marítimo' },
  { id: 'compra:buscar', title: 'Buscar otro' },
]
export const BOTONES_CONFIRMAR: BotonCompra[] = [
  { id: 'compra:confirmar', title: 'Confirmar compra' },
  { id: 'compra:cambiar_envio', title: 'Cambiar envío' },
  { id: 'compra:cantidad', title: 'Cambiar cantidad' },
]
export const BOTONES_PAGO: BotonCompra[] = [
  { id: 'compra:ya_pague', title: 'Ya pagué' },
  { id: 'compra:datos_pago', title: 'Escribir datos' },
  B_MIS,
]
export const BOTONES_CANCELAR: BotonCompra[] = [
  { id: 'compra:cancelar_si', title: 'Sí, cancelar' },
  { id: 'compra:cancelar_no', title: 'No, seguir' },
]
export const BOTONES_VENCIDA: BotonCompra[] = [
  { id: 'compra:recotizar', title: 'Actualizar' },
  B_CANCELAR_COMPRA,
  B_MIS,
]

export const SUGERENCIA_PERSONA = 'Si prefieres, escribe «persona» y te ayudamos.'

export const MSG_NO_DISPONIBLE = 'Las compras en Amazon no están disponibles en este momento. Inténtalo más tarde o toca «Hablar con alguien».'
export const MSG_SIN_TASA = 'Hoy no puedo cotizar compras en Amazon. Inténtalo más tarde o toca «Hablar con alguien».'
export const MSG_ENLACE_CORTO = 'Ese enlace corto no me deja ver el producto. Ábrelo y copia el enlace largo, o escríbeme el nombre.'
export const MSG_AVISO_TIENDA = 'Compramos en Amazon EE. UU. (amazon.com); busco ese producto allá.'
export const NO_REGISTRO_NADA = 'Listo, no se registró nada.'

const GENERICO_NO_COMPLETADO = 'No pudimos completarlo en este momento. Inténtalo de nuevo en unos minutos.'

/**
 * Lo que la base responde a un error de negocio, en palabras para el médico.
 * Lista cerrada: un mensaje que no está aquí NO se le enseña (jamás texto crudo
 * de SQL ni códigos de estado); quien llama lo registra en el log y usa el
 * mensaje genérico. `null` = no reconocido.
 */
export function mensajeAmigableDeError(crudo: string): string | null {
  const m = crudo.replace(/^[a-z_]+: /, '').trim()
  const estado = /\(estado actual: ([a-z_]+)\)/.exec(m)?.[1]
  const etiqueta = estado ? etiquetaEstado(estado) : ''
  if (/no está esperando pago/.test(m)) return `Tu solicitud está en «${etiqueta}», así que ya no espera tu pago.`
  if (/Solo se puede cancelar/.test(m)) return `Esa solicitud está en «${etiqueta}» y ya no se puede cancelar desde aquí. Si necesitas ayuda, toca «Hablar con alguien».`
  if (/Solo se puede recotizar/.test(m)) return `Esa solicitud está en «${etiqueta}»: el precio solo se actualiza mientras espera tu pago.`
  if (/pago reportado pendiente de revisión/.test(m)) return 'Ya tenemos un pago tuyo en revisión para esa solicitud. Te avisamos por aquí en cuanto lo verifiquemos.'
  if (/pago reportado en revisión: no se puede cancelar/.test(m)) return 'Tienes un pago en revisión, por eso no se puede cancelar ahora. Toca «Hablar con alguien» si necesitas ayuda.'
  if (/no encontrada|no corresponde a este (número|canal)/.test(m)) return 'No encontré esa solicitud entre tus compras.'
  if (/ya la usó otro número|ya se usó para otra solicitud/.test(m)) return GENERICO_NO_COMPLETADO
  if (/Falta el banco/.test(m)) return 'Falta el banco del pago.'
  const ref = /La referencia debe tener entre (\d+) y (\d+) caracteres/.exec(m)
  if (ref) return `La referencia debe tener entre ${ref[1]} y ${ref[2]} caracteres.`
  if (/fecha del pago/i.test(m)) return 'Revisa la fecha del pago: no puede ser futura ni de hace muchos días.'
  if (/monto en bolívares/i.test(m)) return 'Revisa el monto del pago.'
  if (/No hay tasa BCV vigente/.test(m)) return 'Hoy no puedo registrar pagos porque falta la tasa del día. Inténtalo más tarde o toca «Hablar con alguien».'
  if (/no está habilitado en este momento/.test(m)) return MSG_NO_DISPONIBLE
  if (/Ruta de captura no válida/.test(m)) return 'No pude guardar tu comprobante. Envíalo de nuevo o toca «Escribir datos».'
  return null
}

export const MSG_NO_COMPLETADO = GENERICO_NO_COMPLETADO
