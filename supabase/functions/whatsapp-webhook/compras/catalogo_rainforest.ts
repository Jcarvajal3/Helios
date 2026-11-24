// ═══════════════════════════════════════════════════════════════════════════
// Helios — Adaptador Rainforest API para catálogo real de Amazon
//
// Implementa `ProveedorCatalogo` contra `https://api.rainforestapi.com/request`
// (campos verificados en docs.trajectdata.com/rainforestapi: `weight` de texto,
// `specifications[{name,value}]`, `buybox_winner.price.value`,
// `main_image.link`, `request_info.success`).
//
// El proveedor lo fija la base (`purchase_settings.catalog_provider`); la clave
// va en el secreto `RAINFOREST_API_KEY`. Aquí NO hay respaldo silencioso a mock:
// sin clave, `crearProveedorCatalogo` devuelve null y el bot dice que las
// compras no están disponibles.
//
// Seguridad: la clave viaja en la URL de la consulta; por eso ningún error
// sale de aquí con la URL ni con el mensaje original de `fetch` (podría
// incluirla). Todo falla como `ErrorCatalogo` con un texto fijo.
// ═══════════════════════════════════════════════════════════════════════════

import { extraerAsinDeTexto, normalizarBusquedaMedica } from './amazon_parser.ts'
import { ProveedorAmazonMock } from './catalogo_mock.ts'
import { redondearCentavos } from './cotizador.ts'
import type { DimensionesIn, ProductoDetalle, ProductoResumen, ProveedorCatalogo } from './tipos.ts'

const RAINFOREST_ENDPOINT = 'https://api.rainforestapi.com/request'
export const TIEMPO_RAINFOREST_MS = 8000

/** Por qué falló el catálogo (sin URL ni clave en el mensaje). */
export type TipoErrorCatalogo = 'timeout' | 'limite' | 'red' | 'http' | 'rechazo' | 'formato'

export class ErrorCatalogo extends Error {
  constructor(
    readonly tipo: TipoErrorCatalogo,
    mensaje: string,
    readonly estado?: number,
  ) {
    super(mensaje)
    this.name = 'ErrorCatalogo'
  }
}

/** «1,200» es mil doscientos; «1,5» es uno y medio; «1.4» es uno coma cuatro. */
function numeroDeTexto(s: string): number {
  if (/^\d{1,3}(,\d{3})+(\.\d+)?$/.test(s)) return Number(s.replace(/,/g, ''))
  return Number(s.replace(',', '.'))
}

const NUM = String.raw`(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:[.,]\d+)?)`

/**
 * Convierte textos reales de peso de Amazon/Rainforest («1.4 pounds»,
 * «14.4 ounces», «1,200 grams», «2.5 kg», «1 lb 4 oz») a libras redondeadas a
 * 2 decimales. Con dos medidas equivalentes («5 pounds (2.27 kg)») toma la primera.
 */
export function parsearPesoALibras(texto: string | null | undefined): number | null {
  if (!texto) return null

  // «1 lb 4 oz», «1 pound 4 ounces»
  const compuesto = new RegExp(`${NUM}\\s*(?:pounds?|lbs?)\\.?\\s*(?:and\\s+|,\\s*)?${NUM}\\s*(?:ounces?|oz)\\b`, 'i').exec(texto)
  if (compuesto) {
    const lb = numeroDeTexto(compuesto[1])
    const oz = numeroDeTexto(compuesto[2])
    if (Number.isFinite(lb) && Number.isFinite(oz) && lb + oz > 0) return redondearCentavos(lb + oz / 16)
  }

  const m = new RegExp(`${NUM}\\s*(pounds?|lbs?|ounces?|oz|kilograms?|kgs?|grams?|g)\\b`, 'i').exec(texto)
  if (!m) return null
  const valor = numeroDeTexto(m[1])
  if (!Number.isFinite(valor) || valor <= 0) return null
  const unidad = m[2].toLowerCase()
  if (unidad.startsWith('lb') || unidad.startsWith('pound')) return redondearCentavos(valor)
  if (unidad.startsWith('oz') || unidad.startsWith('ounce')) return redondearCentavos(valor / 16)
  if (unidad.startsWith('kg') || unidad.startsWith('kilogram')) return redondearCentavos(valor * 2.20462)
  if (unidad === 'g' || unidad.startsWith('gram')) return redondearCentavos(valor / 453.592)
  return null
}

/**
 * Convierte dimensiones de Amazon/Rainforest («13 x 6.5 x 2 inches»,
 * «30 x 20 x 10 cm», «13"L x 6.5"W x 2"H», «1.18"D x 2.36"W x 1.57"H») a pulgadas.
 */
