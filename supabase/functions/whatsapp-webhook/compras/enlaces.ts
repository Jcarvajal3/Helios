// ═══════════════════════════════════════════════════════════════════════════
// Helios — Enlaces cortos de Amazon (amzn.to, a.co, amzn.eu, amzn.com)
//
// Un acortador no trae el ASIN: hay que seguir su redirección. Solo se pide a
// hosts de Amazon (nunca a un sitio cualquiera que pegue el médico), sin
// seguir la redirección sola (`redirect: 'manual'`) para revisar cada salto,
// con 4 s de espera por salto y a lo más 3 saltos.
// ═══════════════════════════════════════════════════════════════════════════

import { analizarEnlaceAmazon } from './amazon_parser.ts'

export const TIEMPO_ENLACE_MS = 4000
const MAXIMO_DE_SALTOS = 3

export type ResolverEnlace = (url: string) => Promise<string | null>

/**
 * Sigue un enlace corto de Amazon y devuelve la URL final que trae un ASIN
 * (la que dejó el último salto), o null si no se pudo resolver.
 */
export async function resolverEnlaceCorto(
  url: string,
  fetchFn: typeof fetch = fetch,
  tiempoMs: number = TIEMPO_ENLACE_MS,
): Promise<string | null> {
  let actual = url
  for (let salto = 0; salto < MAXIMO_DE_SALTOS; salto++) {
    const enlace = analizarEnlaceAmazon(actual)
    // Solo hosts de Amazon y por https: nada de pedirle a un sitio cualquiera.
    if (!enlace || !actual.toLowerCase().startsWith('https://')) return null
    if (enlace.asin) return actual
    try {
      const res = await fetchFn(actual, {
        method: 'GET',
        redirect: 'manual',
        signal: AbortSignal.timeout(tiempoMs),
        headers: { 'User-Agent': 'Mozilla/5.0 (compatible; HeliosBot/1.0)' },
      })
      await res.body?.cancel().catch(() => undefined)
      const destino = res.headers.get('location')
      if (res.status < 300 || res.status >= 400 || !destino) return null
      actual = new URL(destino, actual).toString()
    } catch {
      // Sin respuesta a tiempo o error de red: no se puede resolver.
      return null
    }
  }
  const final = analizarEnlaceAmazon(actual)
  return final?.asin ? actual : null
}
