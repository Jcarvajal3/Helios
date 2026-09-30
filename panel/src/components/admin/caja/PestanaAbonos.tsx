import type { ReactNode } from 'react'

import { AbonosSinDueno } from '@/components/admin/AbonosSinDueno'
import { AbonosDescartados } from '@/components/admin/caja/AbonosDescartados'
import { FilterBar, Filtro, Segmented } from '@/components/ui'

/** Qué abonos se miran: los que esperan dueño o los que alguien descartó. */
export type EstadoAbonos = 'pendientes' | 'descartados'

export const VALORES_ESTADO_ABONOS: readonly EstadoAbonos[] = ['pendientes', 'descartados']

const ESTADOS: Array<{ value: EstadoAbonos; label: string }> = [
  { value: 'pendientes', label: 'Pendientes' },
  { value: 'descartados', label: 'Descartados' },
]

/**
 * La pestaña «Abonos sin dueño» de Pagos reportados: el dinero que entró al
 * banco y nadie ha reclamado.
 *
 * Pagos reportados parte de lo que dice la persona; esta lista parte de lo que
 * dice el banco. Los descartados son la misma lista acotada por su estado, y
 * por eso van en un filtro y no en otra pestaña.
 */
export function PestanaAbonos({
  estado,
  asignar,
  onEstado,
  onAsignar,
  accion,
}: {
  estado: EstadoAbonos
  /** El abono que se está asignando (`?asignar=`). */
  asignar: string | undefined
  onEstado: (estado: EstadoAbonos) => void
  onAsignar: (id: string | undefined) => void
  /** La acción de la pantalla (importar el extracto): cierra la fila de filtros. */
  accion?: ReactNode
}) {
  return (
    <>
      <FilterBar>
        <Filtro label="Estado">
          <Segmented options={ESTADOS} value={estado} onChange={onEstado} />
        </Filtro>
        {accion && <div className="ml-auto">{accion}</div>}
      </FilterBar>

      {estado === 'pendientes' ? (
        <AbonosSinDueno asignar={asignar} onAsignar={onAsignar} />
      ) : (
        <AbonosDescartados />
      )}
    </>
  )
}
