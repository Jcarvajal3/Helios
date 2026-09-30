import { formatNumero } from '@/components/ui'
import { NumerosEnDetalles, SeccionMetricas } from '@/components/admin/metricas/kit'
import { importeYDesglose } from '@/features/admin/metricas/cohortes/desglose'
import type { CohorteDeLocal, ParteDeCuota } from '@/features/admin/metricas/cohortes/tipos'
import { CABECERA, CabecerasDelCobro, CeldasDelCobro } from './CeldasDelCobro'

/**
 * La semana partida por local, en lo que hay que COBRAR: el total a cobrar
 * de cada local (la cuota 1 + la 2, con el service fee dentro), qué parte se
 * cobró, lo cobrado, lo vencido y lo por vencer, cada importe con su desglose
 * debajo, y cómo va cada cuota. Con un local elegido arriba, es su fila. Los
 * locales suman el total de la semana.
 */
export function PorLocal({ filas, hoy }: { filas: ReadonlyArray<CohorteDeLocal>; hoy: string }) {
  const ordenadas = [...filas].sort(
    (a, b) => b.aCobrar.importe.payableUsd - a.aCobrar.importe.payableUsd || a.nombre.localeCompare(b.nombre),
  )
  const importe = (p: ParteDeCuota) => (p.importe.payableUsd > 0 ? importeYDesglose(p.importe) : '—')

  return (
    <SeccionMetricas
      titulo="Total a cobrar por clínica"
      info="Total a cobrar (cuota 1 + cuota 2, con fee) de los financiamientos de esta semana en cada clínica, con lo cobrado, lo vencido y lo por vencer; las clínicas suman el total de la semana."
    >
      <div className="-mx-3 overflow-x-auto overscroll-x-contain">
        <table className="w-full min-w-max border-collapse tabular-nums">
          <thead>
            <tr className="border-b border-panel-hairline-strong">
              <th scope="col" className={`${CABECERA} text-left`}>
                Clínica
              </th>
              <CabecerasDelCobro />
            </tr>
          </thead>
          <tbody>
            {ordenadas.map((l) => (
              <tr key={l.merchantId} className="border-b border-panel-hairline align-top last:border-0">
                <th scope="row" className="px-2.5 py-2 text-left type-panel-body font-semibold text-on-surface">
                  {l.nombre}
                </th>
                <CeldasDelCobro cohorte={l} hoy={hoy} quien={l.nombre} />
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <NumerosEnDetalles
        resumen="Ver el reparto por estado de cada clínica"
        cabeceras={['Clínica', 'Financiamientos', 'Pacientes que se financiaron', 'Cobrado a tiempo', 'Cobrado con atraso', 'Perdido']}
        filas={ordenadas.map((l) => ({
          clave: l.merchantId,
          celdas: [
            l.nombre,
            formatNumero(l.consumos, 0),
            formatNumero(l.personas, 0),
            importe(l.aCobrar.estados.a_tiempo),
            importe(l.aCobrar.estados.tarde),
            importe(l.aCobrar.estados.perdida),
          ],
        }))}
      />
    </SeccionMetricas>
  )
}
