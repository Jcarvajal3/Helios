// ═══════════════════════════════════════════════════════════════════════════
// Helios — Adaptador Rainforest API para catálogo real de Amazon
//
// Implementa `ProveedorCatalogo` contra `https://api.rainforestapi.com/request`.
// Se activa mediante `AMAZON_PROVIDER=rainforest` y `AMAZON_API_KEY`; sin
// credenciales, `crearProveedorCatalogo` entrega `ProveedorAmazonMock`.
// ═══════════════════════════════════════════════════════════════════════════

import { extraerAsinDeTexto, normalizarBusquedaMedica } from './amazon_parser.ts'
import { ProveedorAmazonMock } from './catalogo_mock.ts'
import { redondearCentavos } from './cotizador.ts'
import type { DimensionesIn, ProductoDetalle, ProductoResumen, ProveedorCatalogo } from './tipos.ts'

const RAINFOREST_ENDPOINT = 'https://api.rainforestapi.com/request'

/**
 * Convierte textos reales de peso de Amazon/Rainforest («1.4 pounds»,
 * «14.4 ounces», «500 grams», «2.5 kg») a libras redondeadas a 2 decimales.
 */
export function parsearPesoALibras(texto: string | null | undefined): number | null {
  if (!texto) return null
  const m = /(\d+(?:[.,]\d+)?)\s*(pounds?|lbs?|ounces?|oz|kilograms?|kgs?|grams?|g)\b/i.exec(texto)
  if (!m) return null
  const valor = Number(m[1].replace(',', '.'))
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
 * «30 x 20 x 10 cm», «13"L x 6.5"W x 2"H») a pulgadas.
 */
export function parsearDimensionesAPulgadas(texto: string | null | undefined): DimensionesIn | null {
  if (!texto) return null
  const m =
    /(\d+(?:[.,]\d+)?)\s*(?:"|in(?:ches)?|cm|mm)?\s*[lwh]?\s*[x×]\s*(\d+(?:[.,]\d+)?)\s*(?:"|in(?:ches)?|cm|mm)?\s*[lwh]?\s*[x×]\s*(\d+(?:[.,]\d+)?)\s*(?:"|in(?:ches)?|cm|mm)?\s*[lwh]?(?:\s*(inches|in|cm|mm))?/i.exec(
      texto,
    )
  if (!m) return null
  const a = Number(m[1].replace(',', '.'))
  const b = Number(m[2].replace(',', '.'))
  const c = Number(m[3].replace(',', '.'))
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

function numeroPositivo(v: unknown): number | null {
  const n = Number(v)
  return v != null && Number.isFinite(n) && n > 0 ? n : null
}

function textoLimpio(v: unknown): string {
  return typeof v === 'string' ? v.trim() : ''
}

function buscarEnEspecificaciones(specs: unknown, claves: RegExp): string | null {
  if (!Array.isArray(specs)) return null
  for (const item of specs) {
    const fila = objeto(item)
    const nombre = textoLimpio(fila?.name)
    const valor = textoLimpio(fila?.value)
    if (nombre && valor && claves.test(nombre)) return valor
  }
  return null
}

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
  ) {}

  private async solicitar(params: Record<string, string>): Promise<Record<string, unknown>> {
    const url = new URL(RAINFOREST_ENDPOINT)
    url.searchParams.set('api_key', this.apiKey)
    url.searchParams.set('amazon_domain', this.amazonDomain)
    for (const [k, v] of Object.entries(params)) {
      url.searchParams.set(k, v)
    }

    const res = await this.fetchFn(url.toString(), {
      method: 'GET',
      headers: { Accept: 'application/json' },
    })
    if (!res.ok) {
      throw new Error(`rainforest: HTTP ${res.status}`)
    }
    const json = (await res.json()) as Record<string, unknown>
    return json
  }

  async buscar(query: string, limite = 4): Promise<ProductoResumen[]> {
    const tope = Math.max(1, Math.min(10, Math.floor(limite)))
    const asinDirecto = extraerAsinDeTexto(query)
    if (asinDirecto) {
      const det = await this.detalle(asinDirecto)
      return det ? [det] : []
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
      const precioObj = objeto(r.price)
      const precioUsd = numeroPositivo(precioObj?.value)
      if (!asin || !titulo || precioUsd == null) continue

      const categorias = Array.isArray(r.categories) ? r.categories : []
      const categoria = textoLimpio(objeto(categorias[0])?.name) || 'Amazon'

      salida.push({
        asin,
        titulo,
        precioUsd: redondearCentavos(precioUsd),
        imagenUrl: textoLimpio(r.image) || `https://placehold.co/600x600/0f766e/ffffff.png?text=${encodeURIComponent(asin)}`,
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
    const precioUsd =
      numeroPositivo(objeto(buybox?.price)?.value) ??
      numeroPositivo(objeto(prod.price)?.value) ??
      0

    const specs = prod.specifications
    const pesoTexto =
      textoLimpio(prod.weight) ||
      buscarEnEspecificaciones(specs, /weight|peso/i) ||
      textoLimpio(objeto(prod.dimensions)?.weight)
    const dimTexto =
      textoLimpio(prod.dimensions) ||
      buscarEnEspecificaciones(specs, /package dimensions|product dimensions|item dimensions|dimension/i)

    const categorias = Array.isArray(prod.categories) ? prod.categories : []
    const categoria = textoLimpio(objeto(categorias[categorias.length - 1])?.name) || 'Amazon'

    const imagen =
      textoLimpio(objeto(prod.main_image)?.link) ||
      textoLimpio(prod.image) ||
      `https://placehold.co/600x600/0f766e/ffffff.png?text=${encodeURIComponent(limpio)}`

    const disponibilidad = objeto(buybox?.availability)
    const dispTipo = textoLimpio(disponibilidad?.type).toLowerCase()
    const dispRaw = textoLimpio(disponibilidad?.raw).toLowerCase()
    const disponible = dispTipo !== 'out_of_stock' && !/currently unavailable|out of stock/.test(dispRaw)

    const bullets = Array.isArray(prod.feature_bullets)
      ? prod.feature_bullets.map((b) => textoLimpio(b)).filter(Boolean)
      : []
    const descripcionCorta = (bullets.slice(0, 2).join(' · ') || textoLimpio(prod.description)).slice(0, 240)

    return {
      asin: limpio,
      titulo,
      precioUsd: redondearCentavos(precioUsd),
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
 * Fábrica de adaptador de catálogo según variables de entorno:
 * usa `ProveedorRainforest` solo cuando `providerName === 'rainforest'` y hay
 * `apiKey`; en cualquier otro caso entrega `ProveedorAmazonMock`.
 */
export function crearProveedorCatalogo(providerName?: string, apiKey?: string): ProveedorCatalogo {
  if ((providerName ?? '').trim().toLowerCase() === 'rainforest' && (apiKey ?? '').trim() !== '') {
    return new ProveedorRainforest(apiKey!.trim())
  }
  return new ProveedorAmazonMock()
}
