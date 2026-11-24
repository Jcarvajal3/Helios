// ═══════════════════════════════════════════════════════════════════════════
// Helios — Flujo conversacional de Compras en Amazon para médicos
//
// El mismo código habla por WhatsApp (bot.ts) y en el simulador del
// superadmin (compras-simulador): solo cambia el `TransporteCompras`.
//
// Estados (se guardan en la sesión, 30 min):
//   compra_buscar     texto, enlace o ASIN
//   compra_resultados carrusel (o lista numerada) de 2–4 opciones
//   compra_envio      detalle + aéreo vs. marítimo
//   compra_cantidad   «¿Cuántas unidades?»
//   compra_confirmar  desglose + confirmación (`bot_compra_crear`)
//   compra_pago       comprobante (foto/PDF) o «datos» (`bot_compra_reportar_pago`)
//   compra_pago_datos Pago Móvil escrito (datos_pago.ts)
//   compra_cancelar   «¿Cancelo la solicitud?» (`bot_compra_cancelar`)
//   compra_mis        lista «Mis compras»
//   compra_detalle    una solicitud (`bot_compra_detalle`)
//
// Reglas (CLAUDE.md): español de Venezuela, dinero con `dinero`, bolívares
// SOLO en el bloque de pago que arma la base, ≤ 1 emoji por mensaje, jamás
// préstamo, financiamiento, financiar, crédito ni fee.
//
// Un botón `compra:*` solo vale en su estado; uno viejo no ejecuta nada: se
// avisa y se repite el paso actual. El pago nunca se pierde: si llega un
// comprobante (o «ya pagué») fuera del estado de pago, se recupera la
// solicitud abierta con `bot_compra_pendiente_de_pago`.
// ═══════════════════════════════════════════════════════════════════════════

import { dinero, montoEs } from '../datos.ts'
import {
  faltanDatosDePago,
  formularioDePago,
  juntarDatosDePago,
  leerDatosDePago,
  nombrarCampos,
  quiereEscribirLosDatos,
} from '../datos_pago.ts'
import type { DatosDePago } from '../datos_pago.ts'
import { esCortesia, normalizar } from '../logica.ts'
import type { EventoDeMensaje } from '../logica.ts'
import { contieneEnlace, analizarEnlaceAmazon, extraerAsinDeTexto } from './amazon_parser.ts'
import { ErrorCatalogo, numeroPositivo as positivo } from './catalogo_rainforest.ts'
import { CANTIDAD_MAXIMA, calcularCotizacion, recomendarEnvio } from './cotizador.ts'
import { resolverEnlaceCorto } from './enlaces.ts'
import type { ResolverEnlace } from './enlaces.ts'
import {
  B_BUSCAR,
  B_CANCELAR_COMPRA,
  B_MENU,
  B_MIS,
  B_PERSONA,
  BOTONES_BUSCAR,
  BOTONES_CANCELAR,
  BOTONES_CONFIRMAR,
  BOTONES_DESPUES_ACCION,
  BOTONES_ENVIO,
  BOTONES_ERROR_CATALOGO,
  BOTONES_PAGO,
  BOTONES_VENCIDA,
  ETA_ENVIO,
  MSG_AVISO_TIENDA,
  MSG_ENLACE_CORTO,
  MSG_NO_COMPLETADO,
  MSG_NO_DISPONIBLE,
  MSG_SIN_TASA,
  NO_REGISTRO_NADA,
  SUGERENCIA_PERSONA,
  etiquetaEstado,
  fechaCorta,
  fechaHora,
  formatoNumeroCompra,
  mensajeAmigableDeError,
  nombreEnvio,
  truncar,
} from './textos.ts'
import type { BotonCompra, SesionCompra, TransporteCompras } from './transporte.ts'
import type {
  CotizacionCompra,
  DatosCompra,
  EstadoCompra,
  FilaLista,
  MetodoEnvio,
  ProductoDetalle,
  ProductoResumen,
  ProveedorCatalogo,
  TarifasCompra,
  TarjetaCarrusel,
} from './tipos.ts'

export type { BotonCompra } from './transporte.ts'

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
  /** Una persona del equipo atiende este chat: el bot no contesta lo que no entiende. */
  humano?: boolean
  sesion: SesionCompra
  transporte: TransporteCompras
  volverAlMenu: (saludo?: string) => Promise<unknown>
  /** El catálogo de ese proveedor, o null si no se puede armar (sin clave). */
  proveedorDe: (nombre: string) => ProveedorCatalogo | null
  resolverEnlace?: ResolverEnlace
  ahora?: () => Date
}

export const ESTADOS_COMPRA: readonly EstadoCompra[] = [
  'compra_buscar',
  'compra_resultados',
  'compra_envio',
  'compra_cantidad',
  'compra_confirmar',
  'compra_pago',
  'compra_pago_datos',
  'compra_cancelar',
  'compra_mis',
  'compra_detalle',
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
  'cancelar compra',
  'persona',
  'asesor',
  'hablar con alguien',
])

/** Detecta si el mensaje o botón dispara directamente el flujo de compras. */
export function esAtajoDeCompra(texto: string, boton: string): boolean {
  if (boton === 'menu:comprar' || boton.startsWith('compra:')) return true
  if (ATAJOS_TEXTO_COMPRA.has(normalizar(texto))) return true
  return extraerAsinDeTexto(texto) !== null || analizarEnlaceAmazon(texto) !== null
}

const TEXTOS_PAGO = new Set(['datos', 'ya pague', 'pague', 'listo ya pague', 'ya hice el pago'])

/** ¿El mensaje trae un pago (comprobante, «ya pagué», «datos»)? Se recupera aunque no estemos en `compra_pago`. */
export function esIntentoDePago(m: { texto: string | null; boton: string | null; adjunto: unknown }): boolean {
  if (m.adjunto) return true
  const boton = m.boton ?? ''
  if (boton === 'compra:ya_pague' || boton === 'compra:datos_pago') return true
  const n = normalizar(m.texto ?? '')
  return TEXTOS_PAGO.has(n) || quiereEscribirLosDatos(m.texto ?? '')
}

const ERRORES_DE_NEGOCIO = new Set(['P0001', '22023', 'P0002', '42501', '28000', '55000'])
const PALABRAS_DE_MENU = new Set(['menu', 'cancelar', 'inicio', 'salir', 'hola', 'buenas', 'buenos dias', 'buenas tardes', 'empezar', 'volver al menu'])
const PALABRAS_PERSONA = new Set(['persona', 'asesor', 'hablar con alguien', 'hablar con una persona', 'agente'])
const PALABRAS_CANCELAR_COMPRA = new Set(['cancelar compra', 'cancelar solicitud', 'cancelar pedido'])

const MIN_BUSQUEDA = 3
const MAX_BUSQUEDA = 80
const MAX_CANTIDAD_CHAT = 10
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** Qué estados admiten cada botón `compra:*` (los de navegación valen siempre). */
const BOTON_POR_ESTADO: ReadonlyArray<[RegExp, readonly string[]]> = [
  [/^compra:v:/, ['compra_resultados']],
  [/^compra:envio:/, ['compra_envio']],
  [/^compra:cantidad$/, ['compra_confirmar']],
  [/^compra:cambiar_envio$/, ['compra_confirmar']],
  [/^compra:confirmar$/, ['compra_confirmar']],
  [/^compra:recotizar$/, ['compra_pago', 'compra_pago_datos', 'compra_detalle']],
  [/^compra:cancelar_pedir$/, ['compra_pago', 'compra_pago_datos', 'compra_detalle']],
  [/^compra:cancelar_(si|no)$/, ['compra_cancelar']],
  [/^compra:pagar$/, ['compra_detalle']],
]
const BOTONES_DE_NAVEGACION = /^(compra:(mis|buscar|persona|menu|det:|reenviar:|ya_pague$|datos_pago$))/

// ── El servicio del turno ───────────────────────────────────────────────

type Prob<T> = { ok: true; data: T } | { ok: false; mensaje: string; vencida: boolean }

type S = {
  ctx: ContextoCompra
  tel: string
  estado: string
  datos: DatosCompra
  texto: string
  boton: string
  n: string
  mensaje: EventoDeMensaje
}

type Config = { tarifas: TarifasCompra; proveedorNombre: string }

function crearS(ctx: ContextoCompra): S {
  const texto = (ctx.mensaje.texto ?? '').trim()
  return {
    ctx,
    tel: ctx.personal.phone_e164,
    estado: ctx.sesion.state,
    datos: (ctx.sesion.data ?? {}) as DatosCompra,
    texto,
    boton: (ctx.mensaje.boton ?? '').trim(),
    n: normalizar(texto),
    mensaje: ctx.mensaje,
  }
}

const enviar = (s: S, texto: string, botones: BotonCompra[] = []) => s.ctx.transporte.enviar(texto, botones)

/** Guarda el paso; las entradas inválidas seguidas se reinician. */
function guardar(s: S, estado: EstadoCompra, datos: DatosCompra = {}) {
  s.estado = estado
  s.datos = { ...datos, invalidos: undefined }
  return s.ctx.transporte.guardarSesion(estado, s.datos as Record<string, unknown>)
}

function ahora(s: S): Date {
  return s.ctx.ahora ? s.ctx.ahora() : new Date()
}

