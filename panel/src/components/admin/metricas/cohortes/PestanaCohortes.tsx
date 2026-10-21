import { useQuery } from '@tanstack/react-query'

import type { BusquedaCohortes } from '@/features/admin/metricas/cohortes/busqueda'
import { consultaDeLaLista } from '@/features/admin/metricas/cohortes/consultas'
import type { PropsSubpestana } from '@/features/admin/metricas/tipos'
import { TodasLasSemanas } from './TodasLasSemanas'

/**
 * Métricas › Cobros › Semanas: lo consumido cada semana, seguido hasta
 * cobrar sus dos cuotas, comparado entre semanas, y la elegida arriba frente
 * a las demás (su curva de cobro y su reparto por local).
 *
 * Una semana sola —sus cuatro cifras, sus dos cuotas y quién la debe— es
 * trabajo, no una comparación: vive en Por cobrar › Cohortes desde el
 * 28-09, y se enlaza.
 *
 * La semana de arriba ES la cohorte elegida, y el local de arriba filtra
 * todo. Habla en lo que hay que COBRAR: el total a cobrar de una semana es la
 * cuota 1 + la cuota 2, con la Comisión Helios dentro y SIEMPRE con su desglose a
 * la vista (en cobranza la comisión se cobra: Javier, 28-09).
 */
export function PestanaCohortes({
  semana,
  local,
  nombreLocal,
  busqueda,
  cambiarBusqueda,
}: PropsSubpestana<BusquedaCohortes, 'calendario'>) {
  const lista = useQuery(consultaDeLaLista(local))
  const comun = { lista, semana, local, nombreLocal, busqueda }

  return (
    <div className="flex flex-col gap-5">
      <TodasLasSemanas {...comun} cambiarBusqueda={cambiarBusqueda} />
    </div>
  )
}
