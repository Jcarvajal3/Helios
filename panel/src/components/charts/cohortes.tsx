import type { ReactNode } from 'react'

import { GloboFlotante, lecturaDelPunto, useRecorridoDeMarcas } from '@/components/charts/lectura'
import type { ContenidoDelGlobo, FilaDelGlobo } from '@/components/charts/lectura'

/**
 * Hasta dónde llega el tono del área en la celda más fuerte. Más allá, el
 * texto blanco deja de leerse con los tonos claros (turquesa y violeta
 * bajan de 4,5:1 pasado el 75 %), y cambiarlo a oscuro a media rejilla hacía
 * que las celdas fuertes, las que más importan, se leyeran distinto.
 */
const TINTE_MAXIMO = 75

/**
 * El fondo de una celda según su intensidad, de 0 a 1: el tono del área
 * mezclado con la pista.
 *
 * El suelo es la pista (`panel-control`) y **no** la tarjeta: la rejilla vive
 * dentro de una tarjeta, y una celda al 0 % mezclada contra la tarjeta
 * desaparece —se pinta igual que el hueco de al lado, que es el futuro—. Y
 * son lo contrario: «esta cohorte no volvió» y «esta semana todavía no ha
 * pasado». Cero es un dato y se ve.
 */
export function tinteCohorte(intensity: number): string {
  const limpia = Number.isFinite(intensity) ? Math.min(Math.max(intensity, 0), 1) : 0
  const mezcla = Math.round(limpia * TINTE_MAXIMO)
  return `color-mix(in oklab, var(--area) ${mezcla}%, var(--color-panel-control))`
}

export type CohortCell = {
  /** De 0 a 1. Decide cuánto tono del área lleva la celda. */
  intensity: number
  /** Lo que se escribe DENTRO: '62 %', '€14'. Nunca se deja solo el color. */
  text: string
  /**
   * Los números crudos de la celda: '12 de 20 personas · 60 % · €300,00'.
   * Van en la nota del globo (ya no en el `title` del navegador).
   */
  title: string
  /** Las filas del globo, si la celda tiene más que decir que su texto. */
  filas?: ReadonlyArray<FilaDelGlobo>
  /** El cubo en curso: está a medias y se marca. */
  partial?: boolean
}

export type CohortGridRow = {
  key: string
  /** El rótulo de la fila: '15 sep', 'Semana del 15'. */
  label: string
  /** La segunda línea: cuánta gente entró en ese cubo. Es el denominador. */
  note: string
  /**
   * Una por columna, desde la 0.
   *
   * `null` significa **todavía no ha pasado**, y es distinto de un cero. Es la
   * diferencia entre «esta cohorte dejó de volver» y «esta cohorte se registró
   * anteayer»: pintar un 0 en el futuro dibuja un desplome inventado y hace
   * que las cohortes nuevas parezcan siempre las peores.
   */
  cells: Array<CohortCell | null>
}

/**
 * LA COHORTE QUE ENTRÓ EL LUNES, ¿SEGUÍA AQUÍ EL LUNES SIGUIENTE?
 *
 * Cada fila es la gente que se registró en un mismo cubo y cada columna es
 * cuántos de ESOS mismos seguían activos N cubos después. A lo ancho se lee
 * cómo envejece una cohorte; hacia abajo por una columna, si el producto
 * mejora.
 *
 * **El triángulo es el punto.** El borde escalonado de la derecha es dónde
 * llega el presente: una rejilla rectangular aquí solo se consigue
 * rellenando el futuro con ceros.
 *
 * El color es la segunda lectura, nunca la única: cada celda lleva su número
 * escrito. Y cada celda se lee entera en su globo, con los números crudos:
 * al pasar el ratón o, con el teclado, recorriendo la rejilla con las flechas
 * (← → por la fila, ↑ ↓ por la columna) después de llegar a ella con Tab.
 */