/** Una RPC cuyo error de negocio se le enseña al médico (el texto lo escribe la base). */
async function probar<T>(s: S, fn: string, args: Record<string, unknown>): Promise<Prob<T>> {
  try {
    return { ok: true, data: await s.ctx.rpc<T>(fn, args) }
  } catch (err) {
    const m = err instanceof Error ? err.message : String(err)
    const code = (err as { code?: unknown } | null)?.code
    const vencida = /cotizacion_vencida/.test(m)
    if (typeof code === 'string' && ERRORES_DE_NEGOCIO.has(code)) {
      const amigable = mensajeAmigableDeError(m)
      if (amigable) return { ok: false, mensaje: amigable, vencida }
      if (vencida) return { ok: false, mensaje: MSG_NO_COMPLETADO, vencida }
    }
    // Nunca se le enseña al médico el texto crudo de la base: queda en el log.
    console.error('compras', fn, code, m)
    return { ok: false, mensaje: MSG_NO_COMPLETADO, vencida: false }
  }
}

function esVencida(s: S): boolean {
  const d = s.datos
  if (d.compraVencida === true) return true
  if (!d.compraVenceEn) return false
  const t = Date.parse(d.compraVenceEn)
  return Number.isFinite(t) && t <= ahora(s).getTime()
}

// ── Configuración y catálogo ────────────────────────────────────────────

function noNegativo(v: unknown): number | null {
  const n = Number(v)
  return v != null && Number.isFinite(n) && n >= 0 ? n : null
}

/** Las tarifas de la base, o null si falta CUALQUIER dato (jamás se inventa una tarifa ni la tasa). */
export function normalizarTarifas(raw: Record<string, unknown> | null | undefined): TarifasCompra | null {
  if (!raw) return null
  const taxUsaPct = noNegativo(raw.tax_usa_pct)
  const serviceFeePct = noNegativo(raw.service_fee_pct)
  const airRatePerLbUsd = positivo(raw.air_rate_per_lb_usd)
  const airMinUsd = positivo(raw.air_min_usd)
  const seaRatePerFt3Usd = positivo(raw.sea_rate_per_ft3_usd)
  const seaMinUsd = positivo(raw.sea_min_usd)
  const fallbackWeightLb = positivo(raw.fallback_weight_lb)
  const fxRateUsd = positivo(raw.fx_rate_usd)
  if (
    taxUsaPct == null ||
    serviceFeePct == null ||
    airRatePerLbUsd == null ||
    airMinUsd == null ||
    seaRatePerFt3Usd == null ||
    seaMinUsd == null ||
    fallbackWeightLb == null ||
    fxRateUsd == null
  ) {
    return null
  }
  return {
    taxUsaPct,
    serviceFeePct,
    airRatePerLbUsd,
    airMinUsd,
    seaRatePerFt3Usd,
    seaMinUsd,
    fallbackWeightLb,
    fxRateUsd,
    accountsBlock: String(raw.accounts_block ?? '').trim(),
    quoteTtlHours: positivo(raw.quote_ttl_hours),
  }
}

/** La configuración vigente (se pide a la base en cada paso que cotiza). Si no hay, avisa y devuelve null. */
async function cargarConfig(s: S): Promise<Config | null> {
  let raw: Record<string, unknown> | null = null
  try {
    raw = await s.ctx.rpc<Record<string, unknown> | null>('bot_compra_config', {})
  } catch (err) {
    console.error('compras: no se pudo leer la configuración', (err as { code?: unknown } | null)?.code)
  }
  const tarifas = normalizarTarifas(raw)
  if (!tarifas) {
    await enviar(s, MSG_SIN_TASA, BOTONES_ERROR_CATALOGO)
    return null
  }
  return { tarifas, proveedorNombre: String(raw?.catalog_provider ?? '').trim().toLowerCase() }
}

/** Configuración + catálogo del proveedor que fija la base. Sin catálogo (clave que falta), jamás cae a mock. */
async function prepararCatalogo(s: S): Promise<{ tarifas: TarifasCompra; proveedor: ProveedorCatalogo } | null> {
  const cfg = await cargarConfig(s)
  if (!cfg) return null
  const proveedor = s.ctx.proveedorDe(cfg.proveedorNombre)
  if (!proveedor) {
    console.error('compras: proveedor de catálogo no disponible', cfg.proveedorNombre)
    await enviar(s, MSG_NO_DISPONIBLE, BOTONES_ERROR_CATALOGO)
    return null
  }
  return { tarifas: cfg.tarifas, proveedor }
}

/** Corre algo contra el catálogo; si falla, le explica al médico sin filtrar nada. */
async function conCatalogo<T>(s: S, tarea: () => Promise<T>): Promise<{ ok: true; valor: T } | { ok: false }> {
  try {
    return { ok: true, valor: await tarea() }
  } catch (err) {
    const tipo = err instanceof ErrorCatalogo ? err.tipo : 'desconocido'
    console.error('compras: catálogo', tipo, err instanceof ErrorCatalogo ? err.estado ?? '' : '')
    await enviar(
      s,
      tipo === 'limite'
        ? 'Amazon recibe muchas consultas en este momento. Inténtalo de nuevo en un minuto o toca «Hablar con alguien».'
        : 'Amazon no me responde en este momento. Inténtalo de nuevo en unos minutos o toca «Hablar con alguien».',
      BOTONES_ERROR_CATALOGO,
    )
    return { ok: false }
  }
}

async function cacheGet<T>(s: S, clave: string): Promise<T | null> {
  try {
    const res = await s.ctx.rpc<unknown>('bot_compra_cache_get', { p_key: clave })
    if (!res) return null
    if (typeof res === 'object' && res !== null && 'payload' in (res as Record<string, unknown>)) {
      return (res as { payload?: T | null }).payload ?? null
    }
    return res as T
  } catch {
    return null
  }
}

async function cacheSet(s: S, proveedor: ProveedorCatalogo, clave: string, kind: 'search' | 'product', payload: unknown, ttl: number) {
  try {
    await s.ctx.rpc('bot_compra_cache_set', {
      p_key: clave,
      p_kind: kind,
      p_provider: proveedor.nombre,
      p_payload: payload,
      p_ttl_minutes: ttl,
    })
  } catch {
    // El fallo de caché nunca debe interrumpir al médico.
  }
}

function claveDeBusqueda(proveedor: ProveedorCatalogo, consulta: string): string {
  return `search:${proveedor.nombre}:${normalizar(consulta).slice(0, 80)}`
}

async function buscarCatalogo(s: S, proveedor: ProveedorCatalogo, consulta: string, limite = 4): Promise<ProductoResumen[]> {
  const clave = claveDeBusqueda(proveedor, consulta)
  const enCache = await cacheGet<ProductoResumen[]>(s, clave)
  if (Array.isArray(enCache) && enCache.length > 0) return enCache.slice(0, limite)
  const resultados = await proveedor.buscar(consulta, limite)
  if (resultados.length > 0) await cacheSet(s, proveedor, clave, 'search', resultados, 45)
  return resultados
}

function detalleDesdeResumen(r: ProductoResumen): ProductoDetalle {
  return { ...r, variantes: [], disponible: true, descripcionCorta: '' }
}

async function detalleCatalogo(s: S, proveedor: ProveedorCatalogo, asin: string, respaldo?: ProductoResumen | null): Promise<ProductoDetalle | null> {
  const limpio = asin.trim().toUpperCase()
  const clave = `product:${proveedor.nombre}:${limpio}`
  const enCache = await cacheGet<ProductoDetalle>(s, clave)
  if (enCache && typeof enCache === 'object' && typeof enCache.asin === 'string') return enCache
  const detalle = await proveedor.detalle(limpio)
  if (detalle) {
    if (detalle.disponible) await cacheSet(s, proveedor, clave, 'product', detalle, 120)
    return detalle
  }
  return respaldo ? detalleDesdeResumen(respaldo) : null
}

// ── Salidas ─────────────────────────────────────────────────────────────

/** Entrada inválida: se repite el paso; a la segunda seguida se ofrece una persona. Callada si no hace falta. */
async function invalida(s: S, texto: string, botones: BotonCompra[] = []) {
  if (s.ctx.humano || esCortesia(s.mensaje)) return null
  const n = (s.datos.invalidos ?? 0) + 1
  s.datos = { ...s.datos, invalidos: n }
  await s.ctx.transporte.guardarSesion(s.estado as EstadoCompra, s.datos as Record<string, unknown>)
  await enviar(s, n >= 2 ? `${texto}\n\n${SUGERENCIA_PERSONA}` : texto, botones)
  return { paso: s.estado, invalida: n }
}

/** «Hasta el jue 26/11 16:30», o '' si no se sabe. */
function hastaCuando(iso: string | null | undefined): string {
  const f = fechaHora(iso)
  return f ? ` hasta el ${f}` : ''
}

function numeroDe(s: S): string {
  return s.datos.compraNumero ?? ''
}

// ── Búsqueda ────────────────────────────────────────────────────────────

const PROMPT_BUSCAR =
  '¿Qué quieres comprar en Amazon? Escribe el nombre del producto o pega el enlace de Amazon.\n\nPor ejemplo: «estetoscopio Littmann» o «oxímetro».'

async function iniciarBusqueda(s: S) {
  await guardar(s, 'compra_buscar', {})
  await enviar(s, PROMPT_BUSCAR, BOTONES_BUSCAR)
  return { paso: 'compra_buscar' }
}

function estimadoEnVenezuela(p: ProductoResumen, tarifas: TarifasCompra): number {
  return calcularCotizacion(p, tarifas, recomendarEnvio(p), 1).totalUsd
}

