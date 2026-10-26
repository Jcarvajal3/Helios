import type { CSSProperties } from 'react'

import { formatPorcentaje } from '@/components/ui'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que comparten los gráficos del panel: la forma de los datos, la escala,
// dónde se ancla una etiqueta y la tabla con los números.
//
// Vive aparte para que las barras (charts/barras.tsx) y las líneas
// (charts/lineas.tsx) lo usen sin importarse la una a la otra. Lo público se
// importa de `@/components/charts`, que lo reexporta.
// ═══════════════════════════════════════════════════════════════════════════

/** Dónde se pinta algo que va encima de un punto: el estilo y la clase. */
export type Anclaje = { style: CSSProperties; clase: string }

// ── Los datos que come un gráfico ──────────────────────────────────────────

/**
 * Una serie.
 *
 * Con dos series el orden NO es decorativo: una es el contexto contra el que
 * se mide —el listón gris, la línea gris— y la otra la que cuenta la
 * historia, en el tono del área. En `BarChart` la protagonista es la última;
 * en `LineChart`, la de `principal` (la primera, si no se dice).
 */
export type ChartSeries = {
  key: string
  label: string
}

export type ChartPoint = {
  key: string
  /** Lo que se lee en el eje de abajo y en el globo: '18/09/26', '21:00'. Ya
   *  formateado: aquí no se sabe si es un día o una hora. */
  label: string
  /** Un valor por serie, en el orden de `series`. */
  values: Array<number>
  /** El detalle que acompaña a la cifra: '3 órdenes', '5 cuotas'. Sale en el
   *  globo y en su columna de la tabla. */
  note?: string
}

/**
 * Un punto de una línea. Igual que `ChartPoint`, pero un valor puede ser
 * `null`: «no hay dato» —el día no ha llegado, la consulta no lo trae—, que
 * NO es un cero. La línea se corta ahí en vez de caer a la base.
 */
export type LinePoint = Omit<ChartPoint, 'values'> & { values: Array<number | null> }

// ── La escala ──────────────────────────────────────────────────────────────

/**
 * De un máximo cualquiera a una escala con números redondos.
 *
 * Sin esto, el eje de un día de €437,20 diría «437,20 / 328,90 / 218,60», que
 * son cuatro cifras que nadie puede usar para estimar una barra a ojo. Con
 * esto dice «0 / 150 / 300 / 450», y de ahí sí se lee que una barra vale unos
 * trescientos y pico.
 *
 * El tope queda SIEMPRE por encima o igual al máximo real, así que ninguna
 * barra se sale de la caja.
 */
export function escalaBonita(
  max: number,
  /**
   * El eje cuenta COSAS y no dinero.
   *
   * Sin esto, doce registros daban un paso de 2,5 y el eje decía
   * «13 / 10 / 8 / 5 / 3 / 0»: seis números de los que cuatro no son
   * múltiplos de nada y ninguno existe —no hay 2,5 personas—. Con pasos
   * enteros dice «15 / 10 / 5 / 0», que es de donde se puede estimar una
   * barra a ojo.
   */
  entera = false,
): { tope: number; marcas: Array<number> } {
  if (!Number.isFinite(max) || max <= 0) return { tope: 0, marcas: [0] }

  const magnitud = 10 ** Math.floor(Math.log10(max))
  const pasos = [0.1, 0.15, 0.2, 0.25, 0.5, 1, 1.5, 2, 2.5, 5]
    .map((f) => f * magnitud)
    .filter((p) => !entera || Number.isInteger(p))

  // Se prueban todos los pasos y gana el que deja MENOS aire por encima de la
  // barra más alta, con entre tres y cinco divisiones. Elegir el paso con una
  // fórmula cerrada —lo que hacía la primera versión— dejaba un máximo de
  // €420 contra un tope de €600: la barra más alta se quedaba a dos tercios
  // del alto y el gráfico parecía medio vacío sin estarlo.
  let mejor: { paso: number; divisiones: number; tope: number } | null = null
  for (const paso of pasos) {
    const divisiones = Math.ceil(max / paso)
    if (divisiones < 3 || divisiones > 5) continue
    const tope = divisiones * paso
    if (!mejor || tope < mejor.tope) mejor = { paso, divisiones, tope }
  }

  // Con pasos de 0,1× a 5× de la magnitud del máximo siempre cae alguno en el
  // rango, pero un respaldo cuesta una línea y evita un gráfico en blanco.
  const { paso, divisiones, tope } = mejor ?? {
    paso: magnitud,
    divisiones: Math.ceil(max / magnitud),
    tope: Math.ceil(max / magnitud) * magnitud,
  }

  // Multiplicando y no acumulando: sumar 0,1 diez veces no da 1 en coma
  // flotante, y la última marca acabaría en 0,9999999999.
  const marcas = Array.from({ length: divisiones + 1 }, (_, i) =>
    Number((i * paso).toFixed(6)),
  )

  // El tope sale de la última marca y no del producto: `3 * 0.15` es
  // 0.45000000000000007, y con ese divisor la barra más alta mide un
  // 99,999 % — la línea de arriba de la rejilla y la punta de la barra dejan
  // de coincidir por medio píxel justo donde más se nota.
  return { tope: marcas[divisiones] ?? tope, marcas }
}

