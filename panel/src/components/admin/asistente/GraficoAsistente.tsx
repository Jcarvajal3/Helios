import { BarChart, ChartCard, LineChart, ShareBars } from '@/components/charts'
import type { ChartPoint, ChartSeries, LinePoint, ShareRow } from '@/components/charts'
import type { Grafico } from '@/features/admin/asistente/protocolo'
import { FORMATO, esEntero } from '@/features/admin/asistente/unidades'

/**
 * Las series de un gráfico del asistente. `valor` es la protagonista (el tono del área);
 * `valor2`, si viene, es el contexto contra el que se mide: el listón gris de
 * la barra o la línea de detrás. Va la última: en las barras, el listón se
 * dibuja detrás; en las líneas se dice con `principal`.
 */
function seriesDe(g: Grafico, conSegunda: boolean): ChartSeries[] {
  const principal = { key: 'valor', label: g.leyenda?.valor ?? g.titulo }
  if (!conSegunda) return [principal]
  return [{ key: 'valor2', label: g.leyenda?.valor2 ?? 'Referencia' }, principal]
}

/** Un reparto: cuánto de un montón es cada parte, contra el total. */
function Reparto({ grafico }: { grafico: Grafico }) {
  const filas: ShareRow[] = grafico.puntos.map((p, i) => ({
    key: `${i}-${p.etiqueta}`,
    label: p.etiqueta,
    value: p.valor,
    tone: 'primary',
  }))
  return (
    <ChartCard titulo={grafico.titulo}>
      <ShareBars rows={filas} format={FORMATO[grafico.unidad].completo} />
    </ChartCard>
  )
}

/**
 * Un gráfico que pide el asistente, dibujado con el kit del panel: barras,
 * líneas o reparto, con la unidad aplicada. Se lee sin tocar nada y lleva su
 * tabla detrás del botón de la tarjeta, como cualquier otro gráfico del panel.
 */
export function GraficoAsistente({ grafico }: { grafico: Grafico }) {
  if (grafico.tipo === 'reparto') return <Reparto grafico={grafico} />

  const formato = FORMATO[grafico.unidad]
  const conSegunda = grafico.puntos.some((p) => p.valor2 !== undefined)
  const series = seriesDe(grafico, conSegunda)
  const valores = grafico.puntos.flatMap((p) => (p.valor2 === undefined ? [p.valor] : [p.valor, p.valor2]))
  const comun = {
    title: grafico.titulo,
    series,
    format: formato.completo,
    formatShort: formato.corto,
    enteros: esEntero(grafico.unidad, valores),
    height: 160,
  }

  if (grafico.tipo === 'lineas') {
    const puntos: LinePoint[] = grafico.puntos.map((p, i) => ({
      key: String(i),
      label: p.etiqueta,
      values: conSegunda ? [p.valor2 ?? null, p.valor] : [p.valor],
    }))
    return <LineChart {...comun} points={puntos} principal={series.length - 1} ejeLabel="Periodo" />
  }

  const puntos: ChartPoint[] = grafico.puntos.map((p, i) => ({
    key: String(i),
    label: p.etiqueta,
    values: conSegunda ? [p.valor2 ?? 0, p.valor] : [p.valor],
  }))
  return <BarChart {...comun} points={puntos} ejeLabel="Categoría" />
}
