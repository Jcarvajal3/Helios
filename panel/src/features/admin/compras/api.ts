import { llamarRpc } from '@/features/admin/metricas/consulta'
import { enlaceDelComprobanteDePago } from '@/features/admin/pagosRegistrados/api'
import {
  BUCKET_COMPROBANTES,
  extensionDelComprobante,
} from '@/features/admin/pagosRegistrados/registrarPago'
import { filas } from '@/lib/json'
import { supabase } from '@/lib/supabase'
import {
  leerAjustes,
  leerConteos,
  leerDetalle,
  leerMedicosSim,
  leerMensajeSim,
  leerPago,
  leerPrevision,
  leerSolicitud,
} from './lectores'
import type {
  AjustesComprasConfig,
  CanalCompra,
  ConteosCompras,
  DetalleSolicitudCompra,
  EstadoPagoCompra,
  EstadoSolicitudCompra,
  MedicoSimulador,
  MensajeSimulador,
  MetodoPagoCompra,
  PagoCompraReporte,
  PrevisionPagoCompra,
  ProveedorCatalogoCompra,
  SolicitudCompraResumen,
} from './tipos'

// ── Storage de comprobantes ────────────────────────────────────────────────

/**
 * Sube un comprobante al bucket privado `payment-receipts` bajo
 * `<carpeta>/<uuid>.<ext>` y devuelve la ruta. Quien llama la conserva para
 * reintentar la RPC sin subir el archivo otra vez.
 */
export async function subirComprobanteCompra(params: {
  carpeta: string
  file: File
}): Promise<string> {
  const ext = extensionDelComprobante(params.file)
  if (!ext)
    throw new Error(
      'La captura tiene que ser una imagen (JPG, PNG, WEBP) o un PDF.',
    )
  const ruta = `${params.carpeta}/${crypto.randomUUID()}.${ext}`
  const { error } = await supabase.storage
    .from(BUCKET_COMPROBANTES)
    .upload(ruta, params.file, {
      contentType: params.file.type || undefined,
      upsert: false,
    })
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
      p_statuses:
        params.statuses && params.statuses.length > 0 ? params.statuses : null,
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

export async function obtenerConteosCompras(
  signal?: AbortSignal,
): Promise<ConteosCompras> {
  return llamarRpc('admin_purchase_counts', {}, { signal, leer: leerConteos })
}

/** Tope de la cola: la pantalla nunca pide todo el historial. */
export const TOPE_COLA_PAGOS_COMPRA = 200

export async function listarColaPagosCompra(
  statuses: EstadoPagoCompra[],
  signal?: AbortSignal,
): Promise<PagoCompraReporte[]> {
  return llamarRpc(
    'admin_purchase_payment_queue',
    { p_statuses: statuses, p_limit: TOPE_COLA_PAGOS_COMPRA },
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

export async function obtenerAjustesCompras(
  signal?: AbortSignal,
): Promise<AjustesComprasConfig> {
  return llamarRpc(
    'admin_purchase_settings_get',
    {},
    { signal, leer: leerAjustes },
  )
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
}): Promise<void> {
  await llamarRpc('admin_purchase_register_payment', {
    p_request_id: params.requestId,
    p_method: params.method,
    p_bank: params.bank,
    p_reference: params.reference.trim(),
    p_paid_on: params.paidOn,
    p_amount_ves: params.amountVes,
    p_receipt_path: params.receiptPath,
    p_payer_phone: params.payerPhone?.trim() || null,
    p_note: params.note?.trim() || null,
  })
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
  pilotPhones: string[]
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
      p_pilot_phones: params.pilotPhones,
    },
    { leer: leerAjustes },
  )
}

// ── Lecturas del Simulador WhatsApp (los turnos van por `simulador.ts`) ────

export async function listarMedicosSimulador(
  signal?: AbortSignal,
): Promise<MedicoSimulador[]> {
  return llamarRpc(
    'admin_purchase_sim_merchants',
    {},
    { signal, leer: leerMedicosSim },
  )
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