/**
 * La escala de `escalaBonita`, pero admitiendo negativos.
 *
 * Una línea puede bajar de cero —la caja neta de un día malo— y una escala
 * que empieza en 0 la dibujaría por debajo de la caja. Sin negativos es
 * `escalaBonita` tal cual. Con negativos, el paso sale del mayor de los dos
 * lados y se repite hacia abajo, así que el 0 cae siempre en una marca.
 */
export function escalaConSigno(
  min: number,
  max: number,
  entera = false,
): { suelo: number; tope: number; marcas: Array<number> } {
  const alto = Number.isFinite(max) ? Math.max(max, 0) : 0
  const bajo = Number.isFinite(min) ? Math.min(min, 0) : 0
  if (bajo === 0) return { suelo: 0, ...escalaBonita(alto, entera) }

  const base = escalaBonita(Math.max(alto, -bajo), entera)
  const paso = base.marcas[1] ?? base.tope
  const abajo = Math.ceil(-bajo / paso - 1e-9)
  const arriba = alto > 0 ? Math.ceil(alto / paso - 1e-9) : 0

  const marcas = Array.from({ length: abajo + arriba + 1 }, (_, i) =>
    Number(((i - abajo) * paso).toFixed(6)),
  )
  return { suelo: marcas[0] ?? 0, tope: marcas.at(-1) ?? 0, marcas }
}

/**
 * Qué puntos llevan etiqueta en el eje de abajo.
 *
 * Nunca todos: treinta fechas seguidas se solapan y acaban siendo una mancha
 * gris. Siete repartidos —con el primero y el último siempre puestos— dan una
 * referencia cada cinco barras, que es lo que hace falta para situar un pico.
 */
export function indicesEspaciados(n: number, cuantos: number): Array<number> {
  if (n <= 0) return []
  if (n <= cuantos) return Array.from({ length: n }, (_, i) => i)

  return Array.from({ length: cuantos }, (_, k) =>
    Math.round((k * (n - 1)) / (cuantos - 1)),
  )
}

/**
 * Los puntos con etiqueta en el eje de abajo, y en qué anchos sale cada una:
 * siete desde 640 px y cuatro en el teléfono. En un lienzo de 250 px, siete
 * fechas como «12 oct» se montaban unas encima de otras. Va en clases y no
 * midiendo el lienzo para que salga igual del servidor.
 */
export function etiquetasDelEje(n: number): Array<{ i: number; clase: string }> {
  const anchas = indicesEspaciados(n, 7)
  const estrechas = indicesEspaciados(n, 4)
  return [...new Set([...anchas, ...estrechas])]
    .sort((a, b) => a - b)
    .map((i) => ({
      i,
      clase: !estrechas.includes(i) ? 'max-sm:hidden' : !anchas.includes(i) ? 'sm:hidden' : '',
    }))
}