export function parsearDimensionesAPulgadas(texto: string | null | undefined): DimensionesIn | null {
  if (!texto) return null
  const m =
    /(\d+(?:[.,]\d+)?)\s*(?:"|in(?:ches)?|cm|mm)?\s*[lwhd]?\s*[x×]\s*(\d+(?:[.,]\d+)?)\s*(?:"|in(?:ches)?|cm|mm)?\s*[lwhd]?\s*[x×]\s*(\d+(?:[.,]\d+)?)\s*(?:"|in(?:ches)?|cm|mm)?\s*[lwhd]?(?:\s*(inches|in|cm|mm))?/i.exec(
      texto,
    )
  if (!m) return null
  const a = numeroDeTexto(m[1])
  const b = numeroDeTexto(m[2])
  const c = numeroDeTexto(m[3])
  if (![a, b, c].every((n) => Number.isFinite(n) && n > 0)) return null

  const sufijo = (m[4] ?? texto).toLowerCase()
  let factor = 1
  if (/\bcm\b|centimet/i.test(sufijo)) factor = 1 / 2.54
  else if (/\bmm\b|millimet/i.test(sufijo)) factor = 1 / 25.4

  return {
    largo: redondearCentavos(a * factor),
    ancho: redondearCentavos(b * factor),
    alto: redondearCentavos(c * factor),
  }
}

function objeto(v: unknown): Record<string, unknown> | null {
  return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null
}

export function numeroPositivo(v: unknown): number | null {
  const n = Number(v)
  return v != null && Number.isFinite(n) && n > 0 ? n : null
}

function textoLimpio(v: unknown): string {
  return typeof v === 'string' ? v.trim() : ''
}

/** El valor de la primera especificación cuyo nombre cumple, probando los patrones en orden de prioridad. */
function buscarEnEspecificaciones(specs: unknown, prioridad: RegExp[]): string | null {
  if (!Array.isArray(specs)) return null
  const filas = specs
    .map((item) => objeto(item))
    .map((f) => ({ nombre: textoLimpio(f?.name), valor: textoLimpio(f?.value) }))
    .filter((f) => f.nombre && f.valor)
  for (const patron of prioridad) {
    const hallada = filas.find((f) => patron.test(f.nombre))
    if (hallada) return hallada.valor
  }
  return null
}

const PESO_PRIORIDAD: RegExp[] = [
  /^item weight$/i,
  /^package weight$/i,
  /^product weight$/i,
  /^(?!.*(capacity|limit|max|maximum|per|unit count)).*\bweight\b/i,
]
const DIMENSIONES_PRIORIDAD: RegExp[] = [
  /^package dimensions/i,
  /^(item|product) dimensions/i,
  /dimensions/i,
]

function extraerVariantes(rawVariants: unknown): string[] {
  if (!Array.isArray(rawVariants)) return []
  const salida: string[] = []
  for (const v of rawVariants) {
    const fila = objeto(v)
    if (!fila) continue
    let etiqueta = textoLimpio(fila.title)
    if (!etiqueta && Array.isArray(fila.dimensions)) {
      etiqueta = fila.dimensions
        .map((d) => textoLimpio(objeto(d)?.value))
        .filter(Boolean)
        .join(' / ')
    }
    if (etiqueta && !salida.includes(etiqueta)) salida.push(etiqueta)
    if (salida.length >= 8) break
  }
  return salida
}

export class ProveedorRainforest implements ProveedorCatalogo {
  readonly nombre = 'rainforest'

  constructor(
    private readonly apiKey: string,
    private readonly amazonDomain = 'amazon.com',
    private readonly fetchFn: typeof fetch = fetch,
    private readonly tiempoMs: number = TIEMPO_RAINFOREST_MS,
  ) {}

  private async solicitar(params: Record<string, string>): Promise<Record<string, unknown>> {
    const url = new URL(RAINFOREST_ENDPOINT)
    url.searchParams.set('api_key', this.apiKey)
    url.searchParams.set('amazon_domain', this.amazonDomain)
    for (const [k, v] of Object.entries(params)) {
      url.searchParams.set(k, v)
    }

    let res: Response
    try {
      res = await this.fetchFn(url.toString(), {
        method: 'GET',
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(this.tiempoMs),
      })
    } catch (err) {
      // Jamás se propaga `err`: su mensaje puede traer la URL con la clave.
      const nombre = (err as { name?: unknown } | null)?.name
      if (nombre === 'TimeoutError' || nombre === 'AbortError') {
        throw new ErrorCatalogo('timeout', 'rainforest: tiempo de espera agotado')
      }
      throw new ErrorCatalogo('red', 'rainforest: sin conexión')
    }
    if (res.status === 429) throw new ErrorCatalogo('limite', 'rainforest: límite de consultas', 429)
    if (!res.ok) throw new ErrorCatalogo('http', `rainforest: HTTP ${res.status}`, res.status)

    let json: Record<string, unknown>
    try {
      json = (await res.json()) as Record<string, unknown>
    } catch {
      throw new ErrorCatalogo('formato', 'rainforest: respuesta que no es JSON')
    }
    // Rainforest puede contestar 200 con `request_info.success: false`.
    if (objeto(json.request_info)?.success === false) {
      throw new ErrorCatalogo('rechazo', 'rainforest: la consulta no tuvo éxito')
    }
    return json
  }

