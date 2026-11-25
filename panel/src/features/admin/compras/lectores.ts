// ═══════════════════════════════════════════════════════════════════════════
// Lectores estrictos del JSON de Compras Amazon.
//
// Cada lector mira SOLO las claves reales que arma el SQL
// (`helios_purchase_request_summary`, `helios_purchase_payment_item`,
// `admin_purchase_*`). Una clave obligatoria que falta, un estado que el panel
// no conoce o un canal raro es un error de contrato: se lanza, no se adivina.
// ═══════════════════════════════════════════════════════════════════════════

import {
  comoFila,
  filaONula,
  filas,
  numeroONulo,
  textoONulo,
  textos,
} from '@/lib/json'
import { leerEstadoPagoCompra, leerEstadoSolicitud } from './estados'
import type {
  AjustesComprasConfig,
  BotonSimulador,
  CanalCompra,
  ConteosCompras,
  DetalleSolicitudCompra,
  EventoSolicitudCompra,
  MedicoSimulador,
  MensajeSimulador,
  MetodoEnvioCompra,
  MetodoPagoCompra,
  PagoCompraReporte,
  PrevisionPagoCompra,
  ProveedorCatalogoCompra,
  SolicitudCompraResumen,
} from './tipos'

type Fila = Record<string, unknown>

function falla(donde: string, campo: string): never {
  throw new Error(
    `Respuesta inesperada de ${donde}: falta o es inválido «${campo}».`,
  )
}

function tieneClave(r: Fila, campo: string): boolean {
  return Object.hasOwn(r, campo)
}

function reqTexto(r: Fila, campo: string, donde: string): string {
  return textoONulo(r[campo]) ?? falla(donde, campo)
}

function reqNumero(r: Fila, campo: string, donde: string): number {
  return numeroONulo(r[campo]) ?? falla(donde, campo)
}

function reqBool(r: Fila, campo: string, donde: string): boolean {
  const v = r[campo]
  return typeof v === 'boolean' ? v : falla(donde, campo)
}

/** Booleano que puede no venir: `null` es «el servidor no lo dijo». */
function boolONulo(r: Fila, campo: string): boolean | null {
  const v = r[campo]
  return typeof v === 'boolean' ? v : null
}

function leerCanal(v: unknown, donde: string): CanalCompra {
  if (v === 'whatsapp' || v === 'simulador') return v
  return falla(donde, 'channel')
}

function leerMetodoEnvio(v: unknown, donde: string): MetodoEnvioCompra {
  if (v === 'aereo' || v === 'maritimo') return v
  return falla(donde, 'shipping_method')
}

function leerMetodoPago(v: unknown, donde: string): MetodoPagoCompra {
  if (v === 'pago_movil' || v === 'transferencia') return v
  return falla(donde, 'method')
}

export function leerProveedor(
  v: unknown,
  donde: string,
): ProveedorCatalogoCompra {
  if (v === 'mock' || v === 'rainforest') return v
  return falla(donde, 'catalog_provider')
}

/** `#C-0012` con el número real. */
export function codigoDeSolicitud(requestNumber: number): string {
  return `#C-${String(requestNumber).padStart(4, '0')}`
}

export function leerSolicitud(raw: unknown): SolicitudCompraResumen {
  const d = 'la solicitud de compra'
  const r = comoFila(raw)
  const requestNumber = reqNumero(r, 'request_number', d)
  return {
    id: reqTexto(r, 'id', d),
    requestNumber,
    code: codigoDeSolicitud(requestNumber),
    merchantId: reqTexto(r, 'merchant_id', d),
    merchantName: reqTexto(r, 'merchant_name', d),
    doctorName: textoONulo(r.staff_name),
    phone: reqTexto(r, 'phone_e164', d),
    channel: leerCanal(r.channel, d),
    status: leerEstadoSolicitud(r.status),
    asin: reqTexto(r, 'asin', d),
    productTitle: reqTexto(r, 'product_title', d),
    productUrl: reqTexto(r, 'product_url', d),
    imageUrl: textoONulo(r.image_url),
    variantLabel: textoONulo(r.variant_label),
    quantity: reqNumero(r, 'quantity', d),
    category: textoONulo(r.category),
    shippingMethod: leerMetodoEnvio(r.shipping_method, d),
    unitPriceUsd: reqNumero(r, 'unit_price_usd', d),
    subtotalUsd: reqNumero(r, 'subtotal_usd', d),
    taxUsaUsd: reqNumero(r, 'tax_usa_usd', d),
    shippingUsd: reqNumero(r, 'shipping_usd', d),
    serviceFeeUsd: reqNumero(r, 'service_fee_usd', d),
    totalUsd: reqNumero(r, 'total_usd', d),
    bcvRateQuote: numeroONulo(r.quoted_fx_rate),
    totalVesQuote: numeroONulo(r.quoted_ves),
    weightLb: numeroONulo(r.weight_lb),
    volumetricWeightLb: numeroONulo(r.volumetric_weight_lb),
    volumeFt3: numeroONulo(r.volume_ft3),
    weightEstimated: reqBool(r, 'weight_estimated', d),
    restrictedFlag: reqBool(r, 'restricted_flag', d),
    restrictedReason: textoONulo(r.restricted_reason),
    amazonOrderId: textoONulo(r.amazon_order_id),
    usTrackingNumber: textoONulo(r.us_tracking_number),
    quoteExpiresAt: textoONulo(r.quote_expires_at),
    vencida: boolONulo(r, 'vencida'),
    createdAt: reqTexto(r, 'created_at', d),
    updatedAt: reqTexto(r, 'updated_at', d),
  }
}

