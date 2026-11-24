// ═══════════════════════════════════════════════════════════════════════════
// Helios — Flujo conversacional de Compras en Amazon para médicos
//
// Orquesta los estados `compra_*` dentro de `whatsapp_sessions`:
//   compra_buscar      → texto de búsqueda o link/ASIN directo de Amazon
//   compra_resultados  → carrusel interactivo (2–4 cards) o tarjeta única
//   compra_envio       → detalle + peso/dimensiones + aéreo vs. marítimo
//   compra_confirmar   → desglose USD y Bs BCV + confirmación (`bot_compra_crear`)
//   compra_pago        → captura/PDF (`bot_compra_reportar_pago`) o «datos»
//   compra_pago_datos  → Pago Móvil escrito vía `datos_pago.ts`
//
// Reglas externas (CLAUDE.md): español de Venezuela, formato venezolano
// (`dinero`, `bolivares`), cero vocabulario prohibido (jamás préstamo,
// financiamiento, financiar, crédito ni fee).
// ═══════════════════════════════════════════════════════════════════════════

import { bolivares, dinero, montoEs } from '../datos.ts'
import {
  faltanDatosDePago,
  formularioDePago,
  juntarDatosDePago,
  leerDatosDePago,
  nombrarCampos,
  quiereEscribirLosDatos,
} from '../datos_pago.ts'
import type { DatosDePago } from '../datos_pago.ts'
import { normalizar } from '../logica.ts'
import type { EventoDeMensaje } from '../logica.ts'
import { extraerAsinDeTexto } from './amazon_parser.ts'
import { calcularCotizacion, recomendarEnvio } from './cotizador.ts'
import type {
  CotizacionCompra,
  DatosCompra,
  EstadoCompra,
  MetodoEnvio,
  ProductoDetalle,
  ProductoResumen,
  ProveedorCatalogo,
  TarifasCompra,
  TarjetaCarrusel,
} from './tipos.ts'

export type BotonCompra = { id: string; title: string }

export type RpcCompra = <T>(fn: string, args: Record<string, unknown>) => Promise<T>

export type PersonalCompra = {
  id: string
  phone_e164: string
  user_id: string
  staff_name: string | null
  role: 'gerente' | 'cajero' | null
  merchant_id: string
  merchant_name: string | null
}

export type ContextoCompra = {
  rpc: RpcCompra
  personal: PersonalCompra
  mensaje: EventoDeMensaje
  sesion: { state: string; data: Record<string, unknown>; nueva?: boolean }
  enviar: (texto: string, botones?: BotonCompra[]) => Promise<unknown>
  enviarCarrusel: (cuerpo: string, tarjetas: TarjetaCarrusel[]) => Promise<unknown>
  guardar: (state: EstadoCompra, data?: DatosCompra) => Promise<unknown>
  volverAlMenu: (saludo?: string) => Promise<unknown>
  proveedor: ProveedorCatalogo
}

export const ESTADOS_COMPRA: readonly EstadoCompra[] = [
  'compra_buscar',
  'compra_resultados',
  'compra_envio',
  'compra_confirmar',
  'compra_pago',
  'compra_pago_datos',
] as const

const SET_ESTADOS_COMPRA = new Set<string>(ESTADOS_COMPRA)

/** Type-guard: indica si el estado de sesión pertenece al flujo de compras. */
export function ES_ESTADO_COMPRA(estado: string): estado is EstadoCompra {
  return SET_ESTADOS_COMPRA.has(estado)
}

const ATAJOS_TEXTO_COMPRA = new Set([
  'comprar',
  'comprar en amazon',
  'amazon',
  'catalogo',
  'catalogo amazon',
  'mis compras',
  'mis pedidos',
])

/** Detecta si el mensaje o botón dispara directamente el flujo de compras. */
export function esAtajoDeCompra(texto: string, boton: string): boolean {
  if (boton === 'menu:comprar' || boton.startsWith('compra:')) return true
  const n = normalizar(texto)
  if (ATAJOS_TEXTO_COMPRA.has(n)) return true
  return extraerAsinDeTexto(texto) !== null
}

const TARIFAS_RESPALDO: TarifasCompra = {
  taxUsaPct: 7,
  serviceFeePct: 10,
  airRatePerLbUsd: 6.5,
  airMinUsd: 15,
  seaRatePerFt3Usd: 28,
  seaMinUsd: 35,
  fallbackWeightLb: 1.5,
  fxRateUsd: 100,
  accountsBlock: '',
}

const ERRORES_DE_NEGOCIO = new Set(['P0001', '22023', 'P0002', '42501', '28000', '55000'])

const ESTADO_COMPRA_ETIQUETA: Record<string, string> = {
  cotizado: 'Cotizado',
  revision_aduanal: 'En revisión aduanal',
  esperando_pago: 'Esperando pago',
  pago_reportado: 'Pago en verificación',
  pagado: 'Pago confirmado',
  pago_confirmado: 'Pago confirmado',
  comprado_amazon: 'Comprado en Amazon',
  comprado: 'Comprado en Amazon',
  en_almacen_usa: 'En almacén USA',
  en_transito: 'En tránsito a Venezuela',
  en_aduana: 'En aduana',
  listo_entrega: 'Listo para entrega',
  entregado: 'Entregado',
  cancelado: 'Cancelado',
  rechazado: 'No aprobado',
}

