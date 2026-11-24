import { llamarRpc } from '@/features/admin/metricas/consulta'
import { enlaceDelComprobanteDePago } from '@/features/admin/pagosRegistrados/api'
import {
  BUCKET_COMPROBANTES,
  extensionDelComprobante,
} from '@/features/admin/pagosRegistrados/registrarPago'
import {
  booleano,
  comoFila,
  filaONula,
  filas,
  numero,
  numeroONulo,
  texto,
  textoONulo,
} from '@/lib/json'
import { supabase } from '@/lib/supabase'
import { leerEstadoPagoCompra, leerEstadoSolicitud } from './estados'
import type {
  AjustesComprasConfig,
  CanalCompra,
  ConteosCompras,
  DetalleSolicitudCompra,
  DireccionSimMensaje,
  EstadoPagoCompra,
  EstadoSolicitudCompra,
  EventoSolicitudCompra,
  MedicoSimulador,
  MensajeSimulador,
  MetodoEnvioCompra,
  MetodoPagoCompra,
  PagoCompraReporte,
  PrevisionPagoCompra,
  ProveedorCatalogoCompra,
  SolicitudCompraResumen,
  TipoSimMensaje,
} from './tipos'

// ── Lectores estrictos de JSON ─────────────────────────────────────────────

function leerCanal(v: unknown): CanalCompra {
  return v === 'simulador' ? 'simulador' : 'whatsapp'
}

function leerCanalONulo(v: unknown): CanalCompra | null {
  if (v === 'simulador') return 'simulador'
  if (v === 'whatsapp') return 'whatsapp'
  return null
}

function leerMetodoEnvio(v: unknown): MetodoEnvioCompra {
  return v === 'maritimo' || v === 'sea' ? 'maritimo' : 'aereo'
}

function leerMetodoPago(v: unknown): MetodoPagoCompra {
  return v === 'transferencia' ? 'transferencia' : 'pago_movil'
}

function leerProveedor(v: unknown): ProveedorCatalogoCompra {
  if (v === 'rainforest' || v === 'oxylabs' || v === 'rapidapi' || v === 'mock') return v
  return 'mock'
}

function leerDireccionSim(v: unknown): DireccionSimMensaje {
  return v === 'in' ? 'in' : 'out'
}

function leerTipoSim(v: unknown): TipoSimMensaje {
  if (v === 'buttons' || v === 'carousel' || v === 'list' || v === 'image') return v
  return 'text'
}

function formatearCodigo(requestNumber: number, explicitCode: string | null): string {
  if (explicitCode) return explicitCode
  if (requestNumber > 0) return `#C-${String(requestNumber).padStart(4, '0')}`
  return '#C-0000'
}

