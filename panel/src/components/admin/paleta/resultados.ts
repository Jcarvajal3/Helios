import { normalizar } from '@/features/admin/catalogo'
import { parteNacional, soloDigitos } from './consulta'
import type { Consulta } from './consulta'

// ═══════════════════════════════════════════════════════════════════════════
// El orden de lo que devuelve cada fuente.
//
// En la paleta manda lo que se tecleó: la cédula exacta antes que la que la
// contiene, y el nombre que empieza por lo buscado antes que el que lo lleva
// en medio. A igualdad, se respeta el orden que dio el servidor.
//
// Con un nombre, ese orden ya lo pone `admin_user_directory` (sin tildes y
// por parecido, desde 20260925134000). Con cifras, la base solo sabe que el
// teléfono las contiene: aquí se pone primero el que es ese teléfono.
//
// Módulo puro: se prueba en `resultados.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Cuántas filas enseña cada grupo de la paleta. */
export const POR_GRUPO = 5

/** Si cada palabra de `palabras` empieza alguna palabra de `texto`. */
function cadaPalabraEmpieza(texto: string, palabras: ReadonlyArray<string>): boolean {
  const suyas = texto.split(' ')
  return palabras.every((p) => suyas.some((s) => s.startsWith(p)))
}

/**
 * Cuánto se parece un nombre a lo buscado, de 0 a 100: el nombre entero, su
 * comienzo, el comienzo de una palabra, cada palabra por su comienzo en
 * cualquier orden, y por último el trozo suelto. Lo usan los locales, que se
 * filtran en el cliente; las personas ya llegan ordenadas así de la base.
 */
export function parecidoDeNombre(nombre: string, q: string): number {
  const n = normalizar(nombre)
  if (!n || !q) return 0
  if (n === q) return 100
  if (n.startsWith(q)) return 90
  if (n.split(' ').some((p) => p.startsWith(q))) return 80
  const palabras = q.split(' ').filter(Boolean)
  if (palabras.length > 1 && cadaPalabraEmpieza(n, palabras)) return 70
  if (q.length > 1 && n.includes(q)) return 50
  return 0
}

/** De mejor a peor; a igualdad, el orden de entrada. Sin los que dan cero. */
function ordenar<T>(filas: ReadonlyArray<T>, puntos: (fila: T) => number): T[] {
  return filas
    .map((fila, i) => ({ fila, i, p: puntos(fila) }))
    .filter((r) => r.p > 0)
    .sort((a, b) => b.p - a.p || a.i - b.i)
    .map((r) => r.fila)
}

// ── Personas ───────────────────────────────────────────────────────────────

export type PersonaBuscable = {
  fullName: string | null
  phone: string | null
  document: string | null
}

/**
 * Cuánto se parece una persona a lo buscado, por sus cifras. Nunca cero: el
 * servidor ya la encontró, así que algo suyo casa (por ejemplo, un trozo del
 * teléfono en medio), y se enseña al final en vez de esconderla.
 */
export function puntuarPersona(p: PersonaBuscable, c: Consulta): number {
  const d = soloDigitos(c.personas ?? '')
  if (!d) return 10
  const cedula = soloDigitos(p.document ?? '')
  const telefono = parteNacional(soloDigitos(p.phone ?? ''))
  if (cedula === d || telefono === d) return 100
  if (cedula.startsWith(d) || telefono.startsWith(d)) return 80
  if (cedula.includes(d) || telefono.includes(d)) return 60
  return 10
}

/** Con un nombre, el orden del servidor; con cifras, el de `puntuarPersona`. */
export function ordenarPersonas<T extends PersonaBuscable>(
  filas: ReadonlyArray<T>,
  c: Consulta,
): T[] {
  if (c.forma === 'texto') return [...filas]
  return ordenar(filas, (p) => puntuarPersona(p, c))
}

/**
 * Cuántas personas se piden. Con un nombre, las que se enseñan: vienen ya en
 * orden. Con cifras, más, porque aquí se reordenan y la buena puede no estar
 * entre las primeras que manda la base.
 */
export function personasAPedir(c: Consulta): number {
  return c.forma === 'texto' ? POR_GRUPO : 20
}

// ── Locales ────────────────────────────────────────────────────────────────

export type LocalBuscable = {
  name: string
  legalName: string | null
  taxId: string | null
  handle: string | null
}