function tarjetaDe(p: ProductoResumen, i: number, tarifas: TarifasCompra): TarjetaCarrusel {
  const resto = `\nAmazon: ${dinero(p.precioUsd)}\nPuesto en Venezuela aprox.: ${dinero(estimadoEnVenezuela(p, tarifas))}`
  const cabeza = `${i + 1}. `
  const titulo = truncar(p.titulo, Math.max(20, 158 - resto.length - cabeza.length))
  return {
    image_url: p.imagenUrl,
    body: `${cabeza}${titulo}${resto}`,
    // ≤ 20 caracteres: el límite del id de botón de una tarjeta.
    button_id: `compra:v:${p.asin}`,
    button_title: 'Cotizar',
  }
}

async function mostrarResultados(s: S, consulta: string, resultados: ProductoResumen[], tarifas: TarifasCompra) {
  await guardar(s, 'compra_resultados', { consulta, resultados })
  const n = resultados.length
  const encabezado = `Encontré ${n} opciones para «${truncar(consulta, 50)}». Elige una para cotizarla. Si no es lo que buscas, escribe otra búsqueda.`
  const conFoto = n >= 2 && resultados.every((p) => p.imagenUrl.startsWith('https://'))
  // Sin carrusel (sin fotos, o si Meta/la RPC lo rechaza): lista en el simulador, texto numerado en WhatsApp.
  const sinCarrusel = async () => {
    if (s.ctx.transporte.canal === 'simulador') {
      const filas: FilaLista[] = resultados.map((p, i) => ({
        id: `compra:v:${p.asin}`,
        title: `${i + 1}. ${p.titulo}`,
        description: `Amazon ${dinero(p.precioUsd)} · Venezuela aprox. ${dinero(estimadoEnVenezuela(p, tarifas))}`,
      }))
      await s.ctx.transporte.enviarLista(encabezado, 'Ver opciones', filas)
    } else {
      const lineas = resultados.map(
        (p, i) =>
          `${i + 1}. ${truncar(p.titulo, 90)}\n   Amazon: ${dinero(p.precioUsd)} · Puesto en Venezuela aprox.: ${dinero(estimadoEnVenezuela(p, tarifas))}`,
      )
      await enviar(s, `${encabezado}\n\n${lineas.join('\n')}\n\nResponde con el número de la opción.`)
    }
  }
  if (conFoto) {
    // La sesión ya está guardada: si el carrusel falla (p. ej. 22023) NO se deja caer el turno
    // (el webhook reintentaría y repetiría la búsqueda de pago); se registra solo el código.
    try {
      await s.ctx.transporte.enviarCarrusel(encabezado, resultados.map((p, i) => tarjetaDe(p, i, tarifas)))
    } catch (err) {
      console.error('compras: el carrusel falló; los resultados salen sin tarjetas', (err as { code?: unknown } | null)?.code)
      await sinCarrusel()
    }
  } else {
    await sinCarrusel()
  }
  return { paso: 'compra_resultados', cuantos: n }
}

/** Valida lo que se escribió para buscar: 3–80 caracteres, sin cortesías ni fotos. */
function consultaValida(s: S): string | null {
  const q = s.texto.replace(/\s+/g, ' ').trim()
  if (q.length < MIN_BUSQUEDA || q.length > MAX_BUSQUEDA) return null
  return q
}

async function ejecutarBusqueda(s: S, entrada: string) {
  const enlace = analizarEnlaceAmazon(entrada)
  let asin: string | null = null
  let aviso = ''

  if (enlace) {
    let encontrado = enlace.asin
    if (!encontrado && enlace.corto) {
      const resolver = s.ctx.resolverEnlace ?? ((u: string) => resolverEnlaceCorto(u))
      const larga = await resolver(enlace.url)
      encontrado = larga ? extraerAsinDeTexto(larga) : null
      if (!encontrado) {
        await guardar(s, 'compra_buscar', {})
        await enviar(s, MSG_ENLACE_CORTO, BOTONES_BUSCAR)
        return { paso: 'compra_buscar', enlace_corto: false }
      }
    }
    if (!encontrado) {
      await guardar(s, 'compra_buscar', {})
      await enviar(s, 'No encontré el producto en ese enlace de Amazon. Ábrelo y copia el enlace largo, o escríbeme el nombre.', BOTONES_BUSCAR)
      return { paso: 'compra_buscar', encontrado: false }
    }
    asin = encontrado
    if (!enlace.esAmazonCom) aviso = `${MSG_AVISO_TIENDA}\n\n`
  } else if (contieneEnlace(entrada)) {
    // Un enlace que no es de Amazon jamás se busca como texto.
    await enviar(s, 'Ese enlace no es de Amazon. Pega un enlace de amazon.com o escríbeme el nombre del producto.', BOTONES_BUSCAR)
    return { paso: 'compra_buscar', enlace: 'otro_sitio' }
  } else {
    asin = extraerAsinDeTexto(entrada)
  }

  const listo = await prepararCatalogo(s)
  if (!listo) return { paso: s.estado, error: 'sin_catalogo' }
  const { tarifas, proveedor } = listo

  if (asin) {
    const det = await conCatalogo(s, () => detalleCatalogo(s, proveedor, asin as string))
    if (!det.ok) return { paso: s.estado, error: 'catalogo' }
    if (det.valor) return mostrarDetalleYEnvio(s, det.valor, tarifas, 1, aviso)
    await guardar(s, 'compra_buscar', {})
    await enviar(
      s,
      `${aviso}No pude cargar el producto con código ${asin} en Amazon. Verifica el enlace o escribe el nombre del artículo para buscarlo.`,
      BOTONES_BUSCAR,
    )
    return { paso: 'compra_buscar', encontrado: false, asin }
  }

  const consulta = entrada.replace(/\s+/g, ' ').trim()
  const encontrados = await conCatalogo(s, () => buscarCatalogo(s, proveedor, consulta, 4))
  if (!encontrados.ok) return { paso: s.estado, error: 'catalogo' }
  const resultados = encontrados.valor
  if (resultados.length === 0) {
    await guardar(s, 'compra_buscar', { consulta })
    await enviar(
      s,
      `No encontré resultados en Amazon para «${truncar(consulta, 60)}». Prueba con otro término (por ejemplo: «estetoscopio», «tensiómetro», «autoclave») o pega el enlace directo de Amazon.`,
      BOTONES_BUSCAR,
    )
    return { paso: 'compra_buscar', cuantos: 0 }
  }
  if (resultados.length === 1) {
    const det = await conCatalogo(s, () => detalleCatalogo(s, proveedor, resultados[0].asin, resultados[0]))
    if (!det.ok) return { paso: s.estado, error: 'catalogo' }
    if (det.valor) return mostrarDetalleYEnvio(s, det.valor, tarifas, 1, `Encontré 1 opción para «${truncar(consulta, 50)}».\n\n`)
  }
  return mostrarResultados(s, consulta, resultados, tarifas)
}

// ── Detalle, envío y cantidad ───────────────────────────────────────────

function leerCantidad(n: string, estricta: boolean): number | null {
  let m = /^x\s*(\d{1,3})$/.exec(n) ?? /^(\d{1,3})\s*x$/.exec(n) ?? /^(\d{1,3})\s*(?:unidades?|uds?|piezas?)$/.exec(n)
  if (!m && !estricta) m = /^(\d{1,3})$/.exec(n)
  return m ? Number(m[1]) : null
}

async function mostrarDetalleYEnvio(s: S, producto: ProductoDetalle, tarifas: TarifasCompra, cantidad = 1, prefijo = '') {
  if (!producto.disponible || producto.precioUsd <= 0) {
    await guardar(s, 'compra_buscar', {})
    await enviar(
      s,
      `${prefijo}El producto *${truncar(producto.titulo, 90)}* no está disponible en Amazon en este momento. Prueba con otra búsqueda o pega otro enlace.`,
      BOTONES_BUSCAR,
    )
    return { paso: 'compra_no_disponible', asin: producto.asin }
  }

  const cotAereo = calcularCotizacion(producto, tarifas, 'aereo', cantidad)
  const cotMaritimo = calcularCotizacion(producto, tarifas, 'maritimo', cantidad)
  const recomendado = recomendarEnvio(producto)
  const ahorro = Math.round((cotAereo.totalUsd - cotMaritimo.totalUsd) * 100) / 100

  const dims = producto.dimensionesIn
  const lineaPeso = cotAereo.weightEstimated
    ? `Amazon no publica el peso; calculo con ${montoEs(tarifas.fallbackWeightLb)} lb y, si pesa más al llegar al almacén, te aviso antes de cobrar la diferencia.`
    : `Peso: ${montoEs(cotAereo.weightLb)} lb${dims ? ` · ${montoEs(dims.largo)}×${montoEs(dims.ancho)}×${montoEs(dims.alto)} in` : ''}`
  const aviso = cotAereo.restriccion.restringido
    ? '\nEste producto necesita una revisión aduanal (aprox. 1 día hábil) antes de poder pagarlo.'
    : ''
  const lineaCantidad = cantidad > 1 ? `Cantidad: ${cotAereo.quantity}\n` : ''
  const recomendacion =
    recomendado === 'maritimo' && ahorro > 0
      ? `\nTe recomiendo marítimo: ahorras ${dinero(ahorro)} si no tienes prisa.`
      : ''

  const cuerpo =
    `${prefijo}*${truncar(producto.titulo, 110)}*\n` +
    `Precio en Amazon: ${dinero(producto.precioUsd)}\n${lineaCantidad}` +
    `${lineaPeso}${aviso}\n\n` +
    'Elige cómo traerlo (todo incluido):\n' +
    `• *Aéreo* · ${dinero(cotAereo.totalUsd)} · llega en ${ETA_ENVIO.aereo}\n` +
    `• *Marítimo* · ${dinero(cotMaritimo.totalUsd)} · llega en ${ETA_ENVIO.maritimo}` +
    `${recomendacion}\n\n` +
    'Todo incluido = producto + impuesto EE. UU. + envío + gestión Helios.' +
    (cantidad === 1 ? '\nPara otra cantidad escribe, por ejemplo, «x3».' : '')

  await guardar(s, 'compra_envio', { producto, cantidad, envio: null, cotizacion: null })
  await enviar(s, cuerpo, BOTONES_ENVIO)
  return { paso: 'compra_envio', asin: producto.asin, recomendado, restringido: cotAereo.restriccion.restringido }
}