export function CohortGrid({
  rows,
  totals,
  columnLabel,
  columnTitle,
  rowHeader,
  columnsCaption,
  periods,
  onSelectRow,
  footnote,
  empty = 'Todavía no hay cohortes que seguir.',
}: {
  rows: Array<CohortGridRow>
  /** El renglón de abajo: todas las cohortes juntas. */
  totals?: CohortGridRow
  /** Cómo se llama la columna k: 'Día 0', 'Sem. 3'. */
  columnLabel: (k: number) => string
  /**
   * El nombre entero de la columna k, para el globo: 'Semana 3 desde el
   * registro'. Sin él, el renglón de `columnsCaption` y el de `columnLabel`.
   */
  columnTitle?: (k: number) => string
  /** Cómo se llama la primera columna: 'Se registraron'. */
  rowHeader: string
  /**
   * El renglón que va encima de los números de columna. Sin él, la cabecera
   * es «0 1 2 3 4» y nada dice que son semanas desde el registro y no fechas.
   */
  columnsCaption?: string
  periods: number
  /** Con esto, el rótulo de cada fila pasa a ser un botón que abre ese grupo. */
  onSelectRow?: (key: string) => void
  footnote?: ReactNode
  empty?: string
}) {
  const todas = totals ? [...rows, totals] : rows
  const recorrido = useRecorridoDeMarcas(todas.length * periods, {
    columnas: periods,
    saltar: (i) => (todas.at(Math.floor(i / periods))?.cells[i % periods] ?? null) === null,
  })

  if (rows.length === 0) {
    return <p className="py-8 text-center type-panel-body text-panel-muted">{empty}</p>
  }

  const columnas = Array.from({ length: periods }, (_, k) => k)
  const cabecera = 'pb-2 type-panel-caption font-semibold text-on-surface-variant'
  // «Semanas desde el registro →» sin la flecha, que en una frase sobra.
  const leyendaDeColumnas = columnsCaption?.replace(/\s*[→>]+\s*$/, '').trim()

  const nombreDeColumna = (k: number) =>
    columnTitle
      ? columnTitle(k)
      : leyendaDeColumnas
        ? `${leyendaDeColumnas}: ${columnLabel(k)}`
        : columnLabel(k)

  const globo = (i: number): ContenidoDelGlobo | null => {
    const row = todas.at(Math.floor(i / periods))
    const k = i % periods
    const cell = row?.cells[k] ?? null
    if (!row || !cell) return null
    return {
      titulo: `${row.label} · ${nombreDeColumna(k)}`,
      filas: cell.filas ?? [
        {
          key: 'celda',
          rotulo: row.note,
          valor: cell.text,
          color: tinteCohorte(cell.intensity),
          forma: 'punto',
        },
      ],
      nota: [cell.title, cell.partial ? 'En curso: todavía puede subir.' : '']
        .filter((x) => x !== '')
        .join(' · ') || undefined,
    }
  }
  const activo = recorrido.senalada === null ? null : globo(recorrido.senalada)

  function renglon(row: CohortGridRow, r: number, esTotal: boolean) {
    return (
      <tr key={row.key} className={esTotal ? 'border-t border-panel-hairline-strong' : undefined}>
        <th
          scope="row"
          // Pegada: con doce columnas la rejilla se desplaza a lo ancho, y una
          // celda al 62 % sin saber de qué fila es no dice nada. Con el fondo
          // de la tarjeta, opaco, para que las columnas pasen por debajo.
          className="sticky left-0 z-10 bg-panel-card py-1 pr-3 text-left align-middle"
        >
          {onSelectRow && !esTotal ? (
            <button
              type="button"
              onClick={() => onSelectRow(row.key)}
              title={`Ver solo la cohorte de ${row.label}`}
              className="en-linea block w-full rounded-panel-control px-2 py-1 text-left transition-colors duration-[var(--transition-fast)] hover:bg-panel-raised"
            >
              <Rotulo row={row} />
            </button>
          ) : (
            <span className="block px-2 py-1">
              <Rotulo row={row} />
            </span>
          )}
        </th>

        {columnas.map((k) => {
          const cell = row.cells[k] ?? null
          const i = r * periods + k
          const senalada = recorrido.senalada === i
          return (
            <td key={k} className="p-0.5">
              {cell ? (
                <div
                  {...recorrido.marca(i)}
                  style={{ backgroundColor: tinteCohorte(cell.intensity) }}
                  className={`flex h-10 min-w-14 items-center justify-center rounded-panel-control tabular-nums type-panel-control text-on-surface ${
                    senalada
                      ? 'outline-2 outline-on-surface'
                      : cell.partial
                        ? 'outline-1 outline-dashed outline-panel-muted'
                        : ''
                  }`}
                >
                  {cell.text}
                </div>
              ) : (
                // El futuro. Ni caja ni cero: un hueco, que es lo que es.
                <div className="h-10 min-w-14" aria-hidden />
              )}
            </td>
          )
        })}
      </tr>
    )
  }

  return (
    <div>
      {/* Fuera de la caja que desplaza: dentro, el rótulo que explica las
          columnas se iría de la vista justo cuando más falta hace. */}
      {columnsCaption && (
        <p className="mb-1 type-panel-caption text-panel-muted">{columnsCaption}</p>
      )}
      <div
        {...recorrido.caja}
        role="group"
        aria-label={`${rowHeader}: las flechas recorren las celdas.`}
        className="overflow-x-auto rounded-panel-control"
      >
        <table className="border-separate border-spacing-0">
          <thead>
            <tr>
              <th scope="col" className={`sticky left-0 z-10 bg-panel-card pr-3 text-left ${cabecera}`}>
                {rowHeader}
              </th>
              {columnas.map((k) => (
                <th key={k} scope="col" className={`px-0.5 text-center ${cabecera}`}>
                  {columnLabel(k)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row, r) => renglon(row, r, false))}
            {totals && renglon(totals, rows.length, true)}
          </tbody>
        </table>
      </div>

      {activo && <GloboFlotante ancla={recorrido.ancla} {...activo} />}
      <p aria-live="polite" className="sr-only">
        {activo ? lecturaDelPunto(activo.titulo, activo.filas, activo.nota) : ''}
      </p>

      {footnote && <p className="mt-3 type-panel-caption text-panel-muted">{footnote}</p>}
    </div>
  )
}

/** El rótulo de una fila de la rejilla: cuándo entró el grupo y cuánta gente. */
function Rotulo({ row }: { row: CohortGridRow }) {
  return (
    <>
      <span className="block whitespace-nowrap type-panel-body text-on-surface">{row.label}</span>
      {/* El tamaño del grupo va SIEMPRE con el rótulo: una fila al 100 % sin
          saber que es de una sola persona se lee como un triunfo. */}
      <span className="block whitespace-nowrap type-panel-caption text-panel-muted">
        {row.note}
      </span>
    </>
  )
}
