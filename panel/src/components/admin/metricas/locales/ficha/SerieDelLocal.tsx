import { BarChart } from '@/components/charts'
import { formatUsd, formatUsdShort } from '@/components/ui'
import { puntosDelConsumo } from '@/features/admin/metricas/locales/ficha'
import { semanaCorta } from '@/features/admin/metricas/locales/semanas'
import type { LocalesDeLaSemana, SerieDeLocal } from '@/features/admin/metricas/locales/tipos'

/**
 * Su consumo semana a semana: las doce que acaban en la elegida. La barra más
 * alta lleva su cifra y la tabla, con los consumos y la gente de cada semana,
 * está a un clic en la cabecera.
 */
export function SerieDelLocal({ d, serie }: { d: LocalesDeLaSemana; serie: SerieDeLocal | null }) {
  const semanas = d.series.semanas
  const primera = semanas.at(0)
  const ultima = semanas.at(-1)

  return (
    <BarChart
      title="Financiado por semana (sin comisión)"
      summary={
        primera && ultima
          ? `De ${semanaCorta(primera)} a ${semanaCorta(ultima)}${d.semana.enCurso ? ', la última a medias' : ''}.`
          : undefined
      }
      footnote="Sin la Comisión Helios: el financiado de la clínica cada semana. Los pacientes son los que tienen cuota en sus financiamientos."
      series={[{ key: 'consumo', label: 'Financiado (sin comisión)' }]}
      points={serie ? puntosDelConsumo(semanas, serie) : []}
      format={formatUsd}
      formatShort={formatUsdShort}
      ejeLabel="Semana"
      unidadLabel="Financiamientos y pacientes"
      empty="Esta clínica no ha financiado en estas doce semanas."
    />
  )
}