export function leerPago(raw: unknown): PagoCompraReporte {
  const d = 'el pago de la compra'
  const r = comoFila(raw)
  for (const clave of [
    'diferencia_ves',
    'monto_cuadra',
    'declared_amount_ves',
  ]) {
    if (!tieneClave(r, clave)) falla(d, clave)
  }
  const requestNumber = reqNumero(r, 'request_number', d)
  const montoCuadra = r.monto_cuadra
  return {
    id: reqTexto(r, 'report_id', d),
    requestId: reqTexto(r, 'request_id', d),
    requestNumber,
    requestCode: codigoDeSolicitud(requestNumber),
    merchantId: reqTexto(r, 'merchant_id', d),
    merchantName: reqTexto(r, 'merchant_name', d),
    doctorName: textoONulo(r.staff_name),
    phone: reqTexto(r, 'phone_e164', d),
    productTitle: reqTexto(r, 'product_title', d),
    channel: leerCanal(r.channel, d),
    method: leerMetodoPago(r.method, d),
    bank: textoONulo(r.bank),
    reference: textoONulo(r.reference),
    payerPhone: textoONulo(r.payer_phone),
    paidOn: reqTexto(r, 'paid_on', d).slice(0, 10),
    amountUsd: reqNumero(r, 'total_usd', d),
    fxRate: numeroONulo(r.fx_rate),
    expectedVes: numeroONulo(r.expected_ves),
    amountVes: numeroONulo(r.declared_amount_ves),
    montoDeclarado: reqBool(r, 'monto_declarado', d),
    diferenciaVes: numeroONulo(r.diferencia_ves),
    montoCuadra: typeof montoCuadra === 'boolean' ? montoCuadra : null,
    cotizacionVencida: boolONulo(r, 'cotizacion_vencida'),
    receiptPath: textoONulo(r.receipt_path),
    status: leerEstadoPagoCompra(r.status),
    rejectionNote: textoONulo(r.rejection_note),
    note: textoONulo(r.note),
    referenceCollisions: reqNumero(r, 'reference_collisions', d),
    fourEyes: reqBool(r, 'four_eyes', d),
    canApprove: reqBool(r, 'can_approve', d),
    registeredById: textoONulo(r.registered_by),
    registeredByName: textoONulo(r.registered_by_name),
    reviewedById: textoONulo(r.reviewed_by),
    reviewedByName: textoONulo(r.reviewed_by_name),
    reviewedAt: textoONulo(r.reviewed_at),
    createdAt: reqTexto(r, 'created_at', d),
  }
}

function leerEvento(raw: unknown): EventoSolicitudCompra {
  const d = 'un evento de la solicitud'
  const r = comoFila(raw)
  const detalle = filaONula(r.detail)
  return {
    id: reqTexto(r, 'id', d),
    eventType: reqTexto(r, 'kind', d),
    title: reqTexto(r, 'title', d),
    fromStatus: textoONulo(detalle?.from_status),
    toStatus: textoONulo(detalle?.to_status),
    actorName: textoONulo(r.actor_name),
    note: textoONulo(detalle?.note ?? detalle?.reason),
    createdAt: reqTexto(r, 'created_at', d),
  }
}

export function leerDetalle(raw: unknown): DetalleSolicitudCompra | null {
  if (raw === null || raw === undefined) return null
  const d = 'el detalle de la compra'
  const r = comoFila(raw)
  if (!filaONula(r.request)) falla(d, 'request')
  return {
    request: leerSolicitud(r.request),
    payments: filas(r.payments).map(leerPago),
    events: filas(r.events).map(leerEvento),
    paymentBlock: textoONulo(r.payment_block),
    bcvRateToday: numeroONulo(r.bcv_rate_today),
  }
}

export function leerConteos(raw: unknown): ConteosCompras {
  const d = 'los conteos de compras'
  const r = comoFila(raw)
  const n = (campo: string) => reqNumero(r, campo, d)
  return {
    revisionAduanal: n('revision_aduanal'),
    pagosPendientes: n('payments_pending'),
    esperandoPago: n('esperando_pago'),
    enProcura: n('pagado') + n('comprado_amazon') + n('en_almacen_usa'),
    enTransito: n('en_transito') + n('en_aduana'),
    listoEntrega: n('listo_entrega'),
    totalActivas: n('active'),
    simulador: n('simulador_count'),
  }
}

