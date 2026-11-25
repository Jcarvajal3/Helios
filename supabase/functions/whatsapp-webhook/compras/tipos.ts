// ═══════════════════════════════════════════════════════════════════════════
// Helios — Tipos del motor de Compras en Amazon para médicos
//
// Contratos puros compartidos entre el catálogo (Ports & Adapters), el
// parser médico, el cotizador en centavos y el flujo conversacional (el de
// WhatsApp y el del simulador del superadmin).
// ═══════════════════════════════════════════════════════════════════════════

/** Dimensiones físicas de un paquete en pulgadas (Amazon USA). */
export type DimensionesIn = {
  largo: number
  ancho: number
  alto: number
}

/** Resumen de un producto devuelto por una búsqueda en el catálogo. */
export type ProductoResumen = {
  asin: string
  titulo: string
  precioUsd: number
  /** Vacía si el catálogo no trae foto (no se inventa una). */
  imagenUrl: string
  url: string
  rating: number | null
  resenas: number | null
  categoria: string
  prime: boolean
  pesoLb: number | null
  dimensionesIn?: DimensionesIn | null
}

/** Detalle completo de un producto seleccionado por el médico. */
export type ProductoDetalle = ProductoResumen & {
  variantes: string[]
  disponible: boolean
  descripcionCorta: string
}

/** Tarifas vigentes configuradas en la base para cotizar compras de Amazon. */
export type TarifasCompra = {
  taxUsaPct: number
  serviceFeePct: number
  airRatePerLbUsd: number
  airMinUsd: number
  seaRatePerFt3Usd: number
  seaMinUsd: number
  fallbackWeightLb: number
  /** Tasa BCV real del dólar; sin ella no se cotiza. */
  fxRateUsd: number
  accountsBlock: string
  /** Horas de validez de una cotización (`quote_ttl_hours`); null si la base no lo dice. */
  quoteTtlHours?: number | null
}

export type MetodoEnvio = 'aereo' | 'maritimo'

/** Resultado de la evaluación sanitaria/aduanal de un artículo médico. */
export type RestriccionMedica = {
  restringido: boolean
  motivo: string | null
}

/** Cotización exacta en dólares (centavos) y su equivalente en bolívares BCV. */
export type CotizacionCompra = {
  shippingMethod: MetodoEnvio
  quantity: number
  unitPriceUsd: number
  subtotalUsd: number
  taxUsaUsd: number
  shippingUsd: number
  serviceFeeUsd: number
  totalUsd: number
  totalVes: number
  fxRateUsd: number
  /** Peso por unidad que se usa (el real, o el de respaldo si no hay). */
  weightLb: number
  /** El peso real publicado por unidad, o null si Amazon no lo publica. */
  weightRealLb: number | null
  volumetricWeightLb: number
  volumeFt3: number
  weightEstimated: boolean
  restriccion: RestriccionMedica
}

/** Puerto desacoplado de catálogo Amazon (mock local o Rainforest en producción). */
export type ProveedorCatalogo = {
  readonly nombre: string
  buscar(query: string, limite?: number): Promise<ProductoResumen[]>
  detalle(asin: string): Promise<ProductoDetalle | null>
}

/** Una fila de una lista interactiva de WhatsApp (máx. 10 en total). */
export type FilaLista = {
  id: string
  /** ≤ 24 caracteres. */
  title: string
  /** ≤ 72 caracteres. */
  description: string
}

/** Estados de la sesión propios del flujo de compras en Amazon. */
export type EstadoCompra =
  | 'compra_buscar'
  | 'compra_resultados'
  | 'compra_envio'
  | 'compra_cantidad'
  | 'compra_confirmar'
  | 'compra_pago'
  | 'compra_pago_datos'
  | 'compra_cancelar'
  | 'compra_mis'
  | 'compra_detalle'

/** Una fila visible de «Mis compras» (para aceptar «2» escrito). */
export type FilaMisCompras = { id: string; numero: string }

/** Estado persistido en la sesión durante una compra. */
export type DatosCompra = {
  consulta?: string
  resultados?: ProductoResumen[]
  producto?: ProductoDetalle | null
  envio?: MetodoEnvio | null
  cantidad?: number
  variante?: string | null
  cotizacion?: CotizacionCompra | null
  tarifas?: TarifasCompra | null
  compraId?: string | null
  compraNumero?: string | null
  compraTotalUsd?: number | null
  compraTotalVes?: number | null
  /** Hasta cuándo vale la cotización de la solicitud abierta (ISO). */
  compraVenceEn?: string | null
  /** La base dice que la cotización de la solicitud abierta ya venció. */
  compraVencida?: boolean
  datosPago?: {
    banco?: string
    telefono?: string
    referencia?: string
  }
  intentosDatosPago?: number
  /** Entradas inválidas seguidas (al segundo se ofrece «persona»). */
  invalidos?: number
  /** «Mis compras»: lo que se ve en pantalla. */
  filasMis?: FilaMisCompras[]
  /** La solicitud que se mira en detalle o se pide cancelar. */
  detalleId?: string | null
  detalleNumero?: string | null
  /** A qué estado se vuelve si el médico responde «No, seguir». */
  cancelarVolverA?: EstadoCompra | null
}
