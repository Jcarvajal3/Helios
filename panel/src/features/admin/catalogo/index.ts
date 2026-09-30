import { ajustes } from './ajustes'
import { caja } from './caja'
import { cobranza } from './cobranza'
import { directorio } from './directorio'
import { gerencia } from './gerencia'
import { glosario } from './glosario'
import { inicio } from './inicio'
import { metricas } from './metricas'
import { riesgo } from './riesgo'
import type { Accion, Cifra, Entrada, Pantalla, Termino } from './tipos'

export type {
  Accion,
  Ambito,
  Cifra,
  Destino,
  Entrada,
  Pantalla,
  RutaAdmin,
  Termino,
  TipoEntrada,
} from './tipos'

/*
 * El catálogo del super admin: cada pantalla, acción, cifra y término, con su
 * nombre, dónde vive y adónde lleva. Es la fuente del menú y de la búsqueda.
 *
 * Para añadir algo, se escribe en el archivo de su espacio (o en `glosario.ts`
 * si es un término) y ya está: el tipo comprueba la ruta y sus parámetros, y
 * `catalogo.test.ts` que el id no se repita. Una pantalla nueva sale en el
 * menú cuando se añade su id a `config/navigation.ts`.
 *
 * Lo de Métricas va en `metricas/`: la pantalla y sus pestañas en
 * `pantallas.ts`, y lo de cada pestaña en su archivo, que es de su dueño.
 * Las cifras que vivían en Resumen, Crecimiento, Riesgo de crédito y Dinero
 * siguen en el archivo de su equipo, con el destino ya en su pestaña.
 */

const TODAS = [
  ...inicio,
  // Antes que las demás: la primera pantalla con una ruta es la dueña de esa
  // ruta (`dondeVive` de la paleta, el mapa del asistente), y la de
  // `/admin/metricas` es Métricas, no una de sus pestañas.
  ...metricas,
  ...cobranza,
  ...caja,
  ...riesgo,
  ...gerencia,
  ...directorio,
  ...ajustes,
  ...glosario,
] as const

/** Todo el catálogo, en el orden de los espacios. */
export const CATALOGO: ReadonlyArray<Entrada> = TODAS

/** El id de cualquier pantalla del catálogo. Un id mal escrito no compila. */
export type IdPantalla = Extract<(typeof TODAS)[number], { tipo: 'pantalla' }>['id']

export const PANTALLAS: ReadonlyArray<Pantalla> = CATALOGO.filter(
  (e): e is Pantalla => e.tipo === 'pantalla',
)

/** La pantalla de ese id. Siempre existe: el tipo del id lo garantiza. */
export function pantalla(id: IdPantalla): Pantalla {
  const encontrada = PANTALLAS.find((p) => p.id === id)
  if (!encontrada) throw new Error(`No hay ninguna pantalla con el id «${id}»`)
  return encontrada
}

// ── La búsqueda ────────────────────────────────────────────────────────────

/** Sin tildes, sin mayúsculas y con los espacios de más colapsados. */
export function normalizar(texto: string): string {
  return texto
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim()
}

/** El texto largo de cada tipo: la frase que explica una cifra o un término. */
function explicacion(e: Entrada): string {
  if (e.tipo === 'cifra') return e.que
  if (e.tipo === 'termino') return e.definicion
  return ''
}

/**
 * Si cada palabra buscada empieza alguna palabra de `texto`, en cualquier
 * orden: «pago reportado» encaja con «Pagos reportados» y «reportados pag»
 * también. Es como se teclea con prisa: la mitad de cada palabra.
 */
function cadaPalabraEmpieza(texto: string, palabras: ReadonlyArray<string>): boolean {
  const suyas = texto.split(' ')
  return palabras.every((p) => suyas.some((s) => s.startsWith(p)))
}

/**
 * Cuánto se parece una entrada a lo buscado. Cero es que no se parece.
 *
 * El orden de los pesos es lo que importa, no su valor: el título manda sobre
 * los sinónimos, y los sinónimos sobre la descripción. Dentro del título, que
 * empiece por lo buscado pesa más que una palabra que empiece por ello, y esa
 * más que contenerlo en cualquier sitio.
 *
 * Con menos de tres letras solo cuentan los comienzos: «a» o «de» están
 * dentro de casi todo y enterrarían lo que se busca debajo de medio catálogo.
 */
