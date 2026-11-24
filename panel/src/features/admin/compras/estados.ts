import type { LucideIcon } from 'lucide-react'
import {
  AlertTriangle,
  Ban,
  Box,
  CheckCircle2,
  Clock,
  CopyX,
  FileSearch,
  PackageCheck,
  Plane,
  ReceiptText,
  ShieldAlert,
  ShoppingCart,
  Truck,
  Warehouse,
  XCircle,
} from 'lucide-react'

import type { BadgeTone } from '@/components/ui'
import type {
  CanalCompra,
  EstadoPagoCompra,
  EstadoSolicitudCompra,
  MetodoEnvioCompra,
  MetodoPagoCompra,
  ProveedorCatalogoCompra,
} from './tipos'

export type EstadoVisualCompra = {
  label: string
  plural: string
  tone: BadgeTone
  icon: LucideIcon
  que: string
}

export const VALORES_ESTADO_SOLICITUD: ReadonlyArray<EstadoSolicitudCompra> = [
  'revision_aduanal',
  'esperando_pago',
  'pago_reportado',
  'pagado',
  'comprado_amazon',
  'en_almacen_usa',
  'en_transito',
  'en_aduana',
  'listo_entrega',
  'entregado',
  'cancelado',
]

export const ESTADOS_SOLICITUD_COMPRA: Record<
  EstadoSolicitudCompra,
  EstadoVisualCompra
> = {
  revision_aduanal: {
    label: 'Revisión aduanal',
    plural: 'En revisión aduanal',
    tone: 'warning',
    icon: ShieldAlert,
    que: 'Artículo con posible restricción sanitaria o aduanal. Requiere aprobación del equipo antes de habilitar el pago.',
  },
  esperando_pago: {
    label: 'Esperando pago',
    plural: 'Esperando pago',
    tone: 'neutral',
    icon: Clock,
    que: 'Cotización aprobada y congelada. El médico todavía no ha reportado el pago en bolívares.',
  },
  pago_reportado: {
    label: 'Pago reportado',
    plural: 'Con pago reportado',
    tone: 'warning',
    icon: ReceiptText,
    que: 'El médico o el equipo reportó el comprobante en bolívares. Falta conciliarlo contra el banco.',
  },
  pagado: {
    label: 'Pagado',
    plural: 'Pagados',
    tone: 'success',
    icon: CheckCircle2,
    que: 'Pago aprobado en bolívares. Listo para comprar en Amazon.',
  },
  comprado_amazon: {
    label: 'Comprado en Amazon',
    plural: 'Comprados en Amazon',
    tone: 'brand',
    icon: ShoppingCart,
    que: 'Orden colocada en Amazon USA con número de pedido registrado.',
  },
  en_almacen_usa: {
    label: 'En almacén USA',
    plural: 'En almacén USA',
    tone: 'brand',
    icon: Warehouse,
    que: 'Paquete recibido en el casillero de Miami con número de rastreo USA.',
  },
  en_transito: {
    label: 'En tránsito',
    plural: 'En tránsito',
    tone: 'brand',
    icon: Plane,
    que: 'Envío despachado rumbo a Venezuela.',
  },
  en_aduana: {
    label: 'En aduana',
    plural: 'En aduana',
    tone: 'warning',
    icon: FileSearch,
    que: 'En proceso de nacionalización en aduana venezolana.',
  },
  listo_entrega: {
    label: 'Listo para entrega',
    plural: 'Listos para entrega',
    tone: 'success',
    icon: Box,
    que: 'Disponible en Venezuela para coordinar entrega al médico o consultorio.',
  },
  entregado: {
    label: 'Entregado',
    plural: 'Entregados',
    tone: 'success',
    icon: PackageCheck,
    que: 'Pedido entregado al médico. Ciclo cerrado.',
  },
  cancelado: {
    label: 'Cancelado',
    plural: 'Cancelados',
    tone: 'error',
    icon: Ban,
    que: 'Solicitud cancelada por el equipo, aduana o expiración.',
  },
}

export const VALORES_ESTADO_PAGO_COMPRA: ReadonlyArray<EstadoPagoCompra> = [
  'reported',
  'in_review',
  'reconciled',
  'rejected',
  'duplicate',
]

export const ESTADOS_PAGO_COMPRA: Record<EstadoPagoCompra, EstadoVisualCompra> =
  {
    reported: {
      label: 'Pendiente',
      plural: 'Pendientes',
      tone: 'warning',
      icon: Clock,
      que: 'Pago recién reportado, pendiente de conciliación bancaria.',
    },
    in_review: {
      label: 'En revisión',
      plural: 'En revisión',
      tone: 'warning',
      icon: AlertTriangle,
      que: 'Apartado por el equipo para verificar datos con el banco o el médico.',
    },
    reconciled: {
      label: 'Aprobado',
      plural: 'Aprobados',
      tone: 'success',
      icon: CheckCircle2,
      que: 'Pago conciliado y confirmado.',
    },
    rejected: {
      label: 'Rechazado',
      plural: 'Rechazados',
      tone: 'error',
      icon: XCircle,
      que: 'Pago rechazado con motivo enviado al médico.',
    },
    duplicate: {
      label: 'Duplicado',
      plural: 'Duplicados',
      tone: 'error',
      icon: CopyX,
      que: 'Cerrado como duplicado sin enviar aviso de rechazo al médico.',
    },
  }

