// ═══════════════════════════════════════════════════════════════════════════
// La geometría de los gráficos: dónde cae cada punto, cómo se corta el trazo
// en los huecos, el relleno bajo una línea, los tramos de una columna
// apilada, el arco de un anillo y las cuentas que hay detrás de un acumulado
// o de un embudo. Pura y sin React,
// para los gráficos y sus pruebas (lineas.test.ts y geometria.test.ts).
//
// El lienzo de las líneas es un SVG de 100 × 100 estirado a la caja: la x va
// en % del ancho y la y en % del alto, contada desde la base.
// ═══════════════════════════════════════════════════════════════════════════

/** Un valor que se puede pintar, o `null`. NaN, infinito o ausente son hueco. */
export function limpio(valor: number | null | undefined): number | null {
  return typeof valor === 'number' && Number.isFinite(valor) ? valor : null
}

/** La x de un punto, en % del ancho. Con uno solo, en el centro. */
export function xDe(i: number, n: number): number {
  return n <= 1 ? 50 : (i / (n - 1)) * 100
}

/**
 * El `d` de un `<path>` en un lienzo de 100 × 100 con la y hacia abajo,
 * cortado en cada hueco. `y` da la altura en % desde la base.
 *
 * Con `escalon`, cada valor se mantiene hasta el punto siguiente y sube ahí
 * en vertical: es la forma honesta de un acumulado, que no crece entre dos
 * días sino el día en que entra algo.
 */
export function trazo(
  valores: ReadonlyArray<number | null>,
  y: (v: number) => number,
  escalon = false,
): string {
  const n = valores.length
  const partes: Array<string> = []
  let abierto = false
  let anterior = ''

  valores.forEach((v, i) => {
    if (v === null) {
      abierto = false
      return
    }
    const x = redondo(xDe(i, n))
    const alto = redondo(100 - y(v))
    if (!abierto) partes.push(`M${x} ${alto}`)
    // En escalón, un tramo plano no sube: sin la `V` sobrante, un acumulado
    // de treinta días casi todos a cero no lleva treinta órdenes vacías.
    else if (escalon) partes.push(alto === anterior ? `H${x}` : `H${x} V${alto}`)
    else partes.push(`L${x} ${alto}`)
    abierto = true
    anterior = alto
  })

  return partes.join(' ')
}

/**
 * El relleno bajo una línea, hasta `base` (la altura del cero, en % desde
 * abajo). Un polígono por tramo con dato: el hueco corta también el relleno,
 * y un punto suelto no tiene área que rellenar.
 */
export function relleno(
  valores: ReadonlyArray<number | null>,
  y: (v: number) => number,
  base: number,
  escalon = false,
): string {
  const n = valores.length
  const suelo = redondo(100 - base)
  const poligonos: Array<string> = []

  let desde = -1
  for (let i = 0; i <= n; i++) {
    const hay = i < n && valores[i] !== null
    if (hay && desde < 0) desde = i
    if (!hay && desde >= 0) {
      const hasta = i - 1
      if (hasta > desde) {
        const tramo = valores.map((v, j) => (j >= desde && j <= hasta ? v : null))
        const linea = trazo(tramo, y, escalon).replace(/^M/, 'L')
        poligonos.push(
          `M${redondo(xDe(desde, n))} ${suelo} ${linea} L${redondo(xDe(hasta, n))} ${suelo} Z`,
        )
      }
      desde = -1
    }
  }

  return poligonos.join(' ')
}

function redondo(n: number): string {
  return String(Number(n.toFixed(3)))
}

/**
 * Los puntos sin vecino con dato a ningún lado. Un tramo de un solo punto
 * mide cero y no se ve, así que esos se pintan como un punto.
 */
export function puntosSueltos(valores: ReadonlyArray<number | null>): Array<number> {
  return valores.flatMap((v, i) =>
    v !== null && (valores[i - 1] ?? null) === null && (valores[i + 1] ?? null) === null
      ? [i]
      : [],
  )
}

/** El índice del último valor con dato, o -1. */
export function ultimoConDato(valores: ReadonlyArray<number | null>): number {
  for (let i = valores.length - 1; i >= 0; i--) if (valores[i] !== null) return i
  return -1
}

/** Qué punto cae bajo el puntero, con `fraccion` de 0 a 1 a lo ancho. */
export function indiceCercano(fraccion: number, n: number): number {
  if (n <= 1) return 0
  return Math.min(n - 1, Math.max(0, Math.round(fraccion * (n - 1))))
}