function leerSolicitud(raw: unknown): SolicitudCompraResumen {
  const r = comoFila(raw)
  const requestNumber = numero(r.request_number)
  const explicitCode = textoONulo(r.code ?? r.request_code)
  const totalUsd = numero(r.total_usd)
  const bcvRateQuote = numeroONulo(r.quoted_fx_rate ?? r.bcv_rate_quote ?? r.fx_rate)
  const totalVesQuote = numeroONulo(r.quoted_ves ?? r.total_ves_quote ?? r.total_ves)
  const bcvRateToday = numeroONulo(r.bcv_rate_today ?? r.today_fx_rate ?? r.fx_rate_today)
  const totalVesToday =
    numeroONulo(r.total_ves_today ?? r.today_ves) ??
    (bcvRateToday !== null ? Math.round(totalUsd * bcvRateToday * 100) / 100 : null)

  return {
    id: texto(r.id ?? r.request_id),
    requestNumber,
    code: formatearCodigo(requestNumber, explicitCode),
    merchantId: texto(r.merchant_id),
    merchantName: texto(r.merchant_name ?? r.clinic_name, 'Clínica sin nombre'),
    doctorName: textoONulo(r.staff_name ?? r.doctor_name ?? r.owner_name),
    phone: texto(r.phone_e164 ?? r.phone ?? r.requester_phone),
    channel: leerCanal(r.channel),
    status: leerEstadoSolicitud(texto(r.status)),
    asin: texto(r.asin),
    productTitle: texto(r.product_title, 'Producto Amazon'),
    productUrl: texto(r.product_url),
    imageUrl: textoONulo(r.image_url),
    variantLabel: textoONulo(r.variant_label),
    quantity: Math.max(1, numero(r.quantity) || 1),
    category: textoONulo(r.category),
    shippingMethod: leerMetodoEnvio(r.shipping_method),
    unitPriceUsd: numero(r.unit_price_usd),
    subtotalUsd: numero(r.subtotal_usd),
    taxUsaUsd: numero(r.tax_usa_usd),
    shippingUsd: numero(r.shipping_usd),
    serviceFeeUsd: numero(r.service_fee_usd),
    totalUsd,
    bcvRateQuote,
    totalVesQuote,
    bcvRateToday,
    totalVesToday,
    weightLb: numeroONulo(r.weight_lb),
    volumetricWeightLb: numeroONulo(r.volumetric_weight_lb),
    volumeFt3: numeroONulo(r.volume_ft3),
    weightEstimated: booleano(r.weight_estimated),
    restrictedFlag: booleano(r.restricted_flag),
    restrictedReason: textoONulo(r.restricted_reason),
    amazonOrderId: textoONulo(r.amazon_order_id),
    usTrackingNumber: textoONulo(r.us_tracking_number),
    quoteExpiresAt: textoONulo(r.quote_expires_at),
    paymentBlock: textoONulo(r.payment_block),
    createdAt: texto(r.created_at),
    updatedAt: texto(r.updated_at ?? r.created_at),
  }
}

function leerPago(raw: unknown): PagoCompraReporte {
  const r = comoFila(raw)
  const reqNum = numeroONulo(r.request_number)
  const reqCode =
    textoONulo(r.request_code) ?? (reqNum !== null ? formatearCodigo(reqNum, null) : null)

  return {
    id: texto(r.report_id ?? r.id),
    requestId: texto(r.request_id),
    requestNumber: reqNum,
    requestCode: reqCode,
    merchantId: textoONulo(r.merchant_id),
    merchantName: textoONulo(r.merchant_name ?? r.clinic_name),
    doctorName: textoONulo(r.staff_name ?? r.doctor_name),
    phone: textoONulo(r.phone_e164 ?? r.phone ?? r.requester_phone),
    productTitle: textoONulo(r.product_title),
    channel: leerCanalONulo(r.channel),
    method: leerMetodoPago(r.method),
    bank: textoONulo(r.bank),
    reference: textoONulo(r.reference),
    payerPhone: textoONulo(r.payer_phone),
    paidOn: texto(r.paid_on ?? r.created_at).slice(0, 10),
    amountUsd: numero(r.total_usd ?? r.amount_usd),
    fxRate: numeroONulo(r.fx_rate ?? r.bcv_rate),
    expectedVes: numeroONulo(r.expected_ves ?? r.expected_amount_ves),
    amountVes: numero(r.declared_amount_ves ?? r.amount_ves),
    receiptPath: textoONulo(r.receipt_path),
    status: leerEstadoPagoCompra(texto(r.status, 'reported')),
    rejectionNote: textoONulo(r.rejection_note),
    note: textoONulo(r.note),
    referenceCollisions: numero(r.reference_collisions),
    fourEyes: booleano(r.four_eyes),
    canApprove: r.can_approve === undefined ? true : booleano(r.can_approve),
    registeredById: textoONulo(r.registered_by ?? r.registered_by_id),
    registeredByName: textoONulo(r.registered_by_name),
    reviewedById: textoONulo(r.reviewed_by ?? r.reviewed_by_id),
    reviewedByName: textoONulo(r.reviewed_by_name),
    reviewedAt: textoONulo(r.reviewed_at),
    createdAt: texto(r.created_at),
  }
}