/**
 * Dónde se ancla algo que va encima de la barra `i`.
 *
 * Una etiqueta centrada sobre la primera barra de treinta se sale de la caja
 * por la izquierda: su centro está en el 1,6 % del ancho y el texto mide
 * sesenta píxeles. Las de los extremos se pegan al borde en vez de centrarse.
 */
export function anclaje(i: number, n: number): Anclaje {
  return anclajeEn(((i + 0.5) / n) * 100)
}

/** Lo mismo que `anclaje`, desde la posición en tanto por ciento. Las líneas
 *  ponen sus puntos en los bordes y no en el centro de una columna. */
export function anclajeEn(centro: number): Anclaje {
  if (centro < 8) return { style: { left: 0 }, clase: '' }
  if (centro > 92) return { style: { right: 0 }, clase: '' }
  return { style: { left: `${centro}%` }, clase: '-translate-x-1/2' }
}

// ── Las partes de un todo ──────────────────────────────────────────────────

/**
 * Qué parte del total es una cifra, escrita: '62 %', y con un decimal por
 * debajo del 1 %, que un 0,4 % no es un 0 %. Sin total, '—'. Es lo que dicen
 * los globos de una barra al 100 %, de un reparto y de un embudo.
 */
export function parteDelTotal(valor: number, total: number): string {
  if (!(total > 0) || !Number.isFinite(valor)) return '—'
  const pct = (valor / total) * 100
  return formatPorcentaje(pct, pct > 0 && pct < 1 ? 1 : 0)
}

// ── La tabla ───────────────────────────────────────────────────────────────

function celda(valor: number | null, format: (value: number) => string): string {
  return valor === null ? '—' : format(valor)
}

/**
 * LOS NÚMEROS, SIN RATÓN.
 *
 * Es lo que convierte al globo en una ayuda y no en una condición: quien
 * quiere el número exacto del día 12 pulsa el botón de tabla de la cabecera
 * (`ChartCard`) y lo lee. Un `null` sale como «—»: no hay dato, que no es un
 * cero.
 */
export function TablaDelGrafico({
  series,
  points,
  format,
  ejeLabel,
  unidadLabel,
}: {
  series: Array<ChartSeries>
  points: Array<LinePoint>
  format: (value: number) => string
  ejeLabel: string
  unidadLabel?: string
}) {
  const cabecera = 'px-3 py-2 type-panel-caption font-semibold text-on-surface-variant'
  return (
    <div className="max-h-72 overflow-y-auto">
      <table className="w-full border-collapse">
        <thead className="sticky top-0 bg-panel-card">
          <tr className="border-b border-panel-hairline-strong">
            <th scope="col" className={`${cabecera} text-left`}>
              {ejeLabel}
            </th>
            {series.map((s) => (
              <th key={s.key} scope="col" className={`${cabecera} text-right`}>
                {s.label}
              </th>
            ))}
            {unidadLabel && (
              <th scope="col" className={`${cabecera} text-right`}>
                {unidadLabel}
              </th>
            )}
          </tr>
        </thead>
        <tbody>
          {points.map((p) => (
            <tr key={p.key} className="border-b border-panel-hairline last:border-0">
              <th
                scope="row"
                className="whitespace-nowrap px-3 py-1.5 text-left type-panel-body tabular-nums text-on-surface-variant"
              >
                {p.label}
              </th>
              {series.map((s, si) => (
                <td
                  key={s.key}
                  className="whitespace-nowrap px-3 py-1.5 text-right type-panel-body tabular-nums text-on-surface"
                >
                  {celda(p.values[si] ?? null, format)}
                </td>
              ))}
              {unidadLabel && (
                <td className="whitespace-nowrap px-3 py-1.5 text-right type-panel-body tabular-nums text-on-surface-variant">
                  {p.note ?? '—'}
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