export const VALORES_CANAL_COMPRA: ReadonlyArray<CanalCompra> = [
  'whatsapp',
  'simulador',
]

export function etiquetaDeCanal(canal: CanalCompra | null): string {
  if (canal === 'simulador') return 'Simulador'
  if (canal === 'whatsapp') return 'WhatsApp'
  return '—'
}

export function etiquetaDeEnvio(metodo: MetodoEnvioCompra): string {
  return metodo === 'maritimo' ? 'Marítimo' : 'Aéreo'
}

export function etiquetaDeMetodoPago(metodo: MetodoPagoCompra): string {
  return metodo === 'transferencia' ? 'Transferencia' : 'Pago Móvil'
}

export const METODOS_PAGO_COMPRA: Array<{
  value: MetodoPagoCompra
  label: string
}> = [
  { value: 'pago_movil', label: 'Pago Móvil' },
  { value: 'transferencia', label: 'Transferencia' },
]

/** Un estado que la base manda y el panel no conoce es un error de contrato, no un valor por defecto. */
export function leerEstadoSolicitud(valor: unknown): EstadoSolicitudCompra {
  const e = VALORES_ESTADO_SOLICITUD.find((x) => x === valor)
  if (!e)
    throw new Error(
      `Estado de solicitud de compra desconocido: ${String(valor)}`,
    )
  return e
}

export function leerEstadoPagoCompra(valor: unknown): EstadoPagoCompra {
  const e = VALORES_ESTADO_PAGO_COMPRA.find((x) => x === valor)
  if (!e)
    throw new Error(`Estado de pago de compra desconocido: ${String(valor)}`)
  return e
}

export function visualSolicitudCompra(valor: string): EstadoVisualCompra {
  const clave = VALORES_ESTADO_SOLICITUD.find((e) => e === valor)
  if (clave) return ESTADOS_SOLICITUD_COMPRA[clave]
  return {
    label: valor || 'Desconocido',
    plural: valor || 'Desconocidos',
    tone: 'neutral',
    icon: Truck,
    que: 'Estado registrado en la base.',
  }
}

export function visualPagoCompra(valor: string): EstadoVisualCompra {
  const clave = VALORES_ESTADO_PAGO_COMPRA.find((e) => e === valor)
  if (clave) return ESTADOS_PAGO_COMPRA[clave]
  return {
    label: valor || 'Desconocido',
    plural: valor || 'Desconocidos',
    tone: 'neutral',
    icon: Clock,
    que: 'Estado de pago reportado.',
  }
}

/**
 * Transiciones logísticas permitidas desde un estado dado.
 * Se usan en el carril fijo de la ficha para avanzar la orden paso a paso.
 */
export const SIGUIENTES_ESTADOS_LOGISTICA: Partial<
  Record<
    EstadoSolicitudCompra,
    ReadonlyArray<{
      status: EstadoSolicitudCompra
      label: string
      requiereAmazonOrderId?: boolean
      requiereUsTracking?: boolean
    }>
  >
> = {
  pagado: [
    {
      status: 'comprado_amazon',
      label: 'Marcar comprado en Amazon',
      requiereAmazonOrderId: true,
    },
  ],
  comprado_amazon: [
    {
      status: 'en_almacen_usa',
      label: 'Recibido en almacén USA',
      requiereUsTracking: true,
    },
  ],
  en_almacen_usa: [{ status: 'en_transito', label: 'Despachar en tránsito' }],
  en_transito: [
    { status: 'en_aduana', label: 'Ingresó en aduana' },
    { status: 'listo_entrega', label: 'Listo para entrega' },
  ],
  en_aduana: [
    { status: 'listo_entrega', label: 'Liberado · Listo para entrega' },
  ],
  listo_entrega: [{ status: 'entregado', label: 'Marcar como entregado' }],
}

/** Si la solicitud todavía se puede cancelar manualmente desde el carril. */
export function sePuedeCancelarSolicitud(
  status: EstadoSolicitudCompra,
): boolean {
  return status !== 'entregado' && status !== 'cancelado'
}

/** Etiqueta legible para los tipos de evento del timeline. */
export function etiquetaDeEventoCompra(eventType: string): string {
  const mapa: Record<string, string> = {
    created: 'Solicitud creada',
    customs_approved: 'Aduana aprobada',
    customs_rejected: 'Rechazada por aduana',
    payment_reported: 'Pago reportado',
    payment_flagged: 'Pago en revisión',
    payment_reconciled: 'Pago aprobado',
    payment_rejected: 'Pago rechazado',
    payment_duplicate: 'Pago marcado como duplicado',
    status_changed: 'Cambio de estado logístico',
    cancelled: 'Solicitud cancelada',
    delivered: 'Pedido entregado',
  }
  return Object.hasOwn(mapa, eventType)
    ? mapa[eventType]
    : eventType.replaceAll('_', ' ')
}

/** «Proveedor: Rainforest · listo», «Rainforest · falta RAINFOREST_API_KEY» o «Catálogo de prueba». */
export function rotuloDelProveedor(d: {
  proveedor: ProveedorCatalogoCompra
  proveedorListo: boolean
}): string {
  if (d.proveedor === 'mock') return 'Catálogo de prueba'
  return d.proveedorListo
    ? 'Proveedor: Rainforest · listo'
    : 'Rainforest · falta RAINFOREST_API_KEY'
}