function leerEvento(raw: unknown): EventoSolicitudCompra {
  const r = comoFila(raw)
  const detail = filaONula(r.detail ?? r.payload)
  return {
    id: texto(r.id),
    requestId: texto(r.request_id),
    eventType: texto(r.kind ?? r.event_type, 'status_changed'),
    title: texto(r.title),
    fromStatus: textoONulo(r.from_status ?? detail?.from_status),
    toStatus: textoONulo(r.to_status ?? detail?.to_status),
    actorName: textoONulo(r.actor_name),
    actorRole: textoONulo(r.actor_role),
    note: textoONulo(r.note ?? detail?.note ?? detail?.reason),
    payload: detail,
    createdAt: texto(r.created_at),
  }
}

function leerDetalle(raw: unknown): DetalleSolicitudCompra | null {
  const r = filaONula(raw)
  if (!r) return null
  const reqRaw = filaONula(r.request) ?? (textoONulo(r.id ?? r.request_id) ? r : null)
  if (!reqRaw) return null
  const request = leerSolicitud(reqRaw)
  const bcvRateToday = numeroONulo(r.bcv_rate_today ?? r.fx_rate_usd) ?? request.bcvRateToday
  const paymentBlock = textoONulo(r.payment_block) ?? request.paymentBlock
  return {
    request: {
      ...request,
      bcvRateToday,
      paymentBlock,
      totalVesToday:
        request.totalVesToday ??
        (bcvRateToday !== null ? Math.round(request.totalUsd * bcvRateToday * 100) / 100 : null),
    },
    payments: filas(r.payments ?? r.payment_reports).map(leerPago),
    events: filas(r.events).map(leerEvento),
    paymentBlock,
    bcvRateToday,
  }
}

function leerConteos(raw: unknown): ConteosCompras {
  const r = comoFila(raw)
  const enProcura =
    numeroONulo(r.en_procura) ??
    numero(r.pagado) + numero(r.comprado_amazon) + numero(r.en_almacen_usa)
  const enTransito = numero(r.en_transito) + numero(r.en_aduana)
  return {
    revisionAduanal: numero(r.revision_aduanal),
    pagosPendientes: numero(r.payments_pending ?? r.pagos_pendientes ?? r.pago_reportado),
    esperandoPago: numero(r.esperando_pago),
    enProcura,
    enTransito,
    listoEntrega: numero(r.listo_entrega),
    totalActivas: numero(r.active ?? r.total_activas ?? r.activas),
  }
}

function leerPrevision(raw: unknown): PrevisionPagoCompra {
  const r = comoFila(raw)
  return {
    requestId: texto(r.request_id),
    paidOn: texto(r.paid_on),
    amountUsd: numero(r.total_usd ?? r.amount_usd),
    fxRate: numeroONulo(r.fx_rate ?? r.bcv_rate),
    expectedVes: numeroONulo(r.expected_ves ?? r.amount_ves),
  }
}

function leerAjustes(raw: unknown): AjustesComprasConfig {
  const r = comoFila(raw)
  return {
    taxUsaPct: numeroONulo(r.tax_usa_pct) ?? 7,
    serviceFeePct: numeroONulo(r.service_fee_pct) ?? 10,
    airRatePerLbUsd: numeroONulo(r.air_rate_per_lb_usd) ?? 6.5,
    airMinUsd: numeroONulo(r.air_min_usd) ?? 15,
    seaRatePerFt3Usd: numeroONulo(r.sea_rate_per_ft3_usd) ?? 28,
    seaMinUsd: numeroONulo(r.sea_min_usd) ?? 35,
    fallbackWeightLb: numeroONulo(r.fallback_weight_lb) ?? 1.5,
    quoteTtlHours: numeroONulo(r.quote_ttl_hours) ?? 24,
    catalogProvider: leerProveedor(r.catalog_provider),
    isEnabled: r.is_enabled === undefined ? true : booleano(r.is_enabled),
    bcvRateToday: numeroONulo(r.fx_rate_usd ?? r.bcv_rate_today ?? r.fx_rate_today),
    updatedAt: textoONulo(r.updated_at),
  }
}