/** La fecha de validez de una cotización que se confirma ahora (ISO), o null sin TTL. */
function validaHasta(s: S, tarifas: TarifasCompra): string | null {
  if (!tarifas.quoteTtlHours) return null
  return new Date(ahora(s).getTime() + tarifas.quoteTtlHours * 3600_000).toISOString()
}

async function mostrarConfirmacion(s: S, producto: ProductoDetalle, tarifas: TarifasCompra, metodo: MetodoEnvio, cantidad: number, prefijo = '') {
  const cot: CotizacionCompra = calcularCotizacion(producto, tarifas, metodo, cantidad)
  const restringido = cot.restriccion.restringido
  const hasta = fechaHora(validaHasta(s, tarifas))

  const cuerpo =
    `${prefijo}Revisa tu cotización:\n\n` +
    `*${truncar(producto.titulo, 100)}*\n` +
    `Cantidad: ${cot.quantity} · Envío ${nombreEnvio(metodo).toLowerCase()}\n\n` +
    `• Producto · ${dinero(cot.subtotalUsd)}\n` +
    `• Impuesto EE. UU. · ${dinero(cot.taxUsaUsd)}\n` +
    `• Envío ${nombreEnvio(metodo).toLowerCase()} · ${dinero(cot.shippingUsd)}\n` +
    `• Gestión Helios · ${dinero(cot.serviceFeeUsd)}\n` +
    `*Total: ${dinero(cot.totalUsd)}*\n` +
    `Llega en ${ETA_ENVIO[metodo]} aprox.` +
    (hasta ? `\nPrecio válido hasta ${hasta}.` : '') +
    (cot.weightEstimated ? `\nPeso estimado (${montoEs(cot.weightLb)} lb): si cambia en el almacén, te aviso antes de cobrar la diferencia.` : '') +
    (restringido ? '\nEste producto pasa primero por revisión aduanal (aprox. 1 día hábil); después te aviso para que pagues.' : '') +
    '\nPara cancelar escribe «cancelar».'

  await guardar(s, 'compra_confirmar', { producto, envio: metodo, cantidad: cot.quantity, cotizacion: cot })
  await enviar(s, cuerpo, [
    { id: 'compra:confirmar', title: restringido ? 'Pedir revisión' : 'Confirmar compra' },
    { id: 'compra:cambiar_envio', title: 'Cambiar envío' },
    { id: 'compra:cantidad', title: 'Cambiar cantidad' },
  ])
  return { paso: 'compra_confirmar', envio: metodo, totalUsd: cot.totalUsd }
}

async function preguntarCantidad(s: S) {
  await guardar(s, 'compra_cantidad', { ...s.datos })
  await enviar(s, `¿Cuántas unidades? Escribe un número del 1 al ${MAX_CANTIDAD_CHAT}.`)
  return { paso: 'compra_cantidad' }
}

/** Aplica una cantidad pedida («x3») y repite el paso en el que estábamos. */
async function aplicarCantidad(s: S, cantidad: number) {
  const producto = s.datos.producto
  if (!producto) return iniciarBusqueda(s)
  // Solo los botones que valen en el estado actual (si no, el primer toque diría «ya no está activa»).
  const botonesDelPaso = s.estado === 'compra_envio' ? BOTONES_ENVIO : s.estado === 'compra_confirmar' ? BOTONES_CONFIRMAR : []
  if (cantidad < 1) return invalida(s, `Escribe un número del 1 al ${MAX_CANTIDAD_CHAT}.`, botonesDelPaso)
  if (cantidad > MAX_CANTIDAD_CHAT || cantidad > CANTIDAD_MAXIMA) {
    return invalida(s, `Para ${cantidad} unidades escribe «persona» y te ayudamos. Desde aquí puedo cotizar de 1 a ${MAX_CANTIDAD_CHAT}.`, botonesDelPaso)
  }
  const cfg = await cargarConfig(s)
  if (!cfg) return { paso: s.estado, error: 'sin_config' }
  if (s.datos.envio) return mostrarConfirmacion(s, producto, cfg.tarifas, s.datos.envio, cantidad)
  return mostrarDetalleYEnvio(s, producto, cfg.tarifas, cantidad)
}

// ── Pago ────────────────────────────────────────────────────────────────

const CIERRE_PAGO = 'Cuando pagues, envíame la foto o el PDF del comprobante, o toca «Escribir datos».'

/** El paso de pago de una solicitud: encabezado, validez, bloque de pago de la base y botones. */
async function mostrarPaso(
  s: S,
  d: { id: string; numero: string; totalUsd: number | null; venceEn: string | null; bloque: string; nuevo: boolean; extra?: string },
) {
  await guardar(s, 'compra_pago', {
    compraId: d.id,
    compraNumero: d.numero,
    compraTotalUsd: d.totalUsd,
    compraVenceEn: d.venceEn,
    datosPago: {},
    intentosDatosPago: 0,
  })
  const total = d.totalUsd != null ? ` · *${dinero(d.totalUsd)}*` : ''
  const encabezado = d.nuevo ? `Solicitud ${d.numero} creada${total}.` : `Tu solicitud ${d.numero} espera tu pago${total}.`
  const vence = fechaHora(d.venceEn)
  const partes = [encabezado + (vence ? ` Precio válido hasta ${vence}.` : ''), d.extra ?? '', d.bloque, CIERRE_PAGO].filter((p) => p !== '')
  await enviar(s, partes.join('\n\n'), BOTONES_PAGO)
  return { paso: 'compra_pago', numero: d.numero }
}

async function ofrecerActualizar(s: S) {
  await enviar(
    s,
    `La cotización de ${numeroDe(s)} venció. ¿La actualizo con el precio de hoy?\n\nSi ya pagaste, escribe «persona» y lo revisamos.`,
    BOTONES_VENCIDA,
  )
  return { paso: s.estado, vencida: true }
}

type Pendiente = {
  request_id: string
  request_number: unknown
  total_usd?: number
  quote_expires_at?: string | null
  vencida?: boolean
} | null

/** Recupera la solicitud abierta en `esperando_pago` y deja la sesión en `compra_pago`. */
async function recuperarPago(s: S): Promise<'ok' | 'ninguna' | 'error'> {
  const r = await probar<Pendiente>(s, 'bot_compra_pendiente_de_pago', { p_phone: s.tel, p_channel: s.ctx.transporte.canal })
  if (!r.ok) {
    await enviar(s, r.mensaje, [B_MIS, B_MENU])
    return 'error'
  }
  if (!r.data?.request_id) return 'ninguna'
  await guardar(s, 'compra_pago', {
    compraId: r.data.request_id,
    compraNumero: formatoNumeroCompra(r.data.request_number),
    compraTotalUsd: positivo(r.data.total_usd),
    compraVenceEn: r.data.quote_expires_at ?? null,
    compraVencida: r.data.vencida === true,
    datosPago: {},
    intentosDatosPago: 0,
  })
  return 'ok'
}

async function recotizar(s: S) {
  if (!s.datos.compraId && !s.datos.detalleId) return invalida(s, 'No tengo una solicitud para actualizar.', [B_MIS, B_BUSCAR])
  const id = s.datos.compraId ?? s.datos.detalleId
  const r = await probar<Record<string, unknown>>(s, 'bot_compra_recotizar', { p_phone: s.tel, p_request_id: id, p_channel: s.ctx.transporte.canal })
  if (!r.ok) {
    await enviar(s, r.mensaje, [B_PERSONA, B_MIS, B_MENU])
    return { paso: s.estado, error: r.mensaje }
  }
  const c = r.data
  const nuevo = positivo(c.total_usd)
  const antes = positivo(c.total_anterior_usd)
  const cambio =
    nuevo != null && antes != null && Math.abs(nuevo - antes) > 0.005
      ? `Actualicé la cotización: el total pasó de ${dinero(antes)} a ${dinero(nuevo)}.`
      : 'Actualicé la cotización: el total sigue igual.'
  return mostrarPaso(s, {
    id: String(c.request_id ?? id),
    numero: formatoNumeroCompra(c.request_number ?? s.datos.compraNumero ?? s.datos.detalleNumero),
    totalUsd: nuevo,
    venceEn: (c.quote_expires_at as string | null) ?? null,
    bloque: String(c.payment_block ?? '').trim(),
    nuevo: false,
    extra: cambio,
  })
}

