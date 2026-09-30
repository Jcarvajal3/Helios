import { comoFila, comoLista, numero, numeroONulo, texto, textoONulo } from '@/lib/json'
import { leerErrorDelFlujo } from './errores'
import type { ErrorDelAsistente } from './errores'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que manda la función `admin-asistente`, evento a evento, ya validado.
//
// La función habla en `text/event-stream`: cada evento lleva su tipo y un JSON
// en `data`. Lo que llega del servidor es `unknown` hasta que se mira, y un
// gráfico con un punto sin valor o un enlace sin ruta no se pinta a medias: se
// descarta. Módulo puro; se prueba en `sse.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export type EstadoHerramienta = 'consultando' | 'hecho' | 'error'

/** Una consulta a la base, con el rótulo que se lee mientras corre. */
export type Herramienta = { id: string; rotulo: string; estado: EstadoHerramienta }

/** Un valor de `search` que el router sabe escribir en la URL. */
export type ValorDeBusqueda = string | number | boolean

/** Un enlace a una pantalla del panel, tal como lo propone el asistente. */
export type Enlace = { titulo: string; ruta: string; search?: Record<string, ValorDeBusqueda> }

export type Unidad = 'eur' | 'numero' | 'pct'

export type TipoGrafico = 'barras' | 'lineas' | 'reparto'

export type PuntoGrafico = { etiqueta: string; valor: number; valor2?: number }

export type Grafico = {
  tipo: TipoGrafico
  titulo: string
  unidad: Unidad
  puntos: PuntoGrafico[]
  leyenda?: { valor: string; valor2?: string }
}

/** La unidad de una columna: las de las cifras, más texto y fecha. */
export type UnidadDeColumna = Unidad | 'texto' | 'fecha'

export type ColumnaTabla = { clave: string; rotulo: string; unidad?: UnidadDeColumna }

/** Una celda: lo que no sea texto ni número llega como `null` y se pinta «—». */
export type Celda = string | number | null

export type Tabla = {
  titulo: string
  columnas: ColumnaTabla[]
  filas: Array<Record<string, Celda>>
}

/** Los tokens de la respuesta: lo que la bitácora y la factura cuentan. */
export type Fin = { modelo: string; entrada: number; salida: number; cacheLeida: number }

export type EventoAsistente =
  | { tipo: 'texto'; delta: string }
  | { tipo: 'herramienta'; herramienta: Herramienta }
  | { tipo: 'enlace'; enlace: Enlace }
  | { tipo: 'grafico'; grafico: Grafico }
  | { tipo: 'tabla'; tabla: Tabla }
  | { tipo: 'fin'; fin: Fin }
  | { tipo: 'error'; error: ErrorDelAsistente }

/** El tope de filas de una tabla. El servidor ya lo aplica; aquí no se fía. */
export const FILAS_MAXIMAS = 50

const UNIDADES: ReadonlyArray<Unidad> = ['eur', 'numero', 'pct']
const UNIDADES_DE_COLUMNA: ReadonlyArray<UnidadDeColumna> = [...UNIDADES, 'texto', 'fecha']
const TIPOS_GRAFICO: ReadonlyArray<TipoGrafico> = ['barras', 'lineas', 'reparto']
const ESTADOS: ReadonlyArray<EstadoHerramienta> = ['consultando', 'hecho', 'error']

/** Un valor de la lista cerrada, o `null`. */
function unoDe<T extends string>(valores: ReadonlyArray<T>, v: unknown): T | null {
  return valores.find((x) => x === v) ?? null
}

/** Una clave de `search` razonable: letras, cifras y guion bajo. */
const CLAVE_DE_BUSQUEDA = /^[A-Za-z][A-Za-z0-9_]{0,39}$/

/**
 * El `search` de un enlace: solo valores sueltos. Un objeto o una lista no se
 * dejan pasar; la ruta de destino valida después lo que sí pasa.
 */
export function leerBusqueda(v: unknown): Record<string, ValorDeBusqueda> | undefined {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return undefined
  const salida: Record<string, ValorDeBusqueda> = {}
  for (const [clave, valor] of Object.entries(v)) {
    if (!CLAVE_DE_BUSQUEDA.test(clave)) continue
    if (typeof valor === 'string' || typeof valor === 'boolean') salida[clave] = valor
    else if (typeof valor === 'number' && Number.isFinite(valor)) salida[clave] = valor
  }
  return Object.keys(salida).length > 0 ? salida : undefined
}

export function leerHerramienta(v: unknown): Herramienta | null {
  const f = comoFila(v)
  const id = textoONulo(f.id)
  const rotulo = textoONulo(f.rotulo)
  const estado = unoDe(ESTADOS, f.estado)
  if (!id || !rotulo || !estado) return null
  return { id, rotulo, estado }
}