export function leerPrevision(raw: unknown): PrevisionPagoCompra {
  const d = 'la previsión del pago'
  const r = comoFila(raw)
  return {
    requestId: reqTexto(r, 'request_id', d),
    paidOn: reqTexto(r, 'paid_on', d),
    amountUsd: reqNumero(r, 'total_usd', d),
    fxRate: reqNumero(r, 'fx_rate', d),
    expectedVes: reqNumero(r, 'expected_ves', d),
  }
}

export function leerAjustes(raw: unknown): AjustesComprasConfig {
  const d = 'los ajustes de compras'
  const r = comoFila(raw)
  if (!Array.isArray(r.pilot_phones)) falla(d, 'pilot_phones')
  if (!Array.isArray(r.pilot_status)) falla(d, 'pilot_status')
  const pilotStatus = filas(r.pilot_status).map((e) => ({
    phone: reqTexto(e, 'phone', d),
    registrado: reqBool(e, 'registrado', d),
    nombre: textoONulo(e.nombre),
  }))
  return {
    taxUsaPct: reqNumero(r, 'tax_usa_pct', d),
    serviceFeePct: reqNumero(r, 'service_fee_pct', d),
    airRatePerLbUsd: reqNumero(r, 'air_rate_per_lb_usd', d),
    airMinUsd: reqNumero(r, 'air_min_usd', d),
    seaRatePerFt3Usd: reqNumero(r, 'sea_rate_per_ft3_usd', d),
    seaMinUsd: reqNumero(r, 'sea_min_usd', d),
    fallbackWeightLb: reqNumero(r, 'fallback_weight_lb', d),
    quoteTtlHours: reqNumero(r, 'quote_ttl_hours', d),
    catalogProvider: leerProveedor(r.catalog_provider, d),
    isEnabled: reqBool(r, 'is_enabled', d),
    pilotPhones: textos(r.pilot_phones),
    pilotStatus,
    bcvRateToday: numeroONulo(r.fx_rate_usd),
    updatedAt: textoONulo(r.updated_at),
  }
}

export function leerMedicosSim(raw: unknown): MedicoSimulador[] {
  const d = 'los médicos del simulador'
  const salida: MedicoSimulador[] = []
  for (const r of filas(raw)) {
    const merchantId = reqTexto(r, 'merchant_id', d)
    const merchantName = reqTexto(r, 'merchant_name', d)
    for (const s of filas(r.staff_numbers)) {
      const phone = reqTexto(s, 'phone_e164', d)
      salida.push({
        key: `${merchantId}:${phone}`,
        merchantId,
        merchantName,
        doctorName: textoONulo(s.staff_name),
        role: textoONulo(s.role),
        phone,
        userId: reqTexto(s, 'user_id', d),
      })
    }
  }
  return salida
}

function leerBotones(v: unknown): BotonSimulador[] {
  return filas(v).map((b) => ({
    id: reqTexto(b, 'id', 'un botón'),
    title: reqTexto(b, 'title', 'un botón'),
  }))
}

/** Lee un mensaje en una de las formas canónicas del contrato §4; cualquier otra es un error visible. */
export function leerMensajeSim(raw: unknown): MensajeSimulador {
  const d = 'un mensaje del simulador'
  const r = comoFila(raw)
  const p = comoFila(r.payload)
  const kind = r.kind
  const base = {
    id: reqTexto(r, 'id', d),
    phone: reqTexto(r, 'phone_e164', d),
    direction:
      r.direction === 'in'
        ? ('in' as const)
        : r.direction === 'out'
          ? ('out' as const)
          : falla(d, 'direction'),
    body: typeof r.body === 'string' ? r.body : '',
    createdAt: reqTexto(r, 'created_at', d),
  }
  if (kind === 'text') return { ...base, contenido: { kind: 'text' } }
  if (kind === 'buttons')
    return {
      ...base,
      contenido: { kind: 'buttons', buttons: leerBotones(p.buttons) },
    }
  if (kind === 'list') {
    const sections = filas(p.sections).map((s) => ({
      title: textoONulo(s.title) ?? '',
      rows: filas(s.rows).map((f) => ({
        id: reqTexto(f, 'id', 'una fila'),
        title: reqTexto(f, 'title', 'una fila'),
        description: textoONulo(f.description),
      })),
    }))
    return {
      ...base,
      contenido: {
        kind: 'list',
        button: reqTexto(p, 'button', 'la lista'),
        sections,
      },
    }
  }
  if (kind === 'image')
    return {
      ...base,
      contenido: {
        kind: 'image',
        receiptPath: reqTexto(p, 'receipt_path', 'la imagen'),
      },
    }
  return falla(d, 'kind')
}
