import { useQuery } from '@tanstack/react-query'

import { BarChart } from '@/components/charts'
import { Card, NoSePudoLeer, SkeletonBlock, formatUsd, formatUsdShort } from '@/components/ui'
import { consultaDiasDeCobro } from '@/features/admin/metricas/cobranza/api'
import { fraseDeLosDias, notaDelDia } from '@/features/admin/metricas/cobranza/semana'
import { diaDeLaSemana } from '@/features/admin/semana'
import { PartesEnLinea } from './piezas'

/** «lun 21»; el de hoy, «hoy». */
function rotuloDelDia(dia: string, hoy: string): string {
  if (dia === hoy) return 'hoy'
  return `${diaDeLaSemana(dia).slice(0, 3)} ${Number(dia.slice(8, 10))}`
}

/**
 * Lo que vencía cada día de la semana y lo que entró de eso: el listón gris es
 * lo que vencía y la barra de dentro lo que ya se pagó de ello. Lo que asoma
 * por encima es lo que falta.
 *
 * Las dos son cuotas (con el service fee dentro): la frase dice lo que vencía con
 * su desglose, y lo que entró como la parte que es de ello; la tabla del
 * gráfico da cada día con el suyo. Los días que no han llegado salen con lo
 * que vencerá, y aún pueden pagarse.
 */
export function VenciaYEntroPorDia({
  domingo,
  enCurso,
  hoy,
  local,
}: {
  domingo: string
  enCurso: boolean
  hoy: string
  local: string | null
}) {
  const dias = useQuery(consultaDiasDeCobro(domingo, local))

  if (dias.isError) {
    return (
      <Card className="flex flex-col gap-3">
        <h3 className="type-panel-section text-on-surface">Vencía cada día y cobrado de ello (con fee)</h3>
        <NoSePudoLeer onReintentar={() => void dias.refetch()} />
      </Card>
    )
  }
  if (!dias.data) return <SkeletonBlock className="h-72 w-full" />

  return (
    <div className={`transition-opacity ${dias.isPlaceholderData ? 'opacity-60' : 'opacity-100'}`}>
      <BarChart
        title="Vencía cada día y cobrado de ello (con fee)"
        summary={<PartesEnLinea partes={fraseDeLosDias(dias.data, enCurso, hoy)} />}
        series={[
          { key: 'vencia', label: 'Vencía' },
          { key: 'entro', label: 'Cobrado de ello, hasta hoy' },
        ]}
        points={dias.data.map((d) => ({
          key: d.dia,
          label: rotuloDelDia(d.dia, hoy),
          values: [d.vencia.payableUsd, d.entroDeEso.payableUsd],
          note: d.futuro ? `Todavía no ha llegado · ${notaDelDia(d)}` : notaDelDia(d),
        }))}
        format={formatUsd}
        formatShort={formatUsdShort}
        ejeLabel="Día"
        unidadLabel="Cuotas pagadas y desglose de lo que vencía"
        height={200}
        footnote="Por día de la semana: cuotas con vencimiento ese día (sin las dadas por perdidas) y, dentro, la parte de ellas ya pagada hoy (antes, ese día o después), en dólares con fee; el desglose de cada día está en la tabla."
        empty="No vencía ninguna cuota esta semana."
      />
    </div>
  )
}