async function reportarPagoPorAdjunto(s: S) {
  const adjunto = s.mensaje.adjunto
  if (!adjunto || !s.datos.compraId) return null
  let ruta: string
  try {
    ruta = await s.ctx.transporte.guardarComprobante(
      { id: adjunto.id, mime: adjunto.mime, receipt_path: (s.mensaje.raw as { receipt_path?: string } | null)?.receipt_path },
      s.datos.compraId,
    )
  } catch (err) {
    console.error('compras: no se pudo guardar el comprobante', err instanceof Error ? err.message : '')
    await enviar(s, 'No pude guardar tu comprobante. Envíalo de nuevo o toca «Escribir datos» y me pasas banco, teléfono y referencia.', BOTONES_PAGO)
    return { paso: 'compra_pago', error: 'comprobante' }
  }
  const nota = s.texto || `Comprobante adjunto (${adjunto.mime || s.mensaje.type})`
  const refCaptura = `CAP-${adjunto.id.replace(/[^a-zA-Z0-9]/g, '').slice(-16) || 'adjunto'}`
  const r = await probar<Record<string, unknown>>(s, 'bot_compra_reportar_pago', {
    p_phone: s.tel,
    p_request_id: s.datos.compraId,
    p_method: 'pago_movil',
    p_bank: 'Por verificar (captura)',
    p_reference: refCaptura,
    p_payer_phone: null,
    p_amount_ves: null,
    p_receipt_path: ruta,
    p_wa_message_id: s.mensaje.id,
    p_note: nota,
    p_channel: s.ctx.transporte.canal,
  })
  if (!r.ok) return errorDePago(s, r, BOTONES_PAGO)
  const numero = numeroDe(s)
  const ya = r.data?.ya_registrado === true
  await guardar(s, 'compra_buscar', {})
  await enviar(
    s,
    ya
      ? `Ese comprobante de ${numero} ya lo habíamos recibido. Lo verificamos y te aviso por aquí.`
      : `Recibimos tu comprobante de ${numero}. Lo verificamos y te aviso por aquí.`,
    BOTONES_DESPUES_ACCION,
  )
  return { paso: 'compra_pago_reportado', via: 'adjunto', purchase_id: s.datos.compraId }
}

async function errorDePago(s: S, r: { mensaje: string; vencida: boolean }, botones: BotonCompra[]) {
  if (r.vencida) {
    // «Actualizar» se ofrece con la sesión ya en `compra_pago` y marcada como vencida:
    // así el primer toque vale aunque el error llegara desde `compra_pago_datos`.
    await guardar(s, 'compra_pago', { ...s.datos, compraVencida: true, datosPago: {}, intentosDatosPago: 0 })
    return ofrecerActualizar(s)
  }
  await enviar(s, r.mensaje, botones)
  return { paso: s.estado, error: r.mensaje }
}

async function procesarDatosDePago(s: S, entrada: string) {
  const acumulado: DatosDePago = juntarDatosDePago(s.datos.datosPago ?? {}, leerDatosDePago(entrada))
  const faltan = faltanDatosDePago(acumulado)

  if (faltan.length > 0) {
    const intentos = (s.datos.intentosDatosPago ?? 0) + 1
    await guardar(s, 'compra_pago_datos', { ...s.datos, datosPago: acumulado, intentosDatosPago: intentos })
    const pista =
      faltan.includes('telefono') || faltan.includes('referencia')
        ? ' Recuerda: teléfono venezolano de 11 dígitos (ej. 04141234567) y referencia completa de 8 a 20 dígitos.'
        : ''
    await enviar(s, `Para registrar el pago todavía necesito ${nombrarCampos(faltan)}.${pista}\n\nEnvíamelo aquí:\n${formularioDePago(faltan)}`)
    return { paso: 'compra_pago_datos', faltan }
  }

  const nota = `Pago Móvil · Banco: ${acumulado.banco} · Teléfono: ${acumulado.telefono} · Referencia: ${acumulado.referencia}`
  const r = await probar<Record<string, unknown>>(s, 'bot_compra_reportar_pago', {
    p_phone: s.tel,
    p_request_id: s.datos.compraId,
    p_method: 'pago_movil',
    p_bank: acumulado.banco,
    p_reference: acumulado.referencia,
    p_payer_phone: acumulado.telefono,
    p_amount_ves: null,
    p_receipt_path: null,
    p_wa_message_id: s.mensaje.id,
    p_note: nota,
    p_channel: s.ctx.transporte.canal,
  })
  if (!r.ok) return errorDePago(s, r, [])

  const numero = numeroDe(s)
  const ya = r.data?.ya_registrado === true
  await guardar(s, 'compra_buscar', {})
  await enviar(
    s,
    `${ya ? 'Ya teníamos' : 'Registramos'} tu Pago Móvil de ${numero}:\n` +
      `• Banco: ${acumulado.banco}\n` +
      `• Teléfono: ${acumulado.telefono}\n` +
      `• Referencia: ${acumulado.referencia}\n\n` +
      'Lo verificamos y te aviso por aquí. Si pagaste un monto distinto, dímelo.',
    BOTONES_DESPUES_ACCION,
  )
  return { paso: 'compra_pago_reportado', via: 'datos', purchase_id: s.datos.compraId, datosPago: acumulado }
}

// ── Mis compras y detalle ───────────────────────────────────────────────

type FilaSolicitud = Record<string, unknown>

function idDe(f: FilaSolicitud): string {
  return String(f.request_id ?? f.id ?? '')
}

async function misCompras(s: S) {
  const r = await probar<FilaSolicitud[]>(s, 'bot_compra_mis_solicitudes', { p_phone: s.tel, p_limit: 10, p_channel: s.ctx.transporte.canal })
  if (!r.ok) {
    await enviar(s, r.mensaje, BOTONES_BUSCAR)
    return { paso: 'compra_mis', error: r.mensaje }
  }
  const filas = (Array.isArray(r.data) ? r.data : []).filter((f) => idDe(f) !== '').slice(0, 10)
  if (filas.length === 0) {
    await guardar(s, 'compra_buscar', {})
    await enviar(
      s,
      'Todavía no tienes compras en Amazon registradas con Helios.\n\nEscríbeme qué insumo, equipo o libro médico buscas, o pega un enlace de Amazon para cotizarlo.',
      [B_BUSCAR, B_MENU],
    )
    return { paso: 'compra_mis', cuantas: 0 }
  }
  const lista: FilaLista[] = filas.map((f) => ({
    id: `compra:det:${idDe(f)}`,
    title: truncar(`${formatoNumeroCompra(f.request_number)} · ${String(f.product_title ?? 'Producto Amazon')}`, 24),
    description: truncar(
      `${etiquetaEstado(f.status)} · ${dinero(Number(f.total_usd ?? 0))}${f.created_at ? ` · ${fechaCorta(String(f.created_at))}` : ''}`,
      72,
    ),
  }))
  await guardar(s, 'compra_mis', { filasMis: filas.map((f) => ({ id: idDe(f), numero: formatoNumeroCompra(f.request_number) })) })
  await s.ctx.transporte.enviarLista('Tus compras en Amazon. Toca una para ver el detalle.', 'Ver compras', lista)
  return { paso: 'compra_mis', cuantas: filas.length }
}

async function verDetalle(s: S, id: string) {
  const r = await probar<Record<string, unknown>>(s, 'bot_compra_detalle', { p_phone: s.tel, p_request_id: id, p_channel: s.ctx.transporte.canal })
  if (!r.ok || !r.data) {
    await enviar(s, r.ok ? 'No encontré esa solicitud.' : r.mensaje, [B_MIS, B_BUSCAR])
    return { paso: 'compra_detalle', error: true }
  }
  const d = r.data
  const status = String(d.status ?? '')
  const numero = formatoNumeroCompra(d.request_number)
  const vencida = d.vencida === true
  const cantidad = Number(d.quantity ?? 1)
  const metodo = d.shipping_method === 'maritimo' ? 'maritimo' : d.shipping_method === 'aereo' ? 'aereo' : null
  const abierta = status !== 'cancelado' && status !== 'entregado'

  const lineas = [
    `*${numero}* · ${truncar(String(d.product_title ?? 'Producto Amazon'), 80)}`,
    `Estado: *${etiquetaEstado(status)}*`,
    `${cantidad > 1 ? `Cantidad: ${cantidad} · ` : ''}${metodo ? `Envío ${nombreEnvio(metodo).toLowerCase()} · ` : ''}Total ${dinero(Number(d.total_usd ?? 0))}`,
  ]
  if (metodo && abierta && status !== 'esperando_pago' && status !== 'revision_aduanal') {
    lineas.push(`Tiempo estimado de llegada: ${ETA_ENVIO[metodo]} aprox.`)
  }
  if (status === 'esperando_pago') {
    lineas.push(
      vencida
        ? 'La cotización venció. Puedo actualizarla con el precio de hoy.'
        : `Precio válido${hastaCuando(d.quote_expires_at as string | null)}.`,
    )
  }
  if (status === 'revision_aduanal') lineas.push('Estamos revisando que se pueda traer (aprox. 1 día hábil). Te aviso por aquí.')
  if (d.us_tracking_number) lineas.push(`Seguimiento en EE. UU.: ${String(d.us_tracking_number)}`)
  const bloque = status === 'esperando_pago' && !vencida ? String(d.payment_block ?? '').trim() : ''
  const texto = [lineas.join('\n'), bloque].filter(Boolean).join('\n\n')

  let botones: BotonCompra[]
  if (status === 'esperando_pago') {
    botones = [vencida ? { id: 'compra:recotizar', title: 'Actualizar' } : { id: 'compra:pagar', title: 'Pagar' }, B_CANCELAR_COMPRA, B_PERSONA]
  } else if (status === 'revision_aduanal') {
    botones = [B_CANCELAR_COMPRA, B_PERSONA, B_MIS]
  } else {
    botones = [B_PERSONA, B_MIS, B_BUSCAR]
  }

  await guardar(s, 'compra_detalle', {
    filasMis: s.datos.filasMis,
    detalleId: id,
    detalleNumero: numero,
    compraId: status === 'esperando_pago' ? id : null,
    compraNumero: numero,
    compraTotalUsd: positivo(d.total_usd),
    compraVenceEn: (d.quote_expires_at as string | null) ?? null,
    compraVencida: vencida,
  })
  await enviar(s, texto, botones)
  return { paso: 'compra_detalle', status }
}