export function leerEnlace(v: unknown): Enlace | null {
  const f = comoFila(v)
  const titulo = textoONulo(f.titulo)
  const ruta = textoONulo(f.ruta)
  if (!titulo || !ruta) return null
  const search = leerBusqueda(f.search)
  return search ? { titulo, ruta, search } : { titulo, ruta }
}

function leerPunto(v: unknown): PuntoGrafico | null {
  const f = comoFila(v)
  const etiqueta = textoONulo(f.etiqueta)
  const valor = numeroONulo(f.valor)
  if (etiqueta === null || valor === null) return null
  const valor2 = numeroONulo(f.valor2)
  return valor2 === null ? { etiqueta, valor } : { etiqueta, valor, valor2 }
}

/**
 * Un gráfico. Un punto ilegible invalida el gráfico entero: dibujarlo sin ese
 * punto enseñaría una serie que no es la que se leyó de la base.
 */
export function leerGrafico(v: unknown): Grafico | null {
  const f = comoFila(v)
  const tipo = unoDe(TIPOS_GRAFICO, f.tipo)
  const unidad = unoDe(UNIDADES, f.unidad)
  const titulo = textoONulo(f.titulo)
  if (!tipo || !unidad || !titulo) return null

  const crudos = comoLista(f.puntos)
  const puntos = crudos.map(leerPunto)
  if (puntos.length === 0 || puntos.some((p) => p === null)) return null
  const validos = puntos.filter((p): p is PuntoGrafico => p !== null)

  const l = comoFila(f.leyenda)
  const valor = textoONulo(l.valor)
  const valor2 = textoONulo(l.valor2)
  const leyenda = valor ? (valor2 ? { valor, valor2 } : { valor }) : undefined

  return leyenda
    ? { tipo, titulo, unidad, puntos: validos, leyenda }
    : { tipo, titulo, unidad, puntos: validos }
}

function leerColumna(v: unknown): ColumnaTabla | null {
  const f = comoFila(v)
  const clave = textoONulo(f.clave)
  const rotulo = textoONulo(f.rotulo)
  if (!clave || !rotulo) return null
  const unidad = unoDe(UNIDADES_DE_COLUMNA, f.unidad)
  return unidad ? { clave, rotulo, unidad } : { clave, rotulo }
}

function leerCelda(v: unknown): Celda {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v === 'string') return v
  if (typeof v === 'boolean') return v ? 'Sí' : 'No'
  return null
}

export function leerTabla(v: unknown): Tabla | null {
  const f = comoFila(v)
  const titulo = textoONulo(f.titulo)
  const columnas = comoLista(f.columnas)
    .map(leerColumna)
    .filter((c): c is ColumnaTabla => c !== null)
  if (!titulo || columnas.length === 0) return null

  const filas = comoLista(f.filas)
    .slice(0, FILAS_MAXIMAS)
    .map((cruda) => {
      const fila = comoFila(cruda)
      const salida: Record<string, Celda> = {}
      for (const c of columnas) salida[c.clave] = leerCelda(fila[c.clave])
      return salida
    })
  return { titulo, columnas, filas }
}

export function leerFin(v: unknown): Fin {
  const f = comoFila(v)
  return {
    modelo: texto(f.modelo),
    entrada: numero(f.entrada),
    salida: numero(f.salida),
    cacheLeida: numero(f.cacheLeida),
  }
}

/**
 * Un evento del servidor, ya con su tipo. Un tipo desconocido o unos datos
 * que no encajan devuelven `null` y se ignoran: una versión nueva de la
 * función puede mandar eventos que este panel todavía no sabe pintar.
 */
export function leerEvento(tipo: string, datos: unknown): EventoAsistente | null {
  switch (tipo) {
    case 'texto': {
      const delta = comoFila(datos).delta
      return typeof delta === 'string' ? { tipo, delta } : null
    }
    case 'herramienta': {
      const herramienta = leerHerramienta(datos)
      return herramienta ? { tipo, herramienta } : null
    }
    case 'enlace': {
      const enlace = leerEnlace(datos)
      return enlace ? { tipo, enlace } : null
    }
    case 'grafico': {
      const grafico = leerGrafico(datos)
      return grafico ? { tipo, grafico } : null
    }
    case 'tabla': {
      const tabla = leerTabla(datos)
      return tabla ? { tipo, tabla } : null
    }
    case 'fin':
      return { tipo, fin: leerFin(datos) }
    case 'error':
      // Con o sin `codigo`: la función nueva y la desplegada conviven un tiempo.
      return { tipo, error: leerErrorDelFlujo(datos) }
    default:
      return null
  }
}