function telefonoSimRespaldo(merchantId: string): string {
  const digitos = merchantId.replace(/\D/g, '').slice(0, 7).padEnd(7, '0')
  return `58414${digitos}`
}

function leerMedicosSim(raw: unknown): MedicoSimulador[] {
  const salida: MedicoSimulador[] = []
  for (const r of filas(raw)) {
    const merchantId = texto(r.merchant_id ?? r.id)
    const merchantName = texto(r.merchant_name ?? r.name, 'Clínica sin nombre')
    const staff = filas(r.staff_numbers)
    if (staff.length > 0) {
      for (const s of staff) {
        const phone = texto(s.phone_e164 ?? s.phone)
        if (!phone) continue
        salida.push({
          key: `${merchantId}:${phone}`,
          merchantId,
          merchantName,
          doctorName: textoONulo(s.staff_name ?? s.doctor_name),
          role: textoONulo(s.role),
          phone,
        })
      }
      continue
    }
    const phone = texto(r.phone_e164 ?? r.phone) || telefonoSimRespaldo(merchantId)
    salida.push({
      key: `${merchantId}:${phone}`,
      merchantId,
      merchantName,
      doctorName: textoONulo(r.doctor_name ?? r.owner_name),
      role: null,
      phone,
    })
  }
  return salida
}

function leerMensajeSim(raw: unknown): MensajeSimulador {
  const r = comoFila(raw)
  return {
    id: texto(r.id),
    phone: texto(r.phone_e164 ?? r.phone),
    direction: leerDireccionSim(r.direction),
    kind: leerTipoSim(r.kind),
    body: texto(r.body),
    payload: filaONula(r.payload),
    createdAt: texto(r.created_at),
  }
}

// ── Storage de comprobantes ────────────────────────────────────────────────

/**
 * Sube un comprobante de pago de compra Amazon al bucket privado `payment-receipts`
 * bajo `compras/<request_id>/<uuid>.<ext>`.
 */
export async function subirComprobanteCompra(params: {
  requestId: string
  file: File
}): Promise<string> {
  const ext = extensionDelComprobante(params.file)
  if (!ext) throw new Error('La captura tiene que ser una imagen (JPG, PNG, WEBP) o un PDF.')
  const ruta = `compras/${params.requestId}/${crypto.randomUUID()}.${ext}`
  const { error } = await supabase.storage
    .from(BUCKET_COMPROBANTES)
    .upload(ruta, params.file, { contentType: params.file.type || undefined, upsert: false })
  if (error) throw error
  return ruta
}

export { enlaceDelComprobanteDePago }

// ── RPCs de lectura ────────────────────────────────────────────────────────

export async function listarSolicitudesCompra(
  params: {
    statuses?: EstadoSolicitudCompra[] | null
    channel?: CanalCompra | null
    search?: string | null
    limit?: number
  } = {},
  signal?: AbortSignal,
): Promise<SolicitudCompraResumen[]> {
  return llamarRpc(
    'admin_purchase_list',
    {
      p_statuses: params.statuses && params.statuses.length > 0 ? params.statuses : null,
      p_channel: params.channel ?? null,
      p_search: params.search?.trim() || null,
      p_limit: params.limit ?? 150,
    },
    { signal, leer: (raw) => filas(raw).map(leerSolicitud) },
  )
}

export async function obtenerDetalleCompra(
  requestId: string,
  signal?: AbortSignal,
): Promise<DetalleSolicitudCompra | null> {
  return llamarRpc(
    'admin_purchase_detail',
    { p_request_id: requestId },
    { signal, leer: leerDetalle },
  )
}

export async function obtenerConteosCompras(signal?: AbortSignal): Promise<ConteosCompras> {
  return llamarRpc('admin_purchase_counts', {}, { signal, leer: leerConteos })
}

