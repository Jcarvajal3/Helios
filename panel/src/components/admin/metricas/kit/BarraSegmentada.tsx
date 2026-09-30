import { StackedBar, rampaOrdinal } from '@/components/charts'
import type { TonoDeMarca } from '@/components/charts'
import { formatPct } from '@/components/ui'
import { porcentaje } from '@/features/admin/metricas/formato'
import { NumerosEnDetalles } from './NumerosEnDetalles'

export type SegmentoDeBarra = {
  rotulo: string
  valor: number
  /**
   * El papel del segmento: `area` (lo que cuenta la historia), un estado
   * (`success`, `warning`, `error`) si ESTÁ bien o mal, o `neutro`. Sin tono ni
   * color, los segmentos toman pasos del tono del área, de claro a oscuro.
   */
  tono?: TonoDeMarca
  /** Un color propio (un paso de `rampaOrdinal`). Manda sobre `tono`. */
  color?: string
}

/**
 * Cómo se reparte un todo en una barra al 100 %: las cuotas de una semana por
 * estado, el consumo por local. Es la `StackedBar` del kit con su leyenda
 * (cada segmento con su cifra, también los que valen cero) y, debajo, la
 * tabla con cada parte en un `<details>`.
 *
 * No escribe ningún total, y es a propósito: si los segmentos son cuotas
 * (lo que se paga, con el service fee dentro), su suma sería un «total por
 * cobrar» sin sus sumandos, que es justo lo que la regla del fee prohíbe. El
 * total, si hace falta, lo escribe la pestaña al lado y con su desglose.
 */
export function BarraSegmentada({
  segmentos,
  rotulo,
  formato = String,
  tabla = true,
}: {
  segmentos: ReadonlyArray<SegmentoDeBarra>
  /** Qué se reparte, para el lector de pantalla y la tabla: «Cuotas de la semana por estado». */
  rotulo: string
  formato?: (n: number) => string
  /** La tabla plegada debajo. Solo se quita si los números ya están escritos al lado. */
  tabla?: boolean
}) {
  const rampa = rampaOrdinal(segmentos.length)
  const conColor = segmentos.map((s, i) => ({
    rotulo: s.rotulo,
    valor: s.valor,
    tono: s.tono ?? 'area',
    color: s.color ?? (s.tono === undefined ? rampa[i] : undefined),
  }))
  const suma = segmentos.reduce((a, s) => a + Math.max(0, s.valor), 0)

  return (
    <div className="flex flex-col gap-2">
      <StackedBar segmentos={conColor} formato={formato} rotulo={rotulo} />
      {tabla && (
        <NumerosEnDetalles
          cabeceras={[rotulo, 'Cifra', 'Parte']}
          filas={segmentos.map((s, i) => {
            const parte = porcentaje(Math.max(0, s.valor), suma)
            return {
              clave: `${i}-${s.rotulo}`,
              celdas: [s.rotulo, formato(s.valor), parte === null ? '—' : formatPct(parte)],
            }
          })}
        />
      )}
    </div>
  )
}
