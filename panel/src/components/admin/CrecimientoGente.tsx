import { useQuery } from '@tanstack/react-query'

import {
  SkeletonList,
  SkeletonStats,
  StatGrid,
  formatDayShort,
  formatUsd,
  formatUsdShort,
  formatNumero,
} from '@/components/ui'
import type { Rango } from '@/components/ui'
import { BarChart, LineChart, acumular } from '@/components/charts'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { TodosLosUsuarios } from '@/components/admin/crecimiento/TodosLosUsuarios'
import { CifraConTendencia } from '@/components/admin/metricas/kit'
import { Cifra } from '@/components/admin/tableros/CifrasEnFila'
import type { GrowthOverview } from '@/features/admin/growth'
import { delta } from '@/features/admin/metricas/formato'
import { consultaDelTablero } from '@/features/admin/metricas/gente/consultas'
import { MOTIVO_PADRON } from '@/features/admin/metricas/gente/textos'

const cuenta = (v: number) => String(Math.round(v))

/**
 * Gente › Resumen: quién entra y hasta dónde llega.
 *
 * El orden es el del viaje de una persona: cuántas pidieron el código,
 * cuántas se registraron (un registro es una persona con la verificación de
 * identidad aprobada), cuántas hicieron su primer consumo, y el embudo que
 * enseña en qué escalón se caen las demás. Lo que gastan es la sub-vista
 * siguiente (Uso).
 *
 * Con un local, lo del padrón (solicitudes, registros, embudo de alta,
 * totales) no se parte y lo dice; «Usuarios con su primer consumo» pasa a
 * ser «Usuarios nuevos en el local»: su primera cuota en ese local cayó en la
 * ventana.
 */
export function CrecimientoGente({
  rango,
  local,
  comparar,
}: {
  rango: Rango
  local: string | null
  /** Si la ventana tiene con qué compararse (desde el inicio, no). */
  comparar: boolean
}) {
  const tablero = useQuery(consultaDelTablero(rango, local))

  if (tablero.isPending) {
    return (
      <>
        <SkeletonStats count={4} cols={4} />
        <SkeletonList rows={4} className="mt-6" />
      </>
    )
  }

  if (tablero.isError) {
    return (
      <ErrorConReintento
        title="No se pudo leer quién llega"
        error={tablero.error}
        onReintentar={() => void tablero.refetch()}
      />
    )
  }

  const o = tablero.data
  const conLocal = o.merchantId !== null
  const days = Math.max(o.windowDays, 1)
  const cambio = (d: { count: number; previous: number }) =>
    comparar ? delta(d.count, d.previous, { tipo: 'relativo', arribaEsBueno: true }) : null

  return (
    <div className="flex flex-col gap-10">
      <StatGrid cols={3}>
        <CifraConTendencia
          titulo="Registros"
          valor={o.registered ? String(o.registered.count) : ''}
          delta={o.registered ? cambio(o.registered) : null}
          pie={o.registered ? `${formatNumero(o.registered.count / days)} al día` : undefined}
          info="Pacientes que una clínica registró por primera vez en la ventana, por el día operativo del alta."
          link={{ to: '/admin/pacientes' }}
          noSeParte={o.registered ? false : MOTIVO_PADRON}
        />
        <CifraConTendencia
          titulo={conLocal ? 'Pacientes nuevos en la clínica' : 'Pacientes con su primer financiamiento'}
          valor={String(o.activated.count)}
          delta={cambio(o.activated)}
          info={
            conLocal
              ? 'Pacientes cuya primera cuota en esta clínica cayó en la ventana, se hubieran financiado antes en otro o no.'
              : 'Pacientes cuyo primer financiamiento en Helios cayó en la ventana, se registraran cuando se registraran.'
          }
          pie={conLocal ? 'Su primera vez en esta clínica' : 'Su primer financiamiento en Helios cayó en la ventana'}
        />
        <CifraConTendencia
          titulo="Pacientes que se financiaron"
          valor={String(o.activeUsers.count)}
          delta={cambio(o.activeUsers)}
          info="Pacientes distintos con un financiamiento en la ventana."
          pie={`${o.orders.count} ${o.orders.count === 1 ? 'financiamiento' : 'financiamientos'} · ${formatUsd(o.spend.financedUsd)} financiado (sin comisión)`}
          link={{
            to: '/admin/financiamientos',
            search: { desde: o.from, hasta: o.to, local: o.merchantId ?? undefined },
          }}
        />
      </StatGrid>

      <QuienLlega o={o} />

      <BarChart
        title="Pacientes que se financiaron, por día"
        summary={
          <>
            <Cifra>{o.activeUsers.count}</Cifra> pacientes distintos en la ventana · {o.orders.count} financiamientos ·{' '}
            {formatUsd(o.spend.financedUsd)} financiado (sin comisión)
          </>
        }
        enteros
        series={[{ key: 'active', label: 'Pacientes' }]}
        points={o.series.map((d) => ({
          key: d.day,
          label: formatDayShort(d.day),
          values: [d.activeUsers],
          note: d.orders > 0 ? `${d.orders} ${d.orders === 1 ? 'financiamiento' : 'financiamientos'} · ${formatUsdShort(d.financedUsd)} sin comisión` : undefined,
        }))}
        format={cuenta}
        formatShort={cuenta}
        ejeLabel="Día"
        unidadLabel="Financiamientos y financiado sin comisión"
        footnote="Una barra por día: los pacientes de un día no se suman entre días, porque el mismo paciente cuenta en cada día que vino. El financiado va sin la Comisión Helios."
        empty="No hubo financiamiento en esta ventana."
      />

      <TodosLosUsuarios totales={o.totals} conLocal={conLocal} />
    </div>
  )
}