const BOTONES_BUSCAR: BotonCompra[] = [
  { id: 'compra:mis', title: 'Mis compras' },
  { id: 'orden:cancelar', title: 'Volver al menú' },
]

const BOTONES_DESPUES_ACCION: BotonCompra[] = [
  { id: 'compra:mis', title: 'Mis compras' },
  { id: 'compra:buscar', title: 'Nueva búsqueda' },
  { id: 'orden:cancelar', title: 'Volver al menú' },
]

const BOTONES_ENVIO: BotonCompra[] = [
  { id: 'compra:envio:aereo', title: 'Envío aéreo' },
  { id: 'compra:envio:maritimo', title: 'Envío marítimo' },
  { id: 'compra:buscar', title: 'Buscar otro' },
]

const BOTONES_CONFIRMAR: BotonCompra[] = [
  { id: 'compra:confirmar', title: 'Confirmar compra' },
  { id: 'compra:cambiar_envio', title: 'Cambiar envío' },
  { id: 'orden:cancelar', title: 'Cancelar' },
]

const BOTONES_PAGO: BotonCompra[] = [
  { id: 'compra:ya_pague', title: 'Ya pagué' },
  { id: 'compra:datos_pago', title: 'Escribir datos' },
  { id: 'compra:mis', title: 'Mis compras' },
]

function truncar(texto: string, max: number): string {
  const limpio = texto.replace(/\s+/g, ' ').trim()
  if (limpio.length <= max) return limpio
  return `${limpio.slice(0, Math.max(1, max - 1)).trimEnd()}…`
}

function formatoNumeroCompra(valor: unknown): string {
  const s = String(valor ?? '').trim()
  if (s === '') return '#C-0000'
  if (s.startsWith('#')) return s
  if (/^C-/i.test(s)) return `#${s.toUpperCase()}`
  if (/^\d+$/.test(s)) return `#C-${s}`
  return `#${s}`
}

function numeroPositivo(v: unknown): number | null {
  const n = Number(v)
  return v != null && Number.isFinite(n) && n > 0 ? n : null
}

function numeroNoNegativo(v: unknown): number | null {
  const n = Number(v)
  return v != null && Number.isFinite(n) && n >= 0 ? n : null
}

function normalizarTarifas(raw: Record<string, unknown> | null | undefined): TarifasCompra {
  if (!raw) return { ...TARIFAS_RESPALDO }
  return {
    taxUsaPct: numeroNoNegativo(raw.tax_usa_pct ?? raw.taxUsaPct) ?? TARIFAS_RESPALDO.taxUsaPct,
    serviceFeePct: numeroNoNegativo(raw.service_fee_pct ?? raw.serviceFeePct) ?? TARIFAS_RESPALDO.serviceFeePct,
    airRatePerLbUsd: numeroPositivo(raw.air_rate_per_lb_usd ?? raw.airRatePerLbUsd) ?? TARIFAS_RESPALDO.airRatePerLbUsd,
    airMinUsd: numeroPositivo(raw.air_min_usd ?? raw.airMinUsd) ?? TARIFAS_RESPALDO.airMinUsd,
    seaRatePerFt3Usd:
      numeroPositivo(raw.sea_rate_per_ft3_usd ?? raw.seaRatePerFt3Usd) ?? TARIFAS_RESPALDO.seaRatePerFt3Usd,
    seaMinUsd: numeroPositivo(raw.sea_min_usd ?? raw.seaMinUsd) ?? TARIFAS_RESPALDO.seaMinUsd,
    fallbackWeightLb:
      numeroPositivo(raw.fallback_weight_lb ?? raw.fallbackWeightLb) ?? TARIFAS_RESPALDO.fallbackWeightLb,
    fxRateUsd:
      numeroPositivo(raw.fx_rate_usd ?? raw.fxRateUsd ?? raw.bcv_rate ?? raw.bcvRate) ?? TARIFAS_RESPALDO.fxRateUsd,
    accountsBlock: String(raw.accounts_block ?? raw.accountsBlock ?? raw.payment_block ?? '').trim(),
  }
}

function detalleDesdeResumen(r: ProductoResumen): ProductoDetalle {
  return {
    ...r,
    variantes: [],
    disponible: true,
    descripcionCorta: '',
  }
}

function nombreEnvio(envio: MetodoEnvio): string {
  return envio === 'maritimo' ? 'Marítimo' : 'Aéreo'
}