  async buscar(query: string, limite = 4): Promise<ProductoResumen[]> {
    const tope = Math.max(1, Math.min(10, Math.floor(limite)))
    const asinDirecto = extraerAsinDeTexto(query)
    if (asinDirecto) {
      const det = await this.detalle(asinDirecto)
      return det && det.disponible ? [det] : []
    }

    const { consultaEn } = normalizarBusquedaMedica(query)
    if (!consultaEn) return []

    const data = await this.solicitar({
      type: 'search',
      search_term: consultaEn,
      exclude_sponsored: 'true',
    })

    const resultados = Array.isArray(data.search_results) ? data.search_results : []
    const salida: ProductoResumen[] = []

    for (const item of resultados) {
      const r = objeto(item)
      if (!r) continue
      const asin = textoLimpio(r.asin).toUpperCase()
      const titulo = textoLimpio(r.title)
      const precioUsd = numeroPositivo(objeto(r.price)?.value) ?? numeroPositivo(objeto((Array.isArray(r.prices) ? r.prices : [])[0])?.value)
      if (!asin || !titulo || precioUsd == null) continue

      const categorias = Array.isArray(r.categories) ? r.categories : []
      const categoria = textoLimpio(objeto(categorias[0])?.name) || 'Amazon'

      salida.push({
        asin,
        titulo,
        precioUsd: redondearCentavos(precioUsd),
        imagenUrl: textoLimpio(r.image),
        url: textoLimpio(r.link) || `https://www.amazon.com/dp/${asin}`,
        rating: numeroPositivo(r.rating),
        resenas: numeroPositivo(r.ratings_total),
        categoria,
        prime: Boolean(r.is_prime),
        pesoLb: null,
        dimensionesIn: null,
      })
      if (salida.length >= tope) break
    }

    return salida
  }

  async detalle(asin: string): Promise<ProductoDetalle | null> {
    const limpio = extraerAsinDeTexto(asin) ?? asin.trim().toUpperCase()
    if (!limpio) return null

    const data = await this.solicitar({
      type: 'product',
      asin: limpio,
    })

    const prod = objeto(data.product)
    if (!prod) return null

    const titulo = textoLimpio(prod.title)
    if (!titulo) return null

    const buybox = objeto(prod.buybox_winner)
    const precioUsd = numeroPositivo(objeto(buybox?.price)?.value) ?? numeroPositivo(objeto(prod.price)?.value)

    const specs = prod.specifications
    const pesoTexto = textoLimpio(prod.weight) || buscarEnEspecificaciones(specs, PESO_PRIORIDAD) || ''
    // `dimensions` no es un campo de producto en la documentación; si viniera como texto, vale.
    const dimTexto = textoLimpio(prod.dimensions) || buscarEnEspecificaciones(specs, DIMENSIONES_PRIORIDAD) || ''

    const categorias = Array.isArray(prod.categories) ? prod.categories : []
    const categoria = textoLimpio(objeto(categorias[categorias.length - 1])?.name) || 'Amazon'

    const primeraImagen = Array.isArray(prod.images) ? textoLimpio(objeto(prod.images[0])?.link) : ''
    const imagen = textoLimpio(objeto(prod.main_image)?.link) || primeraImagen || textoLimpio(prod.image)

    const disponibilidad = objeto(buybox?.availability)
    const dispTipo = textoLimpio(disponibilidad?.type).toLowerCase()
    const dispRaw = textoLimpio(disponibilidad?.raw).toLowerCase()
    // Sin precio no hay nada que cotizar: no disponible.
    const disponible =
      precioUsd != null && dispTipo !== 'out_of_stock' && !/currently unavailable|out of stock/.test(dispRaw)

    const bullets = Array.isArray(prod.feature_bullets)
      ? prod.feature_bullets.map((b) => textoLimpio(b)).filter(Boolean)
      : []
    const descripcionCorta = (bullets.slice(0, 2).join(' · ') || textoLimpio(prod.description)).slice(0, 240)

    return {
      asin: limpio,
      titulo,
      precioUsd: redondearCentavos(precioUsd ?? 0),
      imagenUrl: imagen,
      url: textoLimpio(prod.link) || `https://www.amazon.com/dp/${limpio}`,
      rating: numeroPositivo(prod.rating),
      resenas: numeroPositivo(prod.ratings_total),
      categoria,
      prime: Boolean(buybox?.is_prime),
      pesoLb: parsearPesoALibras(pesoTexto),
      dimensionesIn: parsearDimensionesAPulgadas(dimTexto),
      variantes: extraerVariantes(prod.variants),
      disponible,
      descripcionCorta,
    }
  }
}

/**
 * Fábrica del catálogo según lo que dice la base (`purchase_settings.catalog_provider`):
 * `mock` → el catálogo de prueba; `rainforest` → Rainforest con su clave
 * (`RAINFOREST_API_KEY`). Rainforest sin clave devuelve null: NUNCA cae a mock.
 */
export function crearProveedorCatalogo(providerName?: string, apiKey?: string): ProveedorCatalogo | null {
  const nombre = (providerName ?? '').trim().toLowerCase()
  if (nombre === 'mock') return new ProveedorAmazonMock()
  if (nombre === 'rainforest' && (apiKey ?? '').trim() !== '') return new ProveedorRainforest(apiKey!.trim())
  return null
}