/**
 * Registros y primeros consumos de la ventana, acumulados (con local, solo
 * los usuarios nuevos en el local: el registro no se parte).
 */
function QuienLlega({ o }: { o: GrowthOverview }) {
  const days = o.windowDays
  const conLocal = o.merchantId !== null
  const nuevas = conLocal ? 'Pacientes nuevos en la clínica' : 'Pacientes con su primer financiamiento'
  const plazo = `en ${days} ${days === 1 ? 'día' : 'días'}`

  return (
    <LineChart
      title={conLocal ? 'Pacientes nuevos en la clínica, acumulado' : 'Registros y primeros financiamientos, acumulado'}
      summary={
        o.registered ? (
          <>
            <Cifra>{o.registered.count}</Cifra> {o.registered.count === 1 ? 'registro' : 'registros'} y{' '}
            <Cifra>{o.activated.count}</Cifra>{' '}
            {o.activated.count === 1 ? 'primer financiamiento' : 'primeros financiamientos'} {plazo}
          </>
        ) : (
          <>
            <Cifra>{o.activated.count}</Cifra> {o.activated.count === 1 ? 'paciente nuevo' : 'pacientes nuevos'}{' '}
            en la clínica {plazo}
          </>
        )
      }
      series={
        o.registered
          ? [
              { key: 'registered', label: 'Registros' },
              { key: 'activated', label: nuevas },
            ]
          : [{ key: 'activated', label: nuevas }]
      }
      points={acumular(
        o.series.map((d) => ({
          key: d.day,
          label: formatDayShort(d.day),
          values: o.registered ? [d.registered ?? 0, d.activated] : [d.activated],
        })),
      )}
      area
      escalon
      enteros
      format={cuenta}
      formatShort={cuenta}
      ejeLabel="Día"
      unidadLabel={o.registered ? 'Registros' : 'Nota'}
      footnote={
        conLocal
          ? 'Acumulado desde el primer día de la ventana. Un paciente nuevo en la clínica puede haberse financiado antes en otro.'
          : 'Acumulado desde el primer día de la ventana. Un registro cuenta el día en que una clínica lo registró. El primer financiamiento es el de cada paciente, sea cual sea el día en que se registró: por eso puede haber más primeros financiamientos que registros.'
      }
      empty={conLocal ? 'Nadie llegó a la clínica en esta ventana.' : 'Nadie se registró ni hizo su primer financiamiento en esta ventana.'}
    />
  )
}