function puntuar(e: Entrada, q: string, palabras: ReadonlyArray<string>): number {
  const varias = palabras.length > 1
  const corta = q.length < 3
  const titulo = normalizar(e.titulo)
  if (titulo === q) return 120
  if (titulo.startsWith(q)) return 100
  if (titulo.split(' ').some((p) => p.startsWith(q))) return 85
  if (varias && cadaPalabraEmpieza(titulo, palabras)) return 78
  if (!corta && titulo.includes(q)) return 70

  const sinonimos = e.sinonimos.map(normalizar)
  if (sinonimos.some((s) => s === q)) return 65
  if (sinonimos.some((s) => s.startsWith(q))) return 60
  if (varias && sinonimos.some((s) => cadaPalabraEmpieza(s, palabras))) return 55
  if (!corta && sinonimos.some((s) => s.includes(q))) return 50

  if (corta) return 0

  const descripcion = normalizar(e.descripcion)
  if (descripcion.includes(q)) return 30
  if (normalizar(explicacion(e)).includes(q)) return 20

  // Varias palabras que no aparecen juntas: cuenta si están todas en algún
  // sitio de la entrada, y pesa menos que cualquier coincidencia seguida.
  if (palabras.length > 1) {
    const todo = [titulo, ...sinonimos, descripcion].join(' ')
    if (palabras.every((p) => todo.includes(p))) return 10
  }

  return 0
}

export type ResultadoBusqueda = {
  pantallas: Pantalla[]
  acciones: Accion[]
  cifras: Cifra[]
  terminos: Termino[]
  /** Cuántas entradas encajaron en total, antes de recortar cada grupo. */
  total: number
}

/**
 * Busca en todo el catálogo y devuelve lo encontrado agrupado por tipo, cada
 * grupo ordenado de mejor a peor.
 *
 * `limite` es el máximo POR GRUPO (5 por defecto): la paleta enseña unas pocas
 * de cada clase, no las veinte primeras pantallas y ninguna acción.
 */
export function buscarEnCatalogo(
  texto: string,
  opciones: OpcionesDeBusqueda = {},
): ResultadoBusqueda {
  return buscarEn(CATALOGO, texto, opciones)
}

export type OpcionesDeBusqueda = { limite?: number }

/**
 * La búsqueda sobre cualquier lista de entradas. `buscarEnCatalogo` la usa con
 * el catálogo entero; las pruebas, con entradas inventadas, para que el orden
 * se compruebe sin depender de lo que cada equipo escriba en su archivo.
 */
export function buscarEn(
  entradas: ReadonlyArray<Entrada>,
  texto: string,
  { limite = 5 }: OpcionesDeBusqueda = {},
): ResultadoBusqueda {
  const resultado: ResultadoBusqueda = {
    pantallas: [],
    acciones: [],
    cifras: [],
    terminos: [],
    total: 0,
  }
  const q = normalizar(texto)
  if (!q) return resultado

  const palabras = q.split(' ').filter((p) => p.length > 1)

  const encontradas = entradas
    .map((entrada) => ({ entrada, puntos: puntuar(entrada, q, palabras) }))
    .filter((r) => r.puntos > 0)
    // A igualdad de puntos, el título más corto, que es el que más se parece
    // a lo tecleado; y luego el orden del catálogo, que es estable.
    .sort((a, b) => b.puntos - a.puntos || a.entrada.titulo.length - b.entrada.titulo.length)
    .map((r) => r.entrada)

  resultado.total = encontradas.length
  for (const e of encontradas) {
    if (e.tipo === 'pantalla' && resultado.pantallas.length < limite) resultado.pantallas.push(e)
    if (e.tipo === 'accion' && resultado.acciones.length < limite) resultado.acciones.push(e)
    if (e.tipo === 'cifra' && resultado.cifras.length < limite) resultado.cifras.push(e)
    if (e.tipo === 'termino' && resultado.terminos.length < limite) resultado.terminos.push(e)
  }
  return resultado
}
