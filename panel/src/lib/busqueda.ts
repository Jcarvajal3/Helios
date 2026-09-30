// ═══════════════════════════════════════════════════════════════════════════
// Validadores para el `validateSearch` de las rutas.
//
// Lo que llega por la URL lo escribe cualquiera: un enlace viejo, uno copiado
// a medias, uno que alguien editó a mano. Castearlo tal cual —`search.tramo
// as Tramo`— es la forma de que un `?tramo=foo` tire la pantalla entera al
// buscar `labels['foo'].full`. Cada validador devuelve el valor bueno o
// `undefined`, y `undefined` es «como si no viniera»: la pantalla usa su
// valor por defecto y la URL no se reescribe.
//
//   validateSearch: (s: Record<string, unknown>) => ({
//     tramo: unoDe(TRAMOS, s.tramo),
//     desde: comoDia(s.desde),
//     q: comoTexto(s.q),
//     dias: comoEntero(s.dias, { min: 1, max: 366 }),
//     importar: comoBooleano(s.importar),
//     persona: comoId(s.persona),
//   })
//
// El router lee la URL con `JSON.parse` cuando puede, así
// que `?dias=30` llega como el NÚMERO 30 y `?q=1043` también. Por eso
// `unoDe` y `comoTexto` aceptan un número y lo comparan como texto.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Uno de una lista cerrada de valores, con su tipo.
 *
 * `find` y no `includes` + `as`: el valor que devuelve sale de la lista, así
 * que el tipo es el de la lista sin tener que prometérselo al compilador.
 * Un número se compara por su texto: `?dias=30` llega como 30 y la lista
 * dice '30'.
 */
export function unoDe<T extends string>(valores: readonly T[], v: unknown): T | undefined {
  const texto = typeof v === 'number' && Number.isFinite(v) ? String(v) : v
  return valores.find((valor) => valor === texto)
}

/**
 * Un día de calendario, 'YYYY-MM-DD', y que exista: «2026-02-30» no pasa.
 *
 * El formato solo no basta. Un día imposible llega hasta la consulta y lo que
 * vuelve es un error de Postgres en una pantalla que solo quería filtrar.
 */
export function comoDia(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined
  const partes = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v)
  if (!partes) return undefined

  const [anio, mes, dia] = [Number(partes[1]), Number(partes[2]), Number(partes[3])]
  const fecha = new Date(Date.UTC(anio, mes - 1, dia))
  const existe =
    fecha.getUTCFullYear() === anio && fecha.getUTCMonth() === mes - 1 && fecha.getUTCDate() === dia

  return existe ? v : undefined
}

/**
 * Un texto libre —una búsqueda, una nota— sin espacios de sobra.
 *
 * Vacío es `undefined`, para que `?q=` no deje un filtro fantasma. Lo que pase
 * de `max` se recorta en vez de descartarse: un buscador pegado de más sigue
 * buscando por el principio. Un número vale como texto: buscar la orden
 * «1043» llega por la URL como 1043.
 */
export function comoTexto(v: unknown, max = 120): string | undefined {
  const texto = typeof v === 'number' && Number.isFinite(v) ? String(v) : v
  if (typeof texto !== 'string') return undefined
  const limpio = texto.trim().slice(0, max).trim()
  return limpio === '' ? undefined : limpio
}

/**
 * Un entero dentro de un rango. Acepta el número o su texto («30»).
 *
 * Fuera de rango es `undefined` y no el extremo: `?dias=9999` es un enlace
 * roto, y quien lo abre tiene que ver la vista normal, no una de 366 días que
 * nadie pidió.
 */
export function comoEntero(
  v: unknown,
  { min = Number.MIN_SAFE_INTEGER, max = Number.MAX_SAFE_INTEGER }: { min?: number; max?: number } = {},
): number | undefined {
  let n: number
  if (typeof v === 'number') n = v
  else if (typeof v === 'string' && /^\s*-?\d+\s*$/.test(v)) n = Number(v)
  else return undefined

  if (!Number.isSafeInteger(n) || n < min || n > max) return undefined
  return n === 0 ? 0 : n
}

/**
 * Una bandera: `true` si viene encendida (`true`, `'true'`, `'1'`) y
 * `undefined` en cualquier otro caso.
 *
 * No devuelve `false` a propósito: una bandera apagada es la que no está, y
 * así la URL no se llena de `?importar=false`.
 */
export function comoBooleano(v: unknown): true | undefined {
  return v === true || v === 'true' || v === '1' || v === 1 ? true : undefined
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/**
 * El id de una fila (uuid), en minúsculas.
 *
 * En minúsculas para que el mismo id escrito de dos maneras no sean dos
 * claves de caché distintas y dos viajes al servidor.
 */
export function comoId(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined
  const limpio = v.trim()
  return UUID.test(limpio) ? limpio.toLowerCase() : undefined
}