/** Qué columna cae bajo el puntero: las barras reparten el ancho a partes iguales. */
export function columnaBajo(fraccion: number, n: number): number {
  if (n <= 1) return 0
  return Math.min(n - 1, Math.max(0, Math.floor(fraccion * n)))
}

// ── Columnas apiladas ──────────────────────────────────────────────────────

/** Un tramo de una columna apilada, en % del alto del lienzo contado desde la base. */
export type Tramo = { serie: number; base: number; alto: number }

/**
 * Los tramos de una columna apilada, de abajo arriba, y dónde acaba la
 * columna (`cima`), que es donde se escribe su total.
 *
 * - Un valor de cero, negativo o sin dato no ocupa tramo: el sumando existe
 *   en el globo y en la tabla, pero no hay nada que pintar.
 * - Uno positivo mide al menos `suelo` (en % del alto): un céntimo de cargo
 *   sobre cien euros de consumo mediría medio píxel y no se vería.
 * - Nada se sale por arriba: si los suelos empujan la columna más allá del
 *   tope, el último tramo se recorta.
 */
export function apilar(
  valores: ReadonlyArray<number | null>,
  tope: number,
  suelo = 1.5,
): { tramos: Tramo[]; cima: number } {
  if (!(tope > 0)) return { tramos: [], cima: 0 }

  const tramos: Tramo[] = []
  let base = 0
  valores.forEach((v, serie) => {
    const valor = limpio(v)
    if (valor === null || valor <= 0 || base >= 100) return
    const alto = Math.min(Math.max((valor / tope) * 100, suelo), 100 - base)
    tramos.push({ serie, base: redondoNum(base), alto: redondoNum(alto) })
    base += alto
  })

  return { tramos, cima: redondoNum(base) }
}

function redondoNum(n: number): number {
  return Number(n.toFixed(3))
}

// ── Acumulados ─────────────────────────────────────────────────────────────

/**
 * Cada serie, sumada día a día: «lo que vencía y lo que entró, acumulado».
 *
 * Un hueco (`null`) sigue siendo hueco —la línea se corta y no se inventa un
 * valor para un día sin dato— pero no rompe la suma: el día siguiente con
 * dato sigue sumando desde donde iba. Cada serie suma por su lado.
 */
export function acumular<T extends { values: Array<number | null> }>(
  puntos: ReadonlyArray<T>,
): T[] {
  const sumas: Array<number> = []
  return puntos.map((p) => ({
    ...p,
    values: p.values.map((v, si) => {
      const valor = limpio(v)
      // Redondeado a la millonésima: sumar céntimos en coma flotante deja
      // colas como 0,30000000000000004 que acaban en el eje y en la tabla.
      sumas[si] = Number(((sumas[si] ?? 0) + (valor ?? 0)).toFixed(6))
      return valor === null ? null : sumas[si]
    }),
  }))
}

// ── El anillo ──────────────────────────────────────────────────────────────

/** La parte del anillo que se pinta: el valor recortado a [0, 1]. Sin dato, `null`. */
export function fraccionDelAnillo(valor: number | null | undefined): number | null {
  const v = limpio(valor)
  return v === null ? null : Math.min(1, Math.max(0, v))
}

/**
 * Dónde cae la fracción `f` de la vuelta sobre un círculo de `radio` con
 * centro en (`centro`, `centro`): empieza a las 12 y gira como un reloj.
 */
export function puntoDelAnillo(
  f: number,
  radio: number,
  centro: number,
): { x: number; y: number } {
  const angulo = f * 2 * Math.PI - Math.PI / 2
  return {
    x: Number((centro + radio * Math.cos(angulo)).toFixed(3)),
    y: Number((centro + radio * Math.sin(angulo)).toFixed(3)),
  }
}

// ── El embudo ──────────────────────────────────────────────────────────────

/**
 * El escalón donde se cae MÁS gente, contado en personas y no en porcentaje:
 * lo que hay que arreglar es el paso que pierde cuarenta, no el que pierde el
 * 40 % de doce. `-1` si ningún paso pierde a nadie.
 */
export function mayorCaida(valores: ReadonlyArray<number>): number {
  let peor = -1
  let caenPeor = 0
  for (let i = 1; i < valores.length; i++) {
    const caen = valores[i - 1] - valores[i]
    if (caen > caenPeor) {
      peor = i
      caenPeor = caen
    }
  }
  return peor
}
