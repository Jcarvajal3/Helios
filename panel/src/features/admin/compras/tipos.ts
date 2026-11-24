// ═══════════════════════════════════════════════════════════════════════════
// Tipos estrictos del módulo Compras Amazon de Médicos.
// Alineados al contrato SQL en `20261124120000_compras_amazon_para_medicos.sql`.
// ═══════════════════════════════════════════════════════════════════════════

export type EstadoSolicitudCompra =
  | 'revision_aduanal'
  | 'esperando_pago'
  | 'pago_reportado'
  | 'pagado'
  | 'comprado_amazon'
  | 'en_almacen_usa'
  | 'en_transito'
  | 'en_aduana'
  | 'listo_entrega'
  | 'entregado'
  | 'cancelado'

export type EstadoPagoCompra =
  | 'reported'
  | 'in_review'
  | 'reconciled'
  | 'rejected'
  | 'duplicate'

export type CanalCompra = 'whatsapp' | 'simulador'

export type MetodoEnvioCompra = 'aereo' | 'maritimo'

export type MetodoPagoCompra = 'pago_movil' | 'transferencia'

export type ProveedorCatalogoCompra = 'mock' | 'rainforest' | 'oxylabs' | 'rapidapi'

export type SolicitudCompraResumen = {
  id: string
  requestNumber: number
  code: string
  merchantId: string
  merchantName: string
  doctorName: string | null
  phone: string
  channel: CanalCompra
  status: EstadoSolicitudCompra
  asin: string
  productTitle: string
  productUrl: string
  imageUrl: string | null
  variantLabel: string | null
  quantity: number
  category: string | null
  shippingMethod: MetodoEnvioCompra
  unitPriceUsd: number
  subtotalUsd: number
  taxUsaUsd: number
  shippingUsd: number
  serviceFeeUsd: number
  totalUsd: number
  bcvRateQuote: number | null
  totalVesQuote: number | null
  bcvRateToday: number | null
  totalVesToday: number | null
  weightLb: number | null
  volumetricWeightLb: number | null
  volumeFt3: number | null
  weightEstimated: boolean
  restrictedFlag: boolean
  restrictedReason: string | null
  amazonOrderId: string | null
  usTrackingNumber: string | null
  quoteExpiresAt: string | null
  paymentBlock: string | null
  createdAt: string
  updatedAt: string
}

export type PagoCompraReporte = {
  id: string
  requestId: string
  requestNumber: number | null
  requestCode: string | null
  merchantId: string | null
  merchantName: string | null
  doctorName: string | null
  phone: string | null
  productTitle: string | null
  channel: CanalCompra | null
  method: MetodoPagoCompra
  bank: string | null
  reference: string | null
  payerPhone: string | null
  paidOn: string
  amountUsd: number
  fxRate: number | null
  expectedVes: number | null
  amountVes: number
  receiptPath: string | null
  status: EstadoPagoCompra
  rejectionNote: string | null
  note: string | null
  referenceCollisions: number
  fourEyes: boolean
  canApprove: boolean
  registeredById: string | null
  registeredByName: string | null
  reviewedById: string | null
  reviewedByName: string | null
  reviewedAt: string | null
  createdAt: string
}

export type EventoSolicitudCompra = {
  id: string
  requestId: string
  eventType: string
  title: string
  fromStatus: string | null
  toStatus: string | null
  actorName: string | null
  actorRole: string | null
  note: string | null
  payload: Record<string, unknown> | null
  createdAt: string
}

export type DetalleSolicitudCompra = {
  request: SolicitudCompraResumen
  payments: PagoCompraReporte[]
  events: EventoSolicitudCompra[]
  paymentBlock: string | null
  bcvRateToday: number | null
}

export type ConteosCompras = {
  revisionAduanal: number
  pagosPendientes: number
  esperandoPago: number
  enProcura: number
  enTransito: number
  listoEntrega: number
  totalActivas: number
}

export type PrevisionPagoCompra = {
  requestId: string
  paidOn: string
  amountUsd: number
  fxRate: number | null
  expectedVes: number | null
}

export type AjustesComprasConfig = {
  taxUsaPct: number
  serviceFeePct: number
  airRatePerLbUsd: number
  airMinUsd: number
  seaRatePerFt3Usd: number
  seaMinUsd: number
  fallbackWeightLb: number
  quoteTtlHours: number
  catalogProvider: ProveedorCatalogoCompra
  isEnabled: boolean
  bcvRateToday: number | null
  updatedAt: string | null
}

export type MedicoSimulador = {
  key: string
  merchantId: string
  merchantName: string
  doctorName: string | null
  role: string | null
  phone: string
}

export type DireccionSimMensaje = 'in' | 'out'

export type TipoSimMensaje = 'text' | 'buttons' | 'carousel' | 'list' | 'image'

export type BotonSimulador = {
  id: string
  title: string
}

export type TarjetaCarruselSimulador = {
  asin: string
  title: string
  imageUrl: string | null
  rating: number
  reviewCount: number
  priceUsd: number
  estimatedDeliveredUsd: number
  estimatedDeliveredVes: number | null
  shippingHint: string
  restricted: boolean
  weightEstimated: boolean
  actionId: string
  actionLabel: string
}

export type MensajeSimulador = {
  id: string
  phone: string
  direction: DireccionSimMensaje
  kind: TipoSimMensaje
  body: string
  payload: Record<string, unknown> | null
  createdAt: string
}