/** Construye una tarjeta de carrusel (≤ 160 caracteres) con precio base y estimado en Venezuela. */
function construirTarjeta(p: ProductoResumen, tarifas: TarifasCompra): TarjetaCarrusel {
  const metodo = recomendarEnvio(p)
  const cot = calcularCotizacion(p, tarifas, metodo, 1)
  const est = `Amazon: ${dinero(p.precioUsd)} · Est. VE: ${dinero(cot.totalUsd)}`
  const ratingTexto = p.rating != null ? ` ⭐${montoEs(p.rating)}` : ''
  const maxTitulo = Math.max(24, 155 - est.length - ratingTexto.length - 2)
  const cuerpo = `${truncar(p.titulo, maxTitulo)}${ratingTexto}\n${est}`.slice(0, 160)
  return {
    image_url: p.imagenUrl,
    body: cuerpo,
    button_id: `compra:ver:${p.asin}`,
    button_title: 'Ver y cotizar',
  }
}

export async function atenderCompraMedico({
  rpc,
  personal,
  mensaje,
  sesion,
  enviar,
  enviarCarrusel,
  guardar,
  volverAlMenu,
  proveedor,
}: ContextoCompra): Promise<unknown> {
  const tel = personal.phone_e164
  const estado = sesion.state
  const datos = (sesion.data ?? {}) as DatosCompra
  const texto = (mensaje.texto ?? '').trim()
  const boton = (mensaje.boton ?? '').trim()
  const n = normalizar(texto)

  async function probar<T>(
    fn: string,
    args: Record<string, unknown>,
  ): Promise<{ ok: true; data: T } | { ok: false; mensaje: string }> {
    try {
      return { ok: true, data: await rpc<T>(fn, args) }
    } catch (err) {
      const m = err instanceof Error ? err.message : String(err)
      const code = (err as { code?: unknown } | null)?.code
      if (typeof code === 'string' && ERRORES_DE_NEGOCIO.has(code)) {
        return { ok: false, mensaje: m.replace(/^[a-z_]+: /, '') }
      }
      console.error('compras', fn, code, m)
      return { ok: false, mensaje: 'No pudimos completarlo en este momento. Inténtalo de nuevo en unos minutos.' }
    }
  }

  async function cargarTarifas(): Promise<{ tarifas: TarifasCompra; habilitado: boolean }> {
    if (datos.tarifas && datos.tarifas.fxRateUsd > 0) {
      return { tarifas: datos.tarifas, habilitado: true }
    }
    try {
      const raw = await rpc<Record<string, unknown> | null>('bot_compra_config', {})
      const habilitado = raw?.is_enabled !== false
      return { tarifas: normalizarTarifas(raw), habilitado }
    } catch (err) {
      console.warn('compras: fallo al leer configuración, uso respaldo', err)
      return { tarifas: { ...TARIFAS_RESPALDO }, habilitado: true }
    }
  }

  async function cacheGet<T>(clave: string): Promise<T | null> {
    try {
      const res = await rpc<unknown>('bot_compra_cache_get', { p_key: clave })
      if (!res) return null
      if (typeof res === 'object' && res !== null && 'payload' in (res as Record<string, unknown>)) {
        const p = (res as { payload?: T | null }).payload
        return p ?? null
      }
      return res as T
    } catch {
      return null
    }
  }

  async function cacheSet(
    clave: string,
    kind: 'search' | 'product',
    payload: unknown,
    ttlMinutes = 60,
  ): Promise<void> {
    try {
      await rpc('bot_compra_cache_set', {
        p_key: clave,
        p_kind: kind,
        p_provider: proveedor.nombre,
        p_payload: payload,
        p_ttl_minutes: ttlMinutes,
      })
    } catch {
      // El fallo de caché nunca debe interrumpir al médico.
    }
  }

  async function buscarCatalogo(consulta: string, limite = 4): Promise<ProductoResumen[]> {
    const clave = `search:${proveedor.nombre}:${normalizar(consulta)}`
    const enCache = await cacheGet<ProductoResumen[]>(clave)
    if (Array.isArray(enCache) && enCache.length > 0) return enCache.slice(0, limite)
    const resultados = await proveedor.buscar(consulta, limite)
    if (resultados.length > 0) await cacheSet(clave, 'search', resultados, 45)
    return resultados
  }

  async function detalleCatalogo(asin: string, respaldo?: ProductoResumen | null): Promise<ProductoDetalle | null> {
    const limpio = asin.trim().toUpperCase()
    const clave = `product:${proveedor.nombre}:${limpio}`
    const enCache = await cacheGet<ProductoDetalle>(clave)
    if (enCache && typeof enCache === 'object' && typeof enCache.asin === 'string') return enCache
    const detalle = await proveedor.detalle(limpio)
    if (detalle) {
      await cacheSet(clave, 'product', detalle, 120)
      return detalle
    }
    return respaldo ? detalleDesdeResumen(respaldo) : null
  }

  // ── Helper: mostrar detalle + comparación Aéreo vs. Marítimo ──────────
  async function mostrarDetalleYEnvio(producto: ProductoDetalle, tarifas: TarifasCompra, cantidad = 1) {
    if (!producto.disponible) {
      await guardar('compra_buscar', { tarifas })
      await enviar(
        `El producto *${truncar(producto.titulo, 90)}* no está disponible en Amazon en este momento. Prueba con otra búsqueda o pega otro enlace.`,
        BOTONES_BUSCAR,
      )
      return { paso: 'compra_no_disponible', asin: producto.asin }
    }

    const cotAereo = calcularCotizacion(producto, tarifas, 'aereo', cantidad)
    const cotMaritimo = calcularCotizacion(producto, tarifas, 'maritimo', cantidad)
    const recomendado = recomendarEnvio(producto)

    const lineaRating =
      producto.rating != null
        ? `⭐ ${montoEs(producto.rating)}${producto.resenas ? ` (${montoEs(producto.resenas)} reseñas)` : ''}${producto.prime ? ' · Prime' : ''}`
        : producto.prime
          ? 'Prime disponible'
          : ''

    const dimsTexto = producto.dimensionesIn
      ? ` · ${montoEs(producto.dimensionesIn.largo)}×${montoEs(producto.dimensionesIn.ancho)}×${montoEs(producto.dimensionesIn.alto)} in`
      : ''

    const lineaPeso = cotAereo.weightEstimated
      ? `Peso estimado: ${montoEs(cotAereo.weightLb)} lb (Amazon no publica peso; se ajustará si varía al llegar al almacén)`
      : `Peso: ${montoEs(cotAereo.weightLb)} lb${dimsTexto}`

    const avisoAduana = cotAereo.restriccion.restringido
      ? `\n⚠️ *Revisión aduanal:* ${cotAereo.restriccion.motivo}`
      : ''

    const cuerpo =
      `*${truncar(producto.titulo, 110)}*\n` +
      (lineaRating ? `${lineaRating}\n` : '') +
      `Precio en Amazon: ${dinero(producto.precioUsd)}\n` +
      `${lineaPeso}${avisoAduana}\n\n` +
      'Elige cómo quieres traerlo a Venezuela:\n' +
      `• *Aéreo* (7–12 días aprox.): *${dinero(cotAereo.totalUsd)}* (${bolivares(cotAereo.totalVes)})${recomendado === 'aereo' ? ' · Recomendado' : ''}\n` +
      `• *Marítimo* (3–5 semanas aprox.): *${dinero(cotMaritimo.totalUsd)}* (${bolivares(cotMaritimo.totalVes)})${recomendado === 'maritimo' ? ' · Recomendado' : ''}\n\n` +
      `Referencia en bolívares a tasa BCV de hoy (${bolivares(tarifas.fxRateUsd)}/$).`

    await guardar('compra_envio', {
      ...datos,
      producto,
      tarifas,
      cantidad,
      envio: null,
      cotizacion: null,
    })
    await enviar(cuerpo, BOTONES_ENVIO)
    return {
      paso: 'compra_envio',
      asin: producto.asin,
      recomendado,
      restringido: cotAereo.restriccion.restringido,
    }
  }

  // ── Helper: ejecutar búsqueda y enviar carrusel (o resultado único) ───
  async function ejecutarBusqueda(consulta: string) {
    const { tarifas, habilitado } = await cargarTarifas()
    if (!habilitado) {
      return volverAlMenu('El servicio de compras en Amazon no está disponible temporalmente. ¿Qué más quieres hacer?')
    }
    const asinDirecto = extraerAsinDeTexto(consulta)
    if (asinDirecto) {
      const det = await detalleCatalogo(asinDirecto)
      if (det) return mostrarDetalleYEnvio(det, tarifas)
      await guardar('compra_buscar', { tarifas })
      await enviar(
        `No pude cargar el producto con código ${asinDirecto} en Amazon. Verifica el enlace o escribe el nombre del artículo para buscarlo.`,
        BOTONES_BUSCAR,
      )
      return { paso: 'compra_buscar', encontrado: false, asin: asinDirecto }
    }

    const resultados = await buscarCatalogo(consulta, 4)
    if (resultados.length === 0) {
      await guardar('compra_buscar', { tarifas, consulta })
      await enviar(
        `No encontré resultados en Amazon para «${truncar(consulta, 60)}». Prueba con otro término (por ejemplo: «estetoscopio», «tensiómetro», «autoclave») o pega el enlace directo de Amazon.`,
        BOTONES_BUSCAR,
      )
      return { paso: 'compra_buscar', cuantos: 0 }
    }

    const tarjetas = resultados.map((p) => construirTarjeta(p, tarifas))
    const encabezado =
      resultados.length === 1
        ? `Encontré 1 resultado para «${truncar(consulta, 50)}». Pulsa «Ver y cotizar», escribe «1» o haz otra búsqueda:`
        : `Top ${resultados.length} en Amazon para «${truncar(consulta, 50)}». Desliza y pulsa «Ver y cotizar», escribe el número (1–${resultados.length}) o escribe otra búsqueda:`

    await guardar('compra_resultados', {
      consulta,
      resultados,
      tarifas,
      producto: null,
      envio: null,
      cotizacion: null,
    })
    await enviarCarrusel(encabezado, tarjetas)
    return { paso: 'compra_resultados', cuantos: resultados.length }
  }

  // ── Helper: mostrar resumen final y pedir confirmación ────────────────
  async function mostrarConfirmacion(producto: ProductoDetalle, tarifas: TarifasCompra, metodo: MetodoEnvio) {
    const cantidad = datos.cantidad ?? 1
    const cot: CotizacionCompra = calcularCotizacion(producto, tarifas, metodo, cantidad)

    const notaPeso = cot.weightEstimated
      ? `\nNota: peso estimado (${montoEs(cot.weightLb)} lb); si cambia en almacén te avisamos.`
      : ''
    const notaAduana = cot.restriccion.restringido
      ? '\n⚠️ Este artículo pasa primero por revisión aduanal antes de realizar el pago.'
      : ''

    const cuerpo =
      'Revisa tu cotización antes de confirmar:\n\n' +
      `*${truncar(producto.titulo, 100)}*\n` +
      `Envío: *${nombreEnvio(metodo)}* · Cantidad: ${cot.quantity}\n\n` +
      `• Producto: ${dinero(cot.subtotalUsd)}\n` +
      `• Tax USA (${montoEs(tarifas.taxUsaPct)}%): ${dinero(cot.taxUsaUsd)}\n` +
      `• Envío a Venezuela: ${dinero(cot.shippingUsd)}\n` +
      `• Gestión Helios (${montoEs(tarifas.serviceFeePct)}%): ${dinero(cot.serviceFeeUsd)}\n` +
      `*Total: ${dinero(cot.totalUsd)}*\n` +
      `Equivalente hoy (tasa BCV ${bolivares(cot.fxRateUsd)}/$): *${bolivares(cot.totalVes)}*` +
      `${notaPeso}${notaAduana}`

    await guardar('compra_confirmar', {
      ...datos,
      producto,
      tarifas,
      envio: metodo,
      cantidad,
      cotizacion: cot,
    })
    await enviar(cuerpo, BOTONES_CONFIRMAR)
    return { paso: 'compra_confirmar', envio: metodo, totalUsd: cot.totalUsd }
  }

  // ── Helper: registrar pago por adjunto (foto/PDF) ─────────────────────
  async function reportarPagoPorAdjunto() {
    if (!mensaje.adjunto || !datos.compraId) return null
    const nota = texto || `Comprobante adjunto (${mensaje.adjunto.mime || mensaje.type})`
    const mediaLimpio = mensaje.adjunto.id.replace(/[^a-zA-Z0-9._-]/g, '').slice(0, 80) || 'adjunto'
    const refCaptura = `CAP-${mediaLimpio.slice(-16)}`
    const r = await probar<Record<string, unknown>>('bot_compra_reportar_pago', {
      p_phone: tel,
      p_request_id: datos.compraId,
      p_method: 'pago_movil',
      p_bank: 'Por verificar (captura)',
      p_reference: refCaptura,
      p_payer_phone: null,
      p_amount_ves: null,
      p_receipt_path: `compras/${datos.compraId}/${mediaLimpio}`,
      p_wa_message_id: mensaje.id,
      p_note: nota,
    })
    if (!r.ok) {
      await enviar(r.mensaje, BOTONES_PAGO)
      return { paso: 'compra_pago', error: r.mensaje }
    }
    const numero = datos.compraNumero ?? ''
    await guardar('compra_buscar', {})
    await enviar(
      `Recibimos tu comprobante para la compra ${numero}. El equipo de Helios verificará el pago y te avisaremos por aquí en cuanto confirmemos el pedido en Amazon.`,
      BOTONES_DESPUES_ACCION,
    )
    return { paso: 'compra_pago_reportado', via: 'adjunto', purchase_id: datos.compraId }
  }

  // ── Helper: recibir y validar datos escritos de Pago Móvil ────────────
  async function procesarDatosDePago(entrada: string) {
    const acumulado: DatosDePago = juntarDatosDePago(datos.datosPago ?? {}, leerDatosDePago(entrada))
    const faltan = faltanDatosDePago(acumulado)

    if (faltan.length > 0) {
      const intentos = (datos.intentosDatosPago ?? 0) + 1
      await guardar('compra_pago_datos', {
        ...datos,
        datosPago: acumulado,
        intentosDatosPago: intentos,
      })
      const pista =
        faltan.includes('telefono') || faltan.includes('referencia')
          ? ' Recuerda: teléfono venezolano de 11 dígitos (ej. 04141234567) y referencia completa de 8 a 20 dígitos.'
          : ''
      await enviar(
        `Para registrar el pago todavía necesito ${nombrarCampos(faltan)}.${pista}\n\nEnvíamelo aquí:\n${formularioDePago(faltan)}`,
      )
      return { paso: 'compra_pago_datos', faltan }
    }

    const nota = `Pago Móvil · Banco: ${acumulado.banco} · Teléfono: ${acumulado.telefono} · Referencia: ${acumulado.referencia}`
    const r = await probar<Record<string, unknown>>('bot_compra_reportar_pago', {
      p_phone: tel,
      p_request_id: datos.compraId,
      p_method: 'pago_movil',
      p_bank: acumulado.banco,
      p_reference: acumulado.referencia,
      p_payer_phone: acumulado.telefono,
      p_amount_ves: null,
      p_receipt_path: null,
      p_wa_message_id: mensaje.id,
      p_note: nota,
    })
    if (!r.ok) {
      await enviar(r.mensaje)
      return { paso: 'compra_pago_datos', error: r.mensaje }
    }

    const numero = datos.compraNumero ?? ''
    await guardar('compra_buscar', {})
    await enviar(
      `Listo, registramos los datos de tu Pago Móvil para la compra ${numero}:\n` +
        `• Banco: ${acumulado.banco}\n` +
        `• Teléfono: ${acumulado.telefono}\n` +
        `• Referencia: ${acumulado.referencia}\n\n` +
        'Verificaremos el pago y te avisaremos por aquí en cuanto confirmemos el pedido en Amazon.',
      BOTONES_DESPUES_ACCION,
    )
    return {
      paso: 'compra_pago_reportado',
      via: 'datos',
      purchase_id: datos.compraId,
      datosPago: acumulado,
    }
  }

  // ── 1. Mis compras (desde cualquier paso de compra o desde el menú) ───
  if (boton === 'compra:mis' || ['mis compras', 'mis pedidos'].includes(n)) {
    const r = await probar<Array<Record<string, unknown>>>('bot_compra_mis_solicitudes', {
      p_phone: tel,
      p_limit: 8,
    })
    if (!r.ok) {
      await enviar(r.mensaje, BOTONES_BUSCAR)
      return { paso: 'compra_mis', error: r.mensaje }
    }
    const filas = Array.isArray(r.data) ? r.data : []
    await guardar('compra_buscar', {})
    if (filas.length === 0) {
      await enviar(
        'Todavía no tienes compras en Amazon registradas con Helios.\n\nEscríbeme qué insumo, equipo o libro médico buscas, o pega un enlace de Amazon para cotizarlo.',
        [{ id: 'compra:buscar', title: 'Nueva búsqueda' }, { id: 'orden:cancelar', title: 'Volver al menú' }],
      )
      return { paso: 'compra_mis', cuantas: 0 }
    }

    const lineas = filas.map((f) => {
      const num = formatoNumeroCompra(f.request_number ?? f.code ?? f.id)
      const titulo = truncar(String(f.product_title ?? f.title ?? 'Producto Amazon'), 38)
      const totalUsd = Number(f.total_usd ?? 0)
      const estadoTxt = ESTADO_COMPRA_ETIQUETA[String(f.status ?? '')] ?? String(f.status ?? 'En proceso')
      return `${num} · ${titulo} · ${dinero(totalUsd)} · ${estadoTxt}`
    })

    await enviar(`Tus compras en Amazon:\n${lineas.join('\n')}`, [
      { id: 'compra:buscar', title: 'Nueva búsqueda' },
      { id: 'orden:cancelar', title: 'Volver al menú' },
    ])
    return { paso: 'compra_mis', cuantas: lineas.length }
  }

  // ── 2. Botón «Ver y cotizar» de una tarjeta (`compra:ver:<ASIN>`) ─────
  if (boton.startsWith('compra:ver:')) {
    const asin = boton.slice('compra:ver:'.length).trim().toUpperCase()
    const { tarifas } = await cargarTarifas()
    const respaldo = (datos.resultados ?? []).find((r) => r.asin.toUpperCase() === asin) ?? null
    const det = await detalleCatalogo(asin, respaldo)
    if (!det) {
      await guardar('compra_buscar', { tarifas })
      await enviar(
        'No pude cargar el detalle de ese producto. Escribe nuevamente lo que buscas o pega el enlace de Amazon.',
        BOTONES_BUSCAR,
      )
      return { paso: 'compra_buscar', encontrado: false }
    }
    return mostrarDetalleYEnvio(det, tarifas)
  }

  // ── 3. Iniciar / reiniciar búsqueda ───────────────────────────────────
  if (
    boton === 'menu:comprar' ||
    boton === 'compra:buscar' ||
    (!ES_ESTADO_COMPRA(estado) &&
      (['comprar', 'comprar en amazon', 'amazon', 'catalogo', 'catalogo amazon', '3'].includes(n)))
  ) {
    await guardar('compra_buscar', {})
    await enviar(
      '¿Qué insumo, equipo o libro médico quieres buscar en Amazon?\n\n' +
        'Escríbeme el nombre (por ejemplo: «estetoscopio Littmann», «oxímetro», «autoclave») o pega el enlace directo de Amazon.',
      BOTONES_BUSCAR,
    )
    return { paso: 'compra_buscar' }
  }

  // ── 4. Link o ASIN directo pegado desde el menú ───────────────────────
  if (!ES_ESTADO_COMPRA(estado)) {
    const asinDirecto = extraerAsinDeTexto(texto)
    if (asinDirecto) {
      return ejecutarBusqueda(asinDirecto)
    }
    return volverAlMenu()
  }

  // ── 5. Estado: compra_buscar ──────────────────────────────────────────
  if (estado === 'compra_buscar') {
    if (!texto) {
      await enviar(
        'Escribe el nombre del producto médico que buscas en Amazon o pega su enlace directo.',
        BOTONES_BUSCAR,
      )
      return { paso: 'compra_buscar' }
    }
    return ejecutarBusqueda(texto)
  }

  // ── 6. Estado: compra_resultados ──────────────────────────────────────
  if (estado === 'compra_resultados') {
    const resultados = datos.resultados ?? []
    const indice = /^[1-4]$/.test(n) ? Number(n) - 1 : -1
    if (indice >= 0 && resultados[indice]) {
      const elegido = resultados[indice]
      const { tarifas } = await cargarTarifas()
      const det = await detalleCatalogo(elegido.asin, elegido)
      if (det) return mostrarDetalleYEnvio(det, tarifas)
    }
    if (!texto) {
      await enviar(
        'Pulsa «Ver y cotizar» en una tarjeta, escribe un número del 1 al 4 o escribe una nueva búsqueda.',
        BOTONES_BUSCAR,
      )
      return { paso: 'compra_resultados' }
    }
    return ejecutarBusqueda(texto)
  }

  // ── 7. Estado: compra_envio ───────────────────────────────────────────
  if (estado === 'compra_envio') {
    const producto = datos.producto
    const { tarifas } = await cargarTarifas()
    if (!producto) {
      await guardar('compra_buscar', {})
      await enviar('No tengo un producto seleccionado. Escribe qué artículo buscas en Amazon:', BOTONES_BUSCAR)
      return { paso: 'compra_buscar' }
    }

    if (boton === 'compra:envio:aereo' || ['aereo', 'envio aereo', 'avion', '1'].includes(n)) {
      return mostrarConfirmacion(producto, tarifas, 'aereo')
    }
    if (boton === 'compra:envio:maritimo' || ['maritimo', 'envio maritimo', 'barco', '2'].includes(n)) {
      return mostrarConfirmacion(producto, tarifas, 'maritimo')
    }

    // Si pegó un nuevo enlace de Amazon aquí, lo cotizamos directamente.
    const otroAsin = extraerAsinDeTexto(texto)
    if (otroAsin) return ejecutarBusqueda(otroAsin)

    await enviar('Elige el método de envío para continuar: *Envío aéreo* o *Envío marítimo*.', BOTONES_ENVIO)
    return { paso: 'compra_envio' }
  }

  // ── 8. Estado: compra_confirmar ───────────────────────────────────────
  if (estado === 'compra_confirmar') {
    const producto = datos.producto
    const { tarifas } = await cargarTarifas()
    const metodo = datos.envio
    if (!producto || !metodo) {
      await guardar('compra_buscar', {})
      await enviar('La cotización se reinició. Escribe nuevamente lo que buscas en Amazon:', BOTONES_BUSCAR)
      return { paso: 'compra_buscar' }
    }

    if (boton === 'compra:cambiar_envio' || ['cambiar envio', 'cambiar', 'otro envio'].includes(n)) {
      return mostrarDetalleYEnvio(producto, tarifas, datos.cantidad ?? 1)
    }

    if (boton === 'compra:confirmar' || ['confirmar', 'confirmar compra', 'si'].includes(n)) {
      const cot = datos.cotizacion ?? calcularCotizacion(producto, tarifas, metodo, datos.cantidad ?? 1)
      const r = await probar<Record<string, unknown>>('bot_compra_crear', {
        p_phone: tel,
        p_asin: producto.asin,
        p_product_title: producto.titulo,
        p_product_url: producto.url,
        p_image_url: producto.imagenUrl,
        p_variant_label: datos.variante ?? null,
        p_quantity: cot.quantity,
        p_category: producto.categoria,
        p_weight_lb: cot.weightEstimated ? null : cot.weightLb,
        p_volumetric_weight_lb: cot.volumetricWeightLb > 0 ? cot.volumetricWeightLb : null,
        p_volume_ft3: cot.volumeFt3 > 0 ? cot.volumeFt3 : null,
        p_weight_estimated: cot.weightEstimated,
        p_restricted_flag: cot.restriccion.restringido,
        p_restricted_reason: cot.restriccion.motivo,
        p_shipping_method: cot.shippingMethod,
        p_unit_price_usd: cot.unitPriceUsd,
        p_channel: 'whatsapp',
      })

      if (!r.ok) {
        await enviar(`No pudimos crear la solicitud: ${r.mensaje}`, BOTONES_CONFIRMAR)
        return { paso: 'compra_confirmar', error: r.mensaje }
      }

      const c = r.data ?? {}
      const reqId = String(c.request_id ?? c.id ?? '')
      const num = formatoNumeroCompra(c.request_number ?? c.code ?? reqId)
      const restringido =
        c.restricted_flag === true ||
        c.status === 'revision_aduanal' ||
        (c.restricted_flag == null && cot.restriccion.restringido)

      if (restringido) {
        const motivo = String(
          c.restricted_reason ?? c.restriction_reason ?? cot.restriccion.motivo ?? 'Validación aduanal y sanitaria requerida.',
        )
        await guardar('compra_buscar', {})
        await enviar(
          `Solicitud ${num} registrada en *revisión aduanal*.\n\n` +
            `*${truncar(producto.titulo, 95)}*\n` +
            `Motivo: ${motivo}\n\n` +
            'El equipo de Helios validará los requisitos de aduana y te avisaremos por aquí en cuanto quede aprobada para que puedas realizar el pago.',
          BOTONES_DESPUES_ACCION,
        )
        return { paso: 'compra_revision_aduanal', purchase_id: reqId || null, numero: num }
      }

      const totalUsd = numeroPositivo(c.total_usd) ?? cot.totalUsd
      const totalVes = numeroPositivo(c.quoted_ves ?? c.total_ves) ?? cot.totalVes
      const bloquePago = String(c.payment_block ?? tarifas.accountsBlock ?? '').trim()

      await guardar('compra_pago', {
        compraId: reqId,
        compraNumero: num,
        compraTotalUsd: totalUsd,
        compraTotalVes: totalVes,
        producto,
        tarifas,
        envio: metodo,
        cotizacion: cot,
        datosPago: {},
        intentosDatosPago: 0,
      })

      const encabezado = `Solicitud ${num} creada · *${dinero(totalUsd)}* (${bolivares(totalVes)} a tasa BCV de hoy).`
      const cierre =
        'Cuando realices el pago, envíame por aquí la foto o PDF del comprobante, o pulsa «Escribir datos» para pasarme los datos de tu Pago Móvil.'
      const completo = bloquePago ? `${encabezado}\n\n${bloquePago}\n\n${cierre}` : `${encabezado}\n\n${cierre}`

      if (completo.length <= 1024) {
        await enviar(completo, BOTONES_PAGO)
      } else {
        await enviar(bloquePago ? `${encabezado}\n\n${bloquePago}` : encabezado)
        await enviar(cierre, BOTONES_PAGO)
      }

      return { paso: 'compra_pago', purchase_id: reqId || null, numero: num }
    }

    await enviar('Usa los botones: Confirmar compra, Cambiar envío o Cancelar.', BOTONES_CONFIRMAR)
    return { paso: 'compra_confirmar' }
  }

  // ── 9. Estado: compra_pago ────────────────────────────────────────────
  if (estado === 'compra_pago') {
    if (!datos.compraId) {
      return volverAlMenu('No tengo una compra pendiente de pago en esta sesión. ¿Qué quieres hacer?')
    }

    if (mensaje.adjunto) {
      return reportarPagoPorAdjunto()
    }

    if (boton === 'compra:datos_pago' || quiereEscribirLosDatos(texto)) {
      await guardar('compra_pago_datos', {
        ...datos,
        datosPago: {},
        intentosDatosPago: 0,
      })
      await enviar(
        'Perfecto. Envíame los datos de tu Pago Móvil en un solo mensaje (banco, teléfono de 11 dígitos y referencia completa de 8 a 20 dígitos). ' +
          'Puedes copiar esta plantilla o escribirlos uno por línea:\n\n' +
          formularioDePago(),
      )
      return { paso: 'compra_pago_datos' }
    }

    if (boton === 'compra:ya_pague' || ['ya pague', 'pague', 'listo ya pague'].includes(n)) {
      await enviar(
        'Envíame ahora la foto o el PDF de tu comprobante de pago por aquí.\n\n' +
          'Si no tienes captura, pulsa «Escribir datos» o escribe «datos» para pasarme tu banco, teléfono y referencia.',
        [
          { id: 'compra:datos_pago', title: 'Escribir datos' },
          { id: 'compra:mis', title: 'Mis compras' },
          { id: 'orden:cancelar', title: 'Volver al menú' },
        ],
      )
      return { paso: 'compra_pago', recordatorio: true }
    }

    // Si el médico escribió directamente sus datos de Pago Móvil sin tocar «datos», los aceptamos.
    if (texto) {
      const intento = leerDatosDePago(texto)
      const reconocidos = [intento.banco, intento.telefono, intento.referencia].filter(Boolean).length
      if (reconocidos >= 2) {
        return procesarDatosDePago(texto)
      }
    }

    await enviar(
      `Tu compra ${datos.compraNumero ?? ''} espera tu comprobante de pago. Envíame la foto o PDF del comprobante, o pulsa «Escribir datos» para pasarme los datos de tu Pago Móvil.`,
      BOTONES_PAGO,
    )
    return { paso: 'compra_pago' }
  }

  // ── 10. Estado: compra_pago_datos ─────────────────────────────────────
  if (estado === 'compra_pago_datos') {
    if (!datos.compraId) {
      return volverAlMenu('No tengo una compra pendiente de pago en esta sesión. ¿Qué quieres hacer?')
    }

    if (mensaje.adjunto) {
      return reportarPagoPorAdjunto()
    }

    if (!texto) {
      await enviar(`Envíame los datos de tu Pago Móvil:\n\n${formularioDePago()}`)
      return { paso: 'compra_pago_datos' }
    }

    return procesarDatosDePago(texto)
  }

  return volverAlMenu()
}