export async function listarColaPagosCompra(
  statuses: EstadoPagoCompra[] | null,
  signal?: AbortSignal,
): Promise<PagoCompraReporte[]> {
  return llamarRpc(
    'admin_purchase_payment_queue',
    { p_statuses: statuses && statuses.length > 0 ? statuses : null },
    { signal, leer: (raw) => filas(raw).map(leerPago) },
  )
}

export async function preverPagoCompra(
  params: { requestId: string; paidOn: string },
  signal?: AbortSignal,
): Promise<PrevisionPagoCompra> {
  return llamarRpc(
    'admin_purchase_payment_preview',
    { p_request_id: params.requestId, p_paid_on: params.paidOn },
    { signal, leer: leerPrevision },
  )
}

export async function obtenerAjustesCompras(signal?: AbortSignal): Promise<AjustesComprasConfig> {
  return llamarRpc('admin_purchase_settings_get', {}, { signal, leer: leerAjustes })
}

// ── RPCs de escritura (Conciliación, Aduana, Logística, Ajustes) ───────────

export async function registrarPagoCompra(params: {
  requestId: string
  method: MetodoPagoCompra
  bank: string
  reference: string
  paidOn: string
  amountVes: number
  receiptPath: string | null
  payerPhone: string | null
  note: string | null
}): Promise<PagoCompraReporte> {
  return llamarRpc(
    'admin_purchase_register_payment',
    {
      p_request_id: params.requestId,
      p_method: params.method,
      p_bank: params.bank,
      p_reference: params.reference.trim(),
      p_paid_on: params.paidOn,
      p_amount_ves: params.amountVes,
      p_receipt_path: params.receiptPath,
      p_payer_phone: params.payerPhone?.trim() || null,
      p_note: params.note?.trim() || null,
    },
    { leer: leerPago },
  )
}

export async function conciliarPagoCompra(params: {
  reportId: string
  approve: boolean
  note?: string | null
}): Promise<void> {
  await llamarRpc('admin_purchase_reconcile_payment', {
    p_report_id: params.reportId,
    p_approve: params.approve,
    p_note: params.note?.trim() || null,
  })
}

export async function marcarPagoCompraEnRevision(params: {
  reportId: string
  note: string
}): Promise<void> {
  await llamarRpc('admin_purchase_flag_payment', {
    p_report_id: params.reportId,
    p_note: params.note.trim(),
  })
}

export async function marcarPagoCompraDuplicado(params: {
  reportId: string
  note: string
}): Promise<void> {
  await llamarRpc('admin_purchase_mark_payment_duplicate', {
    p_report_id: params.reportId,
    p_note: params.note.trim(),
  })
}

export async function decidirAduanaCompra(params: {
  requestId: string
  approve: boolean
  note?: string | null
}): Promise<void> {
  await llamarRpc('admin_purchase_approve_customs', {
    p_request_id: params.requestId,
    p_approve: params.approve,
    p_note: params.note?.trim() || null,
  })
}

export async function avanzarEstadoCompra(params: {
  requestId: string
  status: EstadoSolicitudCompra
  amazonOrderId?: string | null
  usTrackingNumber?: string | null
  note?: string | null
}): Promise<void> {
  await llamarRpc('admin_purchase_advance_status', {
    p_request_id: params.requestId,
    p_status: params.status,
    p_amazon_order_id: params.amazonOrderId?.trim() || null,
    p_us_tracking_number: params.usTrackingNumber?.trim() || null,
    p_note: params.note?.trim() || null,
  })
}

export async function guardarAjustesCompras(params: {
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
}): Promise<AjustesComprasConfig> {
  return llamarRpc(
    'admin_purchase_settings_set',
    {
      p_tax_usa_pct: params.taxUsaPct,
      p_service_fee_pct: params.serviceFeePct,
      p_air_rate_per_lb_usd: params.airRatePerLbUsd,
      p_air_min_usd: params.airMinUsd,
      p_sea_rate_per_ft3_usd: params.seaRatePerFt3Usd,
      p_sea_min_usd: params.seaMinUsd,
      p_fallback_weight_lb: params.fallbackWeightLb,
      p_quote_ttl_hours: params.quoteTtlHours,
      p_catalog_provider: params.catalogProvider,
      p_is_enabled: params.isEnabled,
    },
    { leer: leerAjustes },
  )
}

