import { Link, useNavigate } from '@tanstack/react-router'
import { Download } from 'lucide-react'

import { Button, formatNumero } from '@/components/ui'
import { SeccionMetricas } from '@/components/admin/metricas/kit'
import { Muestra } from '@/components/charts/lectura'
import type { BusquedaCohortes } from '@/features/admin/metricas/cohortes/busqueda'
import { columnasCsvDeCohortes, nombreDelCsv } from '@/features/admin/metricas/cohortes/comparar'
import { busquedaDeLaSemana } from '@/features/admin/metricas/cohortes/enlaces'
import { ROTULO_DE_ESTADO } from '@/features/admin/metricas/cohortes/estados'
import { rotuloDeSemana, semanaLarga } from '@/features/admin/metricas/cohortes/semanas'
import { ESTADOS_DE_CUOTA } from '@/features/admin/metricas/cohortes/tipos'
import type { Cohorte } from '@/features/admin/metricas/cohortes/tipos'
import { construirCsv, descargarCsv } from '@/lib/csv'
import { CABECERA, CabecerasDelCobro, CeldasDelCobro } from './CeldasDelCobro'
import { COLOR_DE_ESTADO } from './colores'

/**
 * Todas las semanas de consumo, una por fila, en lo que hay que COBRAR: el
 * total a cobrar (la cuota 1 + la 2, con el service fee dentro), qué parte se
 * cobró, lo cobrado, lo vencido y lo por vencer, cada importe con su desglose
 * debajo (consumo · fee), y cómo va cada cuota.
 *
 * Pulsar una fila abre esa semana en «Una semana». El CSV lleva lo mismo,
 * con el desglose de cada importe en columnas.
 */
export function TablaComparada({
  cohortes,
  semana,
  hoy,
  local,
  nombreLocal,
  busqueda,
}: {
  cohortes: ReadonlyArray<Cohorte>
  semana: string
  hoy: string
  local: string | null
  nombreLocal: string | null
  busqueda: BusquedaCohortes
}) {
  const navigate = useNavigate()
  // Pulsar una semana lleva a su detalle: Cobros › Resumen con esa semana.
  const destino = (c: Cohorte) => busquedaDeLaSemana(c.semana, hoy, local, busqueda)

  function bajarCsv() {
    descargarCsv(nombreDelCsv(hoy, nombreLocal), construirCsv(columnasCsvDeCohortes(), [...cohortes]))
  }

  return (
    <SeccionMetricas
      titulo="Total a cobrar y cobrado por semana de financiamiento"
      info="Una fila por semana de financiamiento (lunes a domingo, por día operativo) con su total a cobrar (cuota 1 + cuota 2, con fee y su desglose), lo cobrado, lo vencido, lo por vencer y los pacientes que se financiaron."
      ayuda="Pulsa una fila para abrir esa semana"
      acciones={
        <Button variant="text" size="sm" onClick={bajarCsv} disabled={cohortes.length === 0}>
          <Download size={15} aria-hidden />
          Descargar CSV
        </Button>
      }
    >
      <div className="-mx-3 overflow-x-auto overscroll-x-contain">
        <table className="w-full min-w-max border-collapse tabular-nums">
          <thead>
            <tr className="border-b border-panel-hairline-strong">
              <th scope="col" className={`${CABECERA} text-left`}>
                Semana
              </th>
              <CabecerasDelCobro />
              <th scope="col" className={`${CABECERA} text-right`}>
                Pacientes que se financiaron
              </th>
            </tr>
          </thead>
          <tbody>
            {cohortes.map((c) => {
              const elegida = c.semana === semana
              return (
                <tr
                  key={c.semana}
                  onClick={() => void navigate({ to: '/admin/metricas', search: destino(c) })}
                  className={`cursor-pointer border-b border-panel-hairline align-top last:border-0 hover:bg-panel-raised ${
                    elegida ? 'bg-panel-raised shadow-[inset_3px_0_0_var(--color-on-surface)]' : ''
                  }`}
                >
                  <th scope="row" className="px-2.5 py-2 text-left">
                    <Link
                      to="/admin/metricas"
                      search={destino(c)}
                      aria-current={elegida ? 'true' : undefined}
                      aria-label={`Abrir la semana ${semanaLarga(c.semana)}`}
                      onClick={(e) => e.stopPropagation()}
                      className="type-panel-body font-bold text-on-surface"
                    >
                      {rotuloDeSemana(c.semana)}
                    </Link>
                  </th>
                  <CeldasDelCobro cohorte={c} hoy={hoy} />
                  <td className="px-2.5 py-2 text-right type-panel-body text-on-surface-variant">
                    {formatNumero(c.personas, 0)}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      <ul aria-label="Colores de los estados" className="flex flex-wrap gap-x-4 gap-y-1.5">
        {ESTADOS_DE_CUOTA.map((e) => (
          <li key={e} className="inline-flex items-center gap-1.5 type-panel-caption text-on-surface-variant">
            <Muestra color={COLOR_DE_ESTADO[e]} />
            {ROTULO_DE_ESTADO[e]}
          </li>
        ))}
      </ul>
    </SeccionMetricas>
  )
}