// ── Cancelar, persona, menú ─────────────────────────────────────────────

async function pedirCancelacion(s: S) {
  let id = s.datos.compraId ?? s.datos.detalleId ?? null
  let numero = s.datos.compraNumero ?? s.datos.detalleNumero ?? ''
  let datos = s.datos
  if (!id) {
    const rec = await probar<Pendiente>(s, 'bot_compra_pendiente_de_pago', { p_phone: s.tel, p_channel: s.ctx.transporte.canal })
    if (!rec.ok) {
      await enviar(s, rec.mensaje, [B_MIS, B_MENU])
      return { paso: s.estado, error: rec.mensaje }
    }
    if (rec.data?.request_id) {
      id = rec.data.request_id
      numero = formatoNumeroCompra(rec.data.request_number)
      datos = { ...datos, compraId: id, compraNumero: numero }
    }
  }
  if (!id) {
    await enviar(s, 'No tienes una solicitud abierta para cancelar. Si quieres cancelar lo que estás cotizando, escribe «cancelar».', [B_MIS, B_MENU])
    return { paso: s.estado, sinSolicitud: true }
  }
  const volverA: EstadoCompra = s.estado === 'compra_detalle' ? 'compra_detalle' : 'compra_pago'
  await guardar(s, 'compra_cancelar', { ...datos, compraId: id, compraNumero: numero, detalleId: s.datos.detalleId ?? id, cancelarVolverA: volverA })
  await enviar(s, `¿Cancelo la solicitud ${numero}? Aún no has pagado.`, BOTONES_CANCELAR)
  return { paso: 'compra_cancelar' }
}

async function cancelarSolicitud(s: S) {
  const id = s.datos.compraId ?? s.datos.detalleId
  const r = await probar<Record<string, unknown>>(s, 'bot_compra_cancelar', { p_phone: s.tel, p_request_id: id, p_channel: s.ctx.transporte.canal })
  if (!r.ok) {
    await enviar(s, r.mensaje, [B_PERSONA, B_MIS, B_MENU])
    return { paso: 'compra_cancelar', error: r.mensaje }
  }
  const numero = formatoNumeroCompra(r.data?.request_number ?? s.datos.compraNumero)
  await guardar(s, 'compra_buscar', {})
  await enviar(s, `Listo, cancelé la solicitud ${numero}. No se hizo ningún cobro.`, [B_BUSCAR, B_MIS, B_MENU])
  return { paso: 'compra_cancelada', purchase_id: id }
}

async function volverDeCancelar(s: S) {
  const id = s.datos.compraId ?? s.datos.detalleId
  if (s.datos.cancelarVolverA === 'compra_detalle' && id) return verDetalle(s, id)
  return reanudarPago(s)
}

/** Repite el paso de pago de la solicitud abierta con lo guardado en la sesión. */
async function reanudarPago(s: S) {
  const d = s.datos
  if (!d.compraId) return iniciarBusqueda(s)
  await guardar(s, 'compra_pago', { ...d, cancelarVolverA: null })
  if (esVencida(s)) return ofrecerActualizar(s)
  await enviar(s, `Seguimos con tu solicitud ${numeroDe(s)}. ${CIERRE_PAGO}`, BOTONES_PAGO)
  return { paso: 'compra_pago' }
}

async function pedirPersona(s: S) {
  const id = s.datos.compraId ?? s.datos.detalleId ?? null
  const r = await probar<unknown>(s, 'bot_compra_pedir_persona', {
    p_phone: s.tel,
    p_request_id: id,
    p_texto: s.texto || null,
  })
  if (!r.ok) {
    await enviar(s, r.mensaje, [B_MIS, B_MENU])
    return { paso: s.estado, error: r.mensaje }
  }
  await enviar(s, 'Listo, avisé al equipo de Helios. Te escriben por aquí en horario de atención.', [B_MIS, B_BUSCAR, B_MENU])
  return { paso: s.estado, persona: true }
}

/** «Menú» / «cancelar» / «volver al menú»: sin solicitud no se registró nada; con ella, sigue abierta. */
async function salirAlMenu(s: S) {
  const abierta = (s.estado === 'compra_pago' || s.estado === 'compra_pago_datos' || s.estado === 'compra_cancelar') && s.datos.compraId
  if (abierta) {
    const hasta = s.datos.compraVenceEn ? ` hasta el ${fechaHora(s.datos.compraVenceEn)}` : ''
    return s.ctx.volverAlMenu(
      `Tu solicitud ${numeroDe(s)} sigue abierta${hasta}. La retomas desde «Mis compras». Si quieres cancelarla, escribe «cancelar compra».\n\n¿Qué quieres hacer?`,
    )
  }
  const cancelo = s.n === 'cancelar' || s.boton === 'orden:cancelar'
  const aMedias = ['compra_buscar', 'compra_resultados', 'compra_envio', 'compra_cantidad', 'compra_confirmar'].includes(s.estado)
  if (cancelo && aMedias) return s.ctx.volverAlMenu(`${NO_REGISTRO_NADA} ¿Qué quieres hacer?`)
  return s.ctx.volverAlMenu()
}

// ── Pasos obsoletos ─────────────────────────────────────────────────────

/** Repite el paso en el que está la sesión. */
async function repetirPaso(s: S) {
  const d = s.datos
  switch (s.estado) {
    case 'compra_resultados': {
      const cfg = await cargarConfig(s)
      if (cfg && d.resultados && d.resultados.length > 0) return mostrarResultados(s, d.consulta ?? '', d.resultados, cfg.tarifas)
      return iniciarBusqueda(s)
    }
    case 'compra_envio': {
      const cfg = await cargarConfig(s)
      if (cfg && d.producto) return mostrarDetalleYEnvio(s, d.producto, cfg.tarifas, d.cantidad ?? 1)
      return iniciarBusqueda(s)
    }
    case 'compra_confirmar': {
      const cfg = await cargarConfig(s)
      if (cfg && d.producto && d.envio) return mostrarConfirmacion(s, d.producto, cfg.tarifas, d.envio, d.cantidad ?? 1)
      return iniciarBusqueda(s)
    }
    case 'compra_cantidad':
      return preguntarCantidad(s)
    case 'compra_pago':
    case 'compra_pago_datos':
      return reanudarPago(s)
    case 'compra_cancelar':
      await enviar(s, `¿Cancelo la solicitud ${numeroDe(s)}? Aún no has pagado.`, BOTONES_CANCELAR)
      return { paso: 'compra_cancelar' }
    case 'compra_mis':
      return misCompras(s)
    case 'compra_detalle':
      return d.detalleId ? verDetalle(s, d.detalleId) : misCompras(s)
    default:
      return iniciarBusqueda(s)
  }
}

async function botonObsoleto(s: S) {
  const num = s.datos.compraNumero
  await enviar(s, `Esa opción ya no está activa.${num ? ` Seguimos con tu compra ${num}.` : ''}`)
  if (!ES_ESTADO_COMPRA(s.estado)) return s.ctx.volverAlMenu('¿Qué quieres hacer?')
  return repetirPaso(s)
}

/** ¿Un botón `compra:*` ya no corresponde al estado dado? */
export function botonObsoletoEnEstado(boton: string, estado: string): boolean {
  if (!boton.startsWith('compra:') || BOTONES_DE_NAVEGACION.test(boton)) return false
  for (const [patron, estados] of BOTON_POR_ESTADO) {
    if (patron.test(boton)) return !estados.includes(estado)
  }
  return true // un `compra:*` desconocido
}

function esObsoleto(s: S): boolean {
  return botonObsoletoEnEstado(s.boton, s.estado)
}

// ── Un manejador por estado ─────────────────────────────────────────────

async function hBuscar(s: S) {
  if (s.mensaje.adjunto) {
    return invalida(s, 'Para buscar, escribe el nombre del producto o pega el enlace de Amazon.', BOTONES_BUSCAR)
  }
  if (!s.texto) return invalida(s, 'Escribe el nombre del producto médico que buscas en Amazon o pega su enlace.', BOTONES_BUSCAR)
  // Con una persona atendiendo, un texto libre es para ella: solo enlaces y códigos disparan la búsqueda.
  const esEnlace = contieneEnlace(s.texto) || extraerAsinDeTexto(s.texto) !== null
  if (!esEnlace) {
    if (s.ctx.humano || esCortesia(s.mensaje)) return null
    if (!consultaValida(s)) {
      return invalida(s, `Escribe el nombre del producto (entre ${MIN_BUSQUEDA} y ${MAX_BUSQUEDA} letras) o pega el enlace de Amazon.`, BOTONES_BUSCAR)
    }
  }
  return ejecutarBusqueda(s, s.texto)
}