// ── RPCs del Simulador WhatsApp ────────────────────────────────────────────

export async function listarMedicosSimulador(signal?: AbortSignal): Promise<MedicoSimulador[]> {
  return llamarRpc('admin_purchase_sim_merchants', {}, { signal, leer: leerMedicosSim })
}

export async function listarMensajesSimulador(
  phone: string,
  signal?: AbortSignal,
): Promise<MensajeSimulador[]> {
  return llamarRpc(
    'admin_purchase_sim_messages',
    { p_phone: phone },
    { signal, leer: (raw) => filas(raw).map(leerMensajeSim) },
  )
}

export async function agregarMensajeSimulador(params: {
  phone: string
  direction: DireccionSimMensaje
  kind: TipoSimMensaje
  body: string
  payload?: Record<string, unknown> | null
}): Promise<MensajeSimulador> {
  return llamarRpc(
    'admin_purchase_sim_append',
    {
      p_phone: params.phone,
      p_direction: params.direction,
      p_kind: params.kind,
      p_body: params.body,
      p_payload: params.payload ?? {},
    },
    { leer: leerMensajeSim },
  )
}

export async function reiniciarSimulador(phone: string): Promise<void> {
  await llamarRpc('admin_purchase_sim_reset', { p_phone: phone })
}

export async function crearSolicitudSimulador(params: {
  merchantId: string
  phone: string
  asin: string
  productTitle: string
  productUrl: string
  imageUrl: string | null
  variantLabel: string | null
  quantity: number
  category: string | null
  weightLb: number | null
  volumetricWeightLb: number | null
  volumeFt3: number | null
  weightEstimated: boolean
  restrictedFlag: boolean
  restrictedReason: string | null
  shippingMethod: MetodoEnvioCompra
  unitPriceUsd: number
}): Promise<SolicitudCompraResumen> {
  return llamarRpc(
    'admin_purchase_sim_create',
    {
      p_merchant_id: params.merchantId,
      p_phone: params.phone,
      p_asin: params.asin,
      p_product_title: params.productTitle,
      p_product_url: params.productUrl,
      p_image_url: params.imageUrl,
      p_variant_label: params.variantLabel,
      p_quantity: params.quantity,
      p_category: params.category,
      p_weight_lb: params.weightLb,
      p_volumetric_weight_lb: params.volumetricWeightLb,
      p_volume_ft3: params.volumeFt3,
      p_weight_estimated: params.weightEstimated,
      p_restricted_flag: params.restrictedFlag,
      p_restricted_reason: params.restrictedReason,
      p_shipping_method: params.shippingMethod,
      p_unit_price_usd: params.unitPriceUsd,
    },
    { leer: leerSolicitud },
  )
}

export async function reportarPagoSimulador(params: {
  requestId: string
  method: MetodoPagoCompra
  bank: string
  reference: string
  payerPhone: string | null
  amountVes: number
  receiptPath: string | null
  note: string | null
}): Promise<PagoCompraReporte> {
  return llamarRpc(
    'admin_purchase_sim_report_payment',
    {
      p_request_id: params.requestId,
      p_method: params.method,
      p_bank: params.bank,
      p_reference: params.reference.trim(),
      p_payer_phone: params.payerPhone?.trim() || null,
      p_amount_ves: params.amountVes,
      p_receipt_path: params.receiptPath,
      p_note: params.note?.trim() || null,
    },
    { leer: leerPago },
  )
}

export async function listarSolicitudesSimulador(
  phone: string,
  signal?: AbortSignal,
): Promise<SolicitudCompraResumen[]> {
  return llamarRpc(
    'admin_purchase_sim_requests',
    { p_phone: phone },
    { signal, leer: (raw) => filas(raw).map(leerSolicitud) },
  )
}
