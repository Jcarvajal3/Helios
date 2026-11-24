// ═══════════════════════════════════════════════════════════════════════════
// Helios — Tipos del motor de Compras en Amazon para médicos
//
// Contratos puros compartidos entre el catálogo (Ports & Adapters), el
// parser médico, el cotizador en centavos y el flujo conversacional de
// WhatsApp.
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
  fxRateUsd: number
  accountsBlock: string
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
  weightLb: number
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

/** Tarjeta de un Interactive Media Card Carousel de WhatsApp (2 a 10 cards). */
export type TarjetaCarrusel = {
  image_url: string
  body: string
  button_id: string
  button_title: string
}

/** Estados de la sesión de WhatsApp propios del flujo de compras en Amazon. */
export type EstadoCompra =
  | 'compra_buscar'
  | 'compra_resultados'
  | 'compra_envio'
  | 'compra_confirmar'
  | 'compra_pago'
  | 'compra_pago_datos'

/** Estado persistido en `whatsapp_sessions.data` durante una compra. */
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
  datosPago?: {
    banco?: string
    telefono?: string
    referencia?: string
  }
  intentosDatosPago?: number
}