async function hResultados(s: S) {
  const resultados = s.datos.resultados ?? []
  let elegido: ProductoResumen | undefined
  if (s.boton.startsWith('compra:v:')) {
    const asin = s.boton.slice('compra:v:'.length).trim().toUpperCase()
    elegido = resultados.find((r) => r.asin.toUpperCase() === asin)
    if (!elegido) return botonObsoleto(s)
  } else if (/^\d{1,2}$/.test(s.n)) {
    const i = Number(s.n)
    if (i < 1 || i > resultados.length) {
      return invalida(s, `Elige un número del 1 al ${resultados.length}, o escribe otra búsqueda.`, BOTONES_BUSCAR)
    }
    elegido = resultados[i - 1]
  }
  if (elegido) {
    const listo = await prepararCatalogo(s)
    if (!listo) return { paso: s.estado, error: 'sin_catalogo' }
    const el = elegido
    const det = await conCatalogo(s, () => detalleCatalogo(s, listo.proveedor, el.asin, el))
    if (!det.ok) return { paso: s.estado, error: 'catalogo' }
    if (det.valor) return mostrarDetalleYEnvio(s, det.valor, listo.tarifas)
    return invalida(s, 'No pude cargar el detalle de ese producto. Escribe otra búsqueda o pega el enlace de Amazon.', BOTONES_BUSCAR)
  }
  if (s.mensaje.adjunto || !s.texto) {
    return invalida(s, `Toca «Cotizar» en una opción, escribe un número del 1 al ${resultados.length} o escribe otra búsqueda.`, BOTONES_BUSCAR)
  }
  return hBuscar(s)
}

async function hEnvio(s: S) {
  const producto = s.datos.producto
  if (!producto) return iniciarBusqueda(s)
  const cantidad = leerCantidad(s.n, true)
  if (cantidad != null) return aplicarCantidad(s, cantidad)
  const metodo: MetodoEnvio | null =
    s.boton === 'compra:envio:aereo' || ['aereo', 'envio aereo', 'avion', '1'].includes(s.n)
      ? 'aereo'
      : s.boton === 'compra:envio:maritimo' || ['maritimo', 'envio maritimo', 'barco', '2'].includes(s.n)
        ? 'maritimo'
        : null
  if (metodo) {
    const cfg = await cargarConfig(s)
    if (!cfg) return { paso: s.estado, error: 'sin_config' }
    return mostrarConfirmacion(s, producto, cfg.tarifas, metodo, s.datos.cantidad ?? 1)
  }
  if (s.boton === 'compra:buscar') return iniciarBusqueda(s)
  // Un enlace o código nuevo se cotiza directamente.
  if (contieneEnlace(s.texto) || extraerAsinDeTexto(s.texto) !== null) return ejecutarBusqueda(s, s.texto)
  return invalida(s, 'Elige el método de envío para continuar: *Envío aéreo* o *Envío marítimo*.', BOTONES_ENVIO)
}

async function hCantidad(s: S) {
  const cantidad = leerCantidad(s.n, false)
  if (cantidad == null) return invalida(s, `Escribe un número del 1 al ${MAX_CANTIDAD_CHAT}.`)
  return aplicarCantidad(s, cantidad)
}

async function hConfirmar(s: S) {
  const producto = s.datos.producto
  const metodo = s.datos.envio
  if (!producto || !metodo) return iniciarBusqueda(s)

  if (s.boton === 'compra:cantidad') return preguntarCantidad(s)
  const cantidadPedida = leerCantidad(s.n, true)
  if (cantidadPedida != null) return aplicarCantidad(s, cantidadPedida)

  if (s.boton === 'compra:cambiar_envio' || ['cambiar envio', 'cambiar', 'otro envio'].includes(s.n)) {
    const cfg = await cargarConfig(s)
    if (!cfg) return { paso: s.estado, error: 'sin_config' }
    return mostrarDetalleYEnvio(s, producto, cfg.tarifas, s.datos.cantidad ?? 1)
  }

  if (s.boton === 'compra:confirmar' || ['confirmar', 'confirmar compra', 'pedir revision', 'si'].includes(s.n)) {
    return crearSolicitud(s, producto, metodo)
  }
  return invalida(s, 'Usa los botones: Confirmar compra, Cambiar envío o Cambiar cantidad. Para cancelar escribe «cancelar».', [
    { id: 'compra:confirmar', title: 'Confirmar compra' },
    { id: 'compra:cambiar_envio', title: 'Cambiar envío' },
    { id: 'compra:cantidad', title: 'Cambiar cantidad' },
  ])
}

async function crearSolicitud(s: S, producto: ProductoDetalle, metodo: MetodoEnvio) {
  // Se vuelve a pedir la configuración: si las tarifas o la tasa cambiaron, se muestra el precio nuevo antes de crear.
  const cfg = await cargarConfig(s)
  if (!cfg) return { paso: s.estado, error: 'sin_config' }
  const cantidad = s.datos.cantidad ?? 1
  const cot = calcularCotizacion(producto, cfg.tarifas, metodo, cantidad)
  const antes = s.datos.cotizacion?.totalUsd
  if (antes != null && Math.abs(antes - cot.totalUsd) > 0.01) {
    return mostrarConfirmacion(s, producto, cfg.tarifas, metodo, cantidad, `El precio cambió: antes ${dinero(antes)}, ahora ${dinero(cot.totalUsd)}.\n\n`)
  }

  const r = await probar<Record<string, unknown>>(s, 'bot_compra_crear', {
    p_phone: s.tel,
    p_asin: producto.asin,
    p_product_title: producto.titulo,
    p_product_url: producto.url,
    p_image_url: producto.imagenUrl || null,
    p_variant_label: s.datos.variante ?? null,
    p_quantity: cot.quantity,
    p_category: producto.categoria,
    p_weight_lb: cot.weightRealLb,
    p_volumetric_weight_lb: cot.volumetricWeightLb > 0 ? cot.volumetricWeightLb : null,
    p_volume_ft3: cot.volumeFt3 > 0 ? cot.volumeFt3 : null,
    p_weight_estimated: cot.weightEstimated,
    p_restricted_flag: cot.restriccion.restringido,
    p_restricted_reason: cot.restriccion.motivo,
    p_shipping_method: cot.shippingMethod,
    p_unit_price_usd: cot.unitPriceUsd,
    p_channel: s.ctx.transporte.canal,
    p_idempotency_key: s.mensaje.id,
    p_session_total_usd: cot.totalUsd,
  })
  if (!r.ok) {
    await enviar(s, `No pudimos crear la solicitud: ${r.mensaje}`, [
      { id: 'compra:confirmar', title: 'Confirmar compra' },
      { id: 'compra:cambiar_envio', title: 'Cambiar envío' },
      B_PERSONA,
    ])
    return { paso: 'compra_confirmar', error: r.mensaje }
  }

  const c = r.data ?? {}
  const reqId = String(c.request_id ?? c.id ?? '')
  const num = formatoNumeroCompra(c.request_number ?? c.code ?? reqId)
  const restringido =
    c.restricted_flag === true || c.status === 'revision_aduanal' || (c.restricted_flag == null && cot.restriccion.restringido)

  if (restringido) {
    await guardar(s, 'compra_buscar', {})
    await enviar(
      s,
      `Solicitud ${num} registrada para revisión aduanal (aprox. 1 día hábil).\n\n` +
        `*${truncar(producto.titulo, 95)}*\n` +
        'Te aviso por aquí en cuanto esté aprobada para que puedas pagar.',
      BOTONES_DESPUES_ACCION,
    )
    return { paso: 'compra_revision_aduanal', purchase_id: reqId || null, numero: num }
  }

  const totalUsd = positivo(c.total_usd) ?? cot.totalUsd
  const cambio = c.total_cambio === true ? `Ojo: el total final es ${dinero(totalUsd)} porque la base recalculó con las tarifas de hoy.` : undefined
  return mostrarPaso(s, {
    id: reqId,
    numero: num,
    totalUsd,
    venceEn: (c.quote_expires_at as string | null) ?? null,
    bloque: String(c.payment_block ?? cfg.tarifas.accountsBlock ?? '').trim(),
    nuevo: true,
    extra: cambio,
  })
}

async function hPago(s: S) {
  if (!s.datos.compraId) return s.ctx.volverAlMenu('No tengo una compra pendiente de pago en esta sesión. ¿Qué quieres hacer?')

  if (s.mensaje.adjunto) return reportarPagoPorAdjunto(s)

  if (s.boton === 'compra:recotizar') return recotizar(s)
  if (s.boton === 'compra:datos_pago' || quiereEscribirLosDatos(s.texto)) {
    if (esVencida(s)) return ofrecerActualizar(s)
    await guardar(s, 'compra_pago_datos', { ...s.datos, datosPago: {}, intentosDatosPago: 0 })
    await enviar(
      s,
      'Perfecto. Envíame los datos de tu Pago Móvil en un solo mensaje (banco, teléfono de 11 dígitos y referencia completa de 8 a 20 dígitos). ' +
        `Puedes copiar esta plantilla o escribirlos uno por línea:\n\n${formularioDePago()}`,
    )
    return { paso: 'compra_pago_datos' }
  }

  if (s.boton === 'compra:ya_pague' || ['ya pague', 'pague', 'listo ya pague'].includes(s.n)) {
    if (esVencida(s)) return ofrecerActualizar(s)
    await enviar(
      s,
      'Envíame ahora la foto o el PDF de tu comprobante de pago por aquí.\n\nSi no tienes captura, toca «Escribir datos» o escribe «datos» y me pasas tu banco, teléfono y referencia.',
      [{ id: 'compra:datos_pago', title: 'Escribir datos' }, B_MIS, B_MENU],
    )
    return { paso: 'compra_pago', recordatorio: true }
  }

  // Datos de Pago Móvil escritos directamente, sin tocar «Escribir datos».
  if (s.texto) {
    const intento = leerDatosDePago(s.texto)
    const reconocidos = [intento.banco, intento.telefono, intento.referencia].filter(Boolean).length
    if (reconocidos >= 2) return procesarDatosDePago(s, s.texto)
  }

  if (esVencida(s)) return s.ctx.humano || esCortesia(s.mensaje) ? null : ofrecerActualizar(s)
  return invalida(
    s,
    `Tu compra ${numeroDe(s)} espera tu comprobante de pago. Envíame la foto o el PDF, o toca «Escribir datos» para pasarme tu banco, teléfono y referencia.`,
    BOTONES_PAGO,
  )
}

