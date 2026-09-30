import { useQuery } from '@tanstack/react-query'

import { Ring } from '@/components/charts'
import {
  Seccion,
  Stat,
  StatGrid,
  estadoDeConsulta,
  formatDateTime,
  formatUsd,
  formatPct,
  formatWaiting,
} from '@/components/ui'
import { primerDia, ultimoDia } from '@/features/admin/cierreMes'
import { fetchReconciliationHealth } from '@/features/admin/pagosReportados'

/**
 * La salud de la conciliación en un mes: el rango va del día 1 al último día
 * del mes, o hasta hoy si el mes está en curso. La comparten la lista del
 * cierre (hasta dónde llega el extracto) y estas cifras.
 */
export function useSaludDelMes(mes: string, hoy: string) {
  const desde = primerDia(mes)
  const hasta = ultimoDia(mes) < hoy ? ultimoDia(mes) : hoy
  return useQuery({
    queryKey: ['reconciliation-health', desde, hasta],
    queryFn: () => fetchReconciliationHealth(desde, hasta),
  })
}

function minutos(m: number | null): string {
  return m === null ? 'Sin datos' : formatWaiting(m * 60)
}

/**
 * Cómo va la conciliación: cuánto de lo aprobado respalda el extracto, cuánto
 * se tarda en decidir y cuánto lleva esperando la cola. Cada cifra abre la
 * lista de pagos que la explica. Ninguna lleva color: no tienen umbral en los
 * parámetros, y el cotejo va con su anillo.
 */
export function SaludConciliacion({ mes, hoy }: { mes: string; hoy: string }) {
  const query = useSaludDelMes(mes, hoy)
  const estado = estadoDeConsulta(query)
  const reintentar = () => void query.refetch()
  const d = query.data

  const cotejo = d?.resolved.matchPct ?? null
  const cola = d?.queue

  return (
    <Seccion titulo="Cómo va la aprobación de pagos">
      <StatGrid cols={3}>
        <Stat
          label="Cotejo automático"
          info="De los pagos aprobados por pago móvil o transferencia, cuántos tienen hoy un movimiento que encaja en el extracto. No cuenta los que nacen de asignar un abono, que ya salen del extracto. Zelle, USDT y efectivo no aparecen en el extracto en bolívares."
          value={cotejo === null ? 'Sin datos' : formatPct(cotejo, 0)}
          hint={
            d &&
            (d.resolved.approvedInStatementMethods === 0
              ? 'No hubo aprobados por pago móvil o transferencia'
              : d.resolved.rejectedMatched > 0
                ? `${d.resolved.rejectedMatched} rechazados sí encajan: revísalos`
                : `${d.resolved.approvedMatched} de ${d.resolved.approvedInStatementMethods} aprobados`)
          }
          lateral={
            <Ring
              valor={cotejo === null ? null : cotejo / 100}
              rotulo={
                cotejo === null || !d
                  ? 'Cotejo automático: sin datos'
                  : `Cotejo automático: ${formatPct(cotejo, 0)}, ${d.resolved.approvedMatched} de ${d.resolved.approvedInStatementMethods} aprobados`
              }
            />
          }
          link={{ to: '/admin/cobros', search: { tab: 'aprobados', desde: d?.from, hasta: d?.to } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <Stat
          label="Tiempo hasta aprobar"
          info="La mediana del tiempo entre que el paciente reporta el pago y alguien lo aprueba. Poner un pago en revisión no para el reloj."
          value={minutos(d?.resolutionMinutes.approved.median ?? null)}
          hint={
            d && d.resolutionMinutes.approved.p90 !== null
              ? `Nueve de cada diez, en menos de ${minutos(d.resolutionMinutes.approved.p90)}`
              : undefined
          }
          link={{ to: '/admin/cobros', search: { tab: 'aprobados', desde: d?.from, hasta: d?.to } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <Stat
          label="Cola de pagos por aprobar"
          info="Los pagos reportados que esperan hoy una decisión, sea cual sea el mes. El monto es lo que la gente dice haber pagado."
          value={cola ? `${cola.count} ${cola.count === 1 ? 'pago' : 'pagos'}` : ''}
          hint={
            cola &&
            (cola.count === 0
              ? 'La cola está vacía'
              : `${formatUsd(cola.usd)} · el más viejo, del ${formatDateTime(cola.oldestCreatedAt)}${
                  cola.over3Days.count > 0 ? ` · ${cola.over3Days.count} con más de tres días` : ''
                }`)
          }
          link={{ to: '/admin/cobros' }}
          estado={estado}
          onReintentar={reintentar}
        />
      </StatGrid>
    </Seccion>
  )
}
