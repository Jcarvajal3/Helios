import type { BadgeTone } from '@/components/ui'

// ═══════════════════════════════════════════════════════════════════════════
// Los colores de los gráficos. Todos salen de aquí y todos son variables:
// ni un hex, y el lima tampoco, que es de la acción principal y no de un dato.
//
// La serie que cuenta la historia va en el tono del área (`var(--area)`, que
// pone el marco en <main> o una tarjeta sobre sí misma); lo que da contexto,
// en gris. El estado —verde, ámbar, rojo— solo cuando algo ESTÁ bien o mal.
// ═══════════════════════════════════════════════════════════════════════════

/** Los papeles de un color en un gráfico. */
export const SERIE = {
  /** La serie protagonista. */
  principal: 'var(--area)',
  /** La serie contra la que se compara: una línea gris. */
  contexto: 'var(--color-panel-muted)',
  /** La pista de lo que no se ha llenado: un anillo, un medidor, un embudo. */
  vacio: 'var(--color-panel-control)',
  /** Lo que va detrás sin competir: el listón gris de una barra de contexto
   *  y la marca de un cero en la base. El gris de contexto al 30 %, que sobre
   *  la tarjeta queda un paso por encima de la pista. */
  tenue: 'color-mix(in oklab, var(--color-panel-muted) 30%, transparent)',
  /** Lo que todavía no ha pasado (un día futuro): más apagado que un cero. */
  futuro: 'var(--color-panel-raised)',
  /** El relleno bajo la línea protagonista: un lavado, nunca un bloque. */
  relleno: 'color-mix(in oklab, var(--area) 16%, transparent)',
} as const

/** El tono de una marca suelta: el área, el estado o gris. */
export type TonoDeMarca = 'area' | 'neutro' | BadgeTone

/**
 * El color de una marca por su tono. `brand` y `neutral` se pintan en gris:
 * el violeta de marca choca con el tono de Riesgo, y un gris no avisa de nada.
 */
export function colorDeTono(tono: TonoDeMarca): string {
  switch (tono) {
    case 'area':
      return SERIE.principal
    case 'success':
      return 'var(--color-success)'
    case 'warning':
      return 'var(--color-warning)'
    case 'error':
      return 'var(--color-error)'
    default:
      return SERIE.contexto
  }
}

// Cuánto se aclara el extremo claro (hacia el blanco) y cuánto se apaga el
// oscuro (hacia la tarjeta). Validados con `validate_palette.js --ordinal`
// en oscuro sobre #161616, con los cinco tonos de área y de 2 a 6 pasos:
// salto de luz ≥ 0,06 entre vecinos y el paso más oscuro a ≥ 2:1.
const ACLARADO = 55
const APAGADO = 50

/**
 * Un paso del tono del área, de −1 (claro) a 1 (oscuro); 0 es el tono tal
 * cual. Mezcla en oklab, que reparte la luz a pasos iguales.
 */
function paso(t: number): string {
  if (t === 0) return SERIE.principal
  if (t < 0) {
    return `color-mix(in oklab, var(--area) ${Math.round(100 + ACLARADO * t)}%, var(--color-on-surface))`
  }
  return `color-mix(in oklab, var(--area) ${Math.round(100 - APAGADO * t)}%, var(--color-panel-card))`
}

/**
 * `n` pasos del tono del área, de claro a oscuro, para lo que tiene orden:
 * los escalones de un embudo, los tramos de mora, las cohortes.
 *
 * El tono puro queda en medio y la rampa se abre a los dos lados según
 * cuántos pasos haya: con dos, apenas se separan del tono; con seis, llegan
 * a los extremos. Más de seis pasos ya no se distinguen entre vecinos.
 */
export function rampaOrdinal(n: number): string[] {
  if (n <= 0) return []
  if (n === 1) return [SERIE.principal]
  const abertura = Math.min(1, (n - 1) * 0.25)
  return Array.from({ length: n }, (_, i) => paso(-abertura + (2 * abertura * i) / (n - 1)))
}

/**
 * Los tramos de una columna apilada, de abajo arriba: el de abajo es el tono
 * del área tal cual y cada uno de encima, un paso más claro. Los pasos van a
 * 0,4 unos de otros, la separación validada de `rampaOrdinal(6)`, así que se
 * distinguen igual entre vecinos; del cuarto en adelante se quedan en el
 * extremo claro.
 */
export function rampaApilada(n: number): string[] {
  return Array.from({ length: Math.max(0, n) }, (_, i) => paso(-Math.min(1, i * 0.4)))
}

/**
 * El color de la serie `i` de `n`, con `principal` como protagonista.
 *
 * Con dos series, la otra es contexto y va en gris. Con más, las demás se
 * apagan hacia la tarjeta según lo lejos que estén de la protagonista: las
 * cohortes viejas se van quedando atrás, que es lo que son. Hasta cuatro
 * series cada paso se distingue del de al lado.
 */
export function tonoDeSerie(i: number, n: number, principal = 0): string {
  if (i === principal) return SERIE.principal
  if (n <= 2) return SERIE.contexto
  // Las demás, de la más cercana a la más lejana; a igual distancia, por orden.
  const otras = Array.from({ length: n }, (_, j) => j)
    .filter((j) => j !== principal)
    .sort((a, b) => Math.abs(a - principal) - Math.abs(b - principal) || a - b)
  return paso((otras.indexOf(i) + 1) / otras.length)
}