async function hPagoDatos(s: S) {
  if (!s.datos.compraId) return s.ctx.volverAlMenu('No tengo una compra pendiente de pago en esta sesión. ¿Qué quieres hacer?')
  if (s.mensaje.adjunto) return reportarPagoPorAdjunto(s)
  if (s.boton === 'compra:recotizar') return recotizar(s)
  if (s.boton === 'compra:ya_pague' || s.boton === 'compra:datos_pago') {
    await enviar(s, `Envíame los datos de tu Pago Móvil:\n\n${formularioDePago()}`)
    return { paso: 'compra_pago_datos' }
  }
  if (!s.texto) {
    await enviar(s, `Envíame los datos de tu Pago Móvil:\n\n${formularioDePago()}`)
    return { paso: 'compra_pago_datos' }
  }
  // Con una persona atendiendo, lo que no parece un dato de pago es para ella.
  const intento = leerDatosDePago(s.texto)
  if (s.ctx.humano && !intento.banco && !intento.telefono && !intento.referencia) return null
  return procesarDatosDePago(s, s.texto)
}

async function hCancelar(s: S) {
  if (s.boton === 'compra:cancelar_si' || ['si cancelar', 'si', 'cancelar compra'].includes(s.n)) return cancelarSolicitud(s)
  if (s.boton === 'compra:cancelar_no' || ['no seguir', 'no', 'seguir'].includes(s.n)) return volverDeCancelar(s)
  return invalida(s, `¿Cancelo la solicitud ${numeroDe(s)}? Aún no has pagado.`, BOTONES_CANCELAR)
}

async function hMis(s: S) {
  const i = /^\d{1,2}$/.test(s.n) ? Number(s.n) : 0
  const filas = s.datos.filasMis ?? []
  if (i >= 1 && i <= filas.length) return verDetalle(s, filas[i - 1].id)
  return invalida(s, filas.length > 0 ? `Toca una compra de la lista o escribe un número del 1 al ${filas.length}.` : 'Escribe «mis compras» para ver tu lista.', [B_BUSCAR, B_MENU])
}

async function hDetalle(s: S) {
  if (s.boton === 'compra:pagar') return pagarDesdeDetalle(s)
  if (s.boton === 'compra:recotizar') return recotizar(s)
  const i = /^\d{1,2}$/.test(s.n) ? Number(s.n) : 0
  const filas = s.datos.filasMis ?? []
  if (i >= 1 && i <= filas.length) return verDetalle(s, filas[i - 1].id)
  return invalida(s, 'Usa los botones de la solicitud o escribe «mis compras».', [B_MIS, B_BUSCAR, B_MENU])
}

async function pagarDesdeDetalle(s: S) {
  const id = s.datos.detalleId
  if (!id) return misCompras(s)
  const r = await probar<Record<string, unknown>>(s, 'bot_compra_detalle', { p_phone: s.tel, p_request_id: id, p_channel: s.ctx.transporte.canal })
  if (!r.ok || !r.data) {
    await enviar(s, r.ok ? 'No encontré esa solicitud.' : r.mensaje, [B_MIS, B_MENU])
    return { paso: 'compra_detalle', error: true }
  }
  const d = r.data
  if (d.status !== 'esperando_pago') return verDetalle(s, id)
  if (d.vencida === true) {
    s.datos = { ...s.datos, compraId: id, compraNumero: formatoNumeroCompra(d.request_number), compraVencida: true }
    return ofrecerActualizar(s)
  }
  return mostrarPaso(s, {
    id,
    numero: formatoNumeroCompra(d.request_number),
    totalUsd: positivo(d.total_usd),
    venceEn: (d.quote_expires_at as string | null) ?? null,
    bloque: String(d.payment_block ?? '').trim(),
    nuevo: false,
  })
}

/** `compra:reenviar:<id>` (el aviso de un pago rechazado): se pide otro comprobante para esa solicitud. */
async function reenviarComprobante(s: S) {
  const id = s.boton.slice('compra:reenviar:'.length).trim()
  if (!UUID.test(id)) return botonObsoleto(s)
  const r = await probar<Record<string, unknown>>(s, 'bot_compra_detalle', { p_phone: s.tel, p_request_id: id, p_channel: s.ctx.transporte.canal })
  if (!r.ok || !r.data) {
    await enviar(s, r.ok ? 'No encontré esa solicitud.' : r.mensaje, [B_MIS, B_PERSONA])
    return { paso: 'compra_pago', error: true }
  }
  const numero = formatoNumeroCompra(r.data.request_number)
  await guardar(s, 'compra_pago', {
    compraId: id,
    compraNumero: numero,
    compraTotalUsd: positivo(r.data.total_usd),
    compraVenceEn: (r.data.quote_expires_at as string | null) ?? null,
    compraVencida: r.data.vencida === true,
    datosPago: {},
    intentosDatosPago: 0,
  })
  await enviar(
    s,
    `Para ${numero}, envíame la foto o el PDF del nuevo comprobante, o toca «Escribir datos» y me pasas banco, teléfono y referencia.`,
    [{ id: 'compra:datos_pago', title: 'Escribir datos' }, B_PERSONA, B_MIS],
  )
  return { paso: 'compra_pago', reenvio: true }
}

const MANEJADORES: Record<EstadoCompra, (s: S) => Promise<unknown>> = {
  compra_buscar: hBuscar,
  compra_resultados: hResultados,
  compra_envio: hEnvio,
  compra_cantidad: hCantidad,
  compra_confirmar: hConfirmar,
  compra_pago: hPago,
  compra_pago_datos: hPagoDatos,
  compra_cancelar: hCancelar,
  compra_mis: hMis,
  compra_detalle: hDetalle,
}

// ── Entrada ─────────────────────────────────────────────────────────────

export async function atenderCompraMedico(ctx: ContextoCompra): Promise<unknown> {
  const s = crearS(ctx)
  const enCompra = ES_ESTADO_COMPRA(s.estado)

  // 1. Salir al menú: «menú», «cancelar», «volver al menú».
  if (PALABRAS_DE_MENU.has(s.n) || s.boton === 'compra:menu' || s.boton === 'orden:cancelar') return salirAlMenu(s)

  // 2. Una persona.
  if (s.boton === 'compra:persona' || PALABRAS_PERSONA.has(s.n)) return pedirPersona(s)

  // 3. Cancelar la solicitud abierta (hay que confirmarlo).
  if (s.boton === 'compra:cancelar_pedir' || PALABRAS_CANCELAR_COMPRA.has(s.n)) {
    if (s.boton === 'compra:cancelar_pedir' && esObsoleto(s)) return botonObsoleto(s)
    if (s.estado === 'compra_cancelar') return hCancelar(s)
    return pedirCancelacion(s)
  }

  // 4. El pago nunca se pierde: un comprobante o «ya pagué» fuera de `compra_pago` recupera la solicitud abierta.
  if (esIntentoDePago(s.mensaje) && s.estado !== 'compra_pago' && s.estado !== 'compra_pago_datos') {
    const rec = await recuperarPago(s)
    if (rec === 'error') return { paso: 'compra_pago', error: 'pendiente' }
    if (rec === 'ok') return hPago(s)
    const explicito = s.boton !== '' || quiereEscribirLosDatos(s.texto) || TEXTOS_PAGO.has(s.n)
    if (explicito) {
      await enviar(s, 'No tengo una compra esperando tu pago. Si ya enviaste tu comprobante, lo estamos verificando: míralo en «Mis compras».', [B_MIS, B_BUSCAR, B_MENU])
      return { paso: 'sin_compra_pendiente' }
    }
    // Un adjunto suelto, sin compra de por medio: como siempre, fuera del flujo es «No entendí».
    if (!enCompra) return s.ctx.humano ? null : s.ctx.volverAlMenu('No entendí. ¿Qué quieres hacer?')
  }

  // 5. Mis compras y su detalle (valen en cualquier paso).
  if (s.boton === 'compra:mis' || ['mis compras', 'mis pedidos'].includes(s.n)) return misCompras(s)
  if (s.boton.startsWith('compra:det:')) {
    const id = s.boton.slice('compra:det:'.length)
    return UUID.test(id) ? verDetalle(s, id) : botonObsoleto(s)
  }
  if (s.boton.startsWith('compra:reenviar:')) return reenviarComprobante(s)

  // 6. Iniciar o reiniciar la búsqueda.
  if (
    s.boton === 'menu:comprar' ||
    s.boton === 'compra:buscar' ||
    (!enCompra && ['comprar', 'comprar en amazon', 'amazon', 'catalogo', 'catalogo amazon', '3'].includes(s.n))
  ) {
    return iniciarBusqueda(s)
  }

  // 7. Botones viejos.
  if (esObsoleto(s)) return botonObsoleto(s)

  // 8. Fuera del flujo: un enlace o código pegado en el menú; si no, el menú.
  if (!enCompra) {
    if (analizarEnlaceAmazon(s.texto) !== null || extraerAsinDeTexto(s.texto) !== null) return ejecutarBusqueda(s, s.texto)
    return s.ctx.volverAlMenu()
  }

  // 9. El manejador del estado.
  return MANEJADORES[s.estado as EstadoCompra](s)
}
