import type { ReactNode } from 'react'

import { Segmented, formatUsd, formatUsdShort, formatPorcentaje } from '@/components/ui'
import { ChartCard, CohortGrid, tinteCohorte } from '@/components/charts'
import type { CohortGridRow } from '@/components/charts'
import { Cifra } from '@/components/admin/tableros/CifrasEnFila'
import type { UserCohorts } from '@/features/admin/growth'
import {
  OPCIONES_DE_MEDIDA,
  TEXTOS_DE_BASE,
  UNIDAD,
  celda,
  columnasDesde,
  etiquetaCubo,
  porcentaje,
  totalEn,
  valor,
} from './cohortes'
import type { Medida } from './cohortes'

/**
 * Comparar todas: la rejilla de retención.
 *
 * Es como mira esto un analista y por eso es el segundo paso, no la puerta.
 * Arriba lleva la lectura de una fila de verdad, con sus números; cómo se lee
 * entera va en la explicación. Es la única vista que contesta si el producto
 * MEJORA: la columna 1 de las cohortes nuevas contra la de las viejas.
 */
export function TodasLasCohortes({
  data,
  medida,
  onMedida,
  onAbrir,
}: {
  data: UserCohorts
  medida: Medida
  onMedida: (m: Medida) => void
  onAbrir: (start: string) => void
}) {
  const unidad = UNIDAD[data.grain]
  const textos = TEXTOS_DE_BASE[data.base]

  // El tope de la escala de color sale de la propia rejilla y no de un 100 %
  // fijo: la retención del periodo 3 casi nunca pasa del 20 %, y medida contra
  // cien todas esas celdas saldrían del mismo gris. El precio es que dos
  // rejillas con filtros distintos no se comparan por el color — por eso cada
  // celda lleva su número escrito.
  const tope = Math.max(
    ...data.rows.flatMap((r) => r.cells.map((c) => valor(r, c.k, medida) ?? 0)),
    0,
  )

  const filas: CohortGridRow[] = data.rows.map((r) => ({
    key: r.start,
    label: etiquetaCubo(r.start, data.grain),
    note: textos.miembros(r.size),
    cells: Array.from({ length: data.periods }, (_, k) =>
      k > r.maxPeriod ? null : celda(r, k, medida, tope),
    ),
  }))

  const resumen: CohortGridRow = {
    key: 'totales',
    label: 'Todas juntas',
    note: 'media ponderada',
    cells: Array.from({ length: data.periods }, (_, k) => {
      const t = totalEn(data, k)
      if (!t || t.size === 0) return null

      const pct = (t.active / t.size) * 100
      const porPersona = t.financedUsd / t.size
      const bruto = medida === 'gente' ? pct : porPersona

      return {
        intensity: tope > 0 ? bruto / tope : 0,
        text: medida === 'gente' ? `${formatPorcentaje(pct)}` : formatUsdShort(porPersona),
        title: `${t.active} de ${t.size} se financiaron · ${formatPorcentaje(pct)} · ${formatUsd(t.financedUsd)} financiado sin fee`,
      }
    }),
  }

  return (
    <ChartCard
      titulo="Retención por cohorte"
      info={`Cada fila es una cohorte: los que ${textos.verbo} ${unidad.elMismo}. Las columnas no son fechas: son ${unidad.unos} desde que entraron. «Se financiaron (%)» es la parte de la cohorte con al menos un financiamiento en ese periodo; «Financiado por paciente (sin fee)», lo financiado a la cohorte en ese periodo entre todos sus miembros. Se lee en dos direcciones: a lo ancho, cómo envejece una cohorte y dónde se apaga; hacia abajo por una misma columna, si el producto mejora (la columna 1 de las cohortes de arriba, que son las nuevas, contra la de las de abajo). El borde escalonado de la derecha es el presente: donde un periodo no ha ocurrido no hay celda, y la última de cada fila, la del borde punteado, va a subir todavía.`}
      resumen={<Ejemplo data={data} />}
      controles={
        <>
          <Leyenda tope={tope} medida={medida} />
          <Segmented
            etiqueta="Medida"
            options={OPCIONES_DE_MEDIDA}
            value={medida}
            onChange={onMedida}
          />
        </>
      }
    >
      <CohortGrid
        rows={filas}
        totals={resumen}
        periods={data.periods}
        rowHeader={textos.entraron}
        columnsCaption={`${columnasDesde(data.grain, data.base)} →`}
        columnLabel={(k) => String(k)}
        onSelectRow={onAbrir}
        empty={textos.vacio}
        footnote="Pulsa el rótulo de una fila para ver esa cohorte sola."
      />
    </ChartCard>
  )
}

/**
 * Cómo se lee, con los números de una fila de verdad: un ejemplo trabajado
 * enseña la rejilla en una línea; una leyenda abstracta —«filas: cohortes;
 * columnas: periodos»— no enseña nada.
 */
function Ejemplo({ data }: { data: UserCohorts }): ReactNode {
  const unidad = UNIDAD[data.grain]
  // La primera fila con al menos dos columnas: con una sola no se puede
  // enseñar la idea de «y después».
  const ejemplo = data.rows.find((r) => r.maxPeriod >= 1 && r.size > 0)
  if (!ejemplo) return `Cada fila es una cohorte; las columnas son ${unidad.unos} desde que entraron.`

  return (
    <>
      Fila del {etiquetaCubo(ejemplo.start, data.grain)}: entraron <Cifra>{ejemplo.size}</Cifra>;{' '}
      <Cifra>{porcentaje(ejemplo, 0)}</Cifra> se financiaron {unidad.ese} y{' '}
      <Cifra>{porcentaje(ejemplo, 1)}</Cifra> se financiaron {unidad.siguiente}
    </>
  )
}

function Leyenda({ tope, medida }: { tope: number; medida: Medida }) {
  return (
    <div className="flex items-center gap-2" aria-hidden>
      <span className="type-panel-caption text-panel-muted">0</span>
      <div className="flex gap-0.5">
        {[0, 0.25, 0.5, 0.75, 1].map((p) => (
          <span
            key={p}
            className="block size-4 rounded-extra-small"
            style={{ backgroundColor: tinteCohorte(p) }}
          />
        ))}
      </div>
      <span className="type-panel-caption tabular-nums text-panel-muted">
        {medida === 'gente' ? formatPorcentaje(tope) : formatUsdShort(tope)}
      </span>
    </div>
  )
}
