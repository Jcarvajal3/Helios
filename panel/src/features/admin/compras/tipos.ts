// ═══════════════════════════════════════════════════════════════════════════
// Tipos estrictos del módulo Compras Amazon de Médicos.
// Alineados al JSON real de `20261124120000_compras_amazon_para_medicos.sql`
// y a las correcciones de `20261124180000_compras_amazon_correcciones.sql`.
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
  'reported' | 'in_review' | 'reconciled' | 'rejected' | 'duplicate'

export type CanalCompra = 'whatsapp' | 'simulador'

export type MetodoEnvioCompra = 'aereo' | 'maritimo'

export type MetodoPagoCompra = 'pago_movil' | 'transferencia'

export type ProveedorCatalogoCompra = 'mock' | 'rainforest'

export type SolicitudCompraResumen = {
  id: string
  requestNumber: number
  /** `#C-0012`: armado con el número real de la solicitud. */
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
  /** Tasa y total en bolívares congelados al aprobar; solo lo que mandó el servidor. */
  bcvRateQuote: number | null
  totalVesQuote: number | null
  weightLb: number | null
  volumetricWeightLb: number | null
  volumeFt3: number | null
  weightEstimated: boolean
  restrictedFlag: boolean
  restrictedReason: string | null
  amazonOrderId: string | null
  usTrackingNumber: string | null
  quoteExpiresAt: string | null
  /** `null` si el servidor no lo manda. */
  vencida: boolean | null
  createdAt: string
  updatedAt: string
}

export type PagoCompraReporte = {
  id: string
  requestId: string
  requestNumber: number
  requestCode: string
  merchantId: string
  merchantName: string
  doctorName: string | null
  phone: string
  productTitle: string
  channel: CanalCompra
  method: MetodoPagoCompra
  bank: string | null
  reference: string | null
  payerPhone: string | null
  paidOn: string
  amountUsd: number
  fxRate: number | null
  expectedVes: number | null
  /** `null` cuando el médico no declaró el monto: hay que verificarlo en el banco. */
  amountVes: number | null
  montoDeclarado: boolean
  /** Declarado − esperado, calculado por el servidor. */
  diferenciaVes: number | null
  /** Veredicto del servidor contra el margen; `null` si no hay monto o tasa. */
  montoCuadra: boolean | null
  /** `true` si el reporte llegó con la cotización vencida; `null` si el servidor no lo manda. */
  cotizacionVencida: boolean | null
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
  eventType: string
  title: string
  fromStatus: string | null
  toStatus: string | null
  actorName: string | null
  note: string | null
  createdAt: string
}

export type DetalleSolicitudCompra = {
  request: SolicitudCompraResumen
  payments: PagoCompraReporte[]
  events: EventoSolicitudCompra[]
  /** Bloque de pago en bolívares armado por el servidor (solo esperando pago o aduana). */
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
  /** Solicitudes del canal simulador (no entran en los demás números). */
  simulador: number
}

export type PrevisionPagoCompra = {
  requestId: string
  paidOn: string
  amountUsd: number
  fxRate: number
  expectedVes: number
}

export type EstadoPilotoCompra = {
  phone: string
  registrado: boolean
  nombre: string | null
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
  /** Teléfonos E.164 que ven la opción aunque `isEnabled` sea falso. */
  pilotPhones: string[]
  /** Por cada piloto guardado: si es personal registrado de alguna clínica. */
  pilotStatus: EstadoPilotoCompra[]
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
  userId: string
}

export type DireccionSimMensaje = 'in' | 'out'

export type BotonSimulador = { id: string; title: string }

export type FilaListaSimulador = {
  id: string
  title: string
  description: string | null
}

export type SeccionListaSimulador = {
  title: string
  rows: FilaListaSimulador[]
}

/** Mensaje del simulador ya leído en una de las formas canónicas del contrato. */
export type MensajeSimulador = {
  id: string
  phone: string
  direction: DireccionSimMensaje
  body: string
  createdAt: string
  contenido:
    | { kind: 'text' }
    | { kind: 'buttons'; buttons: BotonSimulador[] }
    | { kind: 'list'; button: string; sections: SeccionListaSimulador[] }
    | { kind: 'image'; receiptPath: string }
}

export type DiagnosticoSimulador = {
  proveedor: ProveedorCatalogoCompra
  proveedorListo: boolean
}

export type ResultadoTurnoSimulador = DiagnosticoSimulador & {
  estado: string | null
}

/** Cuerpo de `compras-simulador` (contrato §4). */
export type PeticionSimulador =
  | { accion: 'diagnostico' }
  | {
      accion: 'turno'
      phone: string
      texto?: string
      respuesta?: { id: string; title: string }
      adjunto?: { receipt_path: string }
    }
  | { accion: 'reiniciar'; phone: string }