/**
 * Cuánto se parece un local a lo buscado. La lista de locales se filtra
 * entera en el cliente, así que aquí sí vale cero: es el filtro.
 *
 * Con cifras solo se mira el RIF, y desde cuatro cifras. Con una sola letra,
 * solo los comienzos del nombre: «a» no puede traer todos los locales con una
 * a dentro.
 */
export function puntuarLocal(l: LocalBuscable, c: Consulta): number {
  const rif = soloDigitos(l.taxId ?? '')
  const d = c.digitos

  if (c.forma === 'rif' || c.forma === 'numero') {
    if (d.length < 4 || !rif) return 0
    if (rif === d) return 100
    if (rif.startsWith(d)) return 80
    return rif.includes(d) ? 60 : 0
  }
  if (c.forma !== 'texto') return 0

  const q = c.normal
  const nombre = parecidoDeNombre(l.name, q)
  if (nombre > 0) return nombre
  if (q.length < 2) return 0
  if (normalizar(l.legalName ?? '').includes(q)) return 40
  const usuario = q.replace(/^@/, '')
  if (usuario.length >= 2 && normalizar(l.handle ?? '').includes(usuario)) return 35
  if (d.length >= 4 && rif.includes(d)) return 30
  return 0
}

export function buscarLocales<T extends LocalBuscable>(
  locales: ReadonlyArray<T>,
  c: Consulta,
  limite = POR_GRUPO,
): T[] {
  return ordenar(locales, (l) => puntuarLocal(l, c)).slice(0, limite)
}

// ── Consumos ───────────────────────────────────────────────────────────────

/**
 * Solo el consumo con ESE número. `admin_charges` también casa por teléfono,
 * nombre y local; en la paleta el grupo Consumos es la búsqueda por orden, y
 * lo demás ya sale en Personas y Locales.
 */
export function delNumero<T extends { orderNumber: number | null }>(
  consumos: ReadonlyArray<T>,
  orden: number | null,
): T[] {
  if (orden === null) return []
  return consumos.filter((c) => c.orderNumber === orden)
}

// ── Pagos reportados ───────────────────────────────────────────────────────

export type PagoBuscable = { reference: string | null; createdAt: string }

/**
 * Cuánto encaja la referencia de un pago con la tecleada. Se compara por
 * cifras y por el final, que es lo que coincide entre lo que dicta el banco y
 * lo que la persona copió al reportar.
 */
export function puntuarPago(p: PagoBuscable, referencia: string): number {
  const suya = soloDigitos(p.reference ?? '')
  if (!suya || !referencia) return 0
  if (suya === referencia) return 100
  if (suya.endsWith(referencia)) return 80
  if (suya.includes(referencia)) return 60
  // Se dictó la referencia larga del banco y lo guardado es su final.
  if (suya.length >= 4 && referencia.endsWith(suya)) return 50
  return 0
}

/** Los que encajan, del más exacto al menos, y a igualdad el más reciente. */
export function buscarPagos<T extends PagoBuscable>(
  pagos: ReadonlyArray<T>,
  referencia: string | null,
  limite = POR_GRUPO,
): T[] {
  if (!referencia) return []
  return pagos
    .map((pago) => ({ pago, p: puntuarPago(pago, referencia) }))
    .filter((r) => r.p > 0)
    .sort((a, b) => b.p - a.p || b.pago.createdAt.localeCompare(a.pago.createdAt))
    .map((r) => r.pago)
    .slice(0, limite)
}

// ── Sin texto ──────────────────────────────────────────────────────────────

/**
 * Unas pocas pantallas de los equipos, repartidas: la primera de cada
 * equipo, luego la segunda, hasta `max`. Así el primero no se lleva los seis
 * huecos.
 */
export function atajosDeEspacios<T extends { espacio: string }>(
  pantallas: ReadonlyArray<T>,
  espacios: ReadonlyArray<string>,
  max = 6,
): T[] {
  const porEspacio = espacios.map((e) => pantallas.filter((p) => p.espacio === e))
  const salida: T[] = []
  for (let vuelta = 0; salida.length < max; vuelta++) {
    const deEstaVuelta = porEspacio
      .map((lista) => lista.at(vuelta))
      .filter((p): p is T => p !== undefined)
    if (deEstaVuelta.length === 0) break
    salida.push(...deEstaVuelta.slice(0, max - salida.length))
  }
  return salida
}
