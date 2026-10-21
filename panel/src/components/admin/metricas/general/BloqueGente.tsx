import { StatGrid } from '@/components/ui'
import { CifraConTendencia } from '@/components/admin/metricas/kit'
import {
  PIE_REGISTROS,
  entero,
  pctOGuion,
  pieDeQuienesConsumieron,
  pieHanComprado,
} from '@/features/admin/metricas/general/cifras'
import { CIFRAS_GENERAL as T } from '@/features/admin/metricas/general/textos'
import { BloqueGeneral } from './BloqueGeneral'
import type { LecturaGeneral } from './lectura'

/** Por qué los registros no se parten por clínica. */
const SIN_LOCAL = 'Los registros no se parten por clínica: esta cifra es de todo Helios. Quita la clínica de arriba para verla.'

/**
 * Los pacientes desde el primer día: cuántos registraron las clínicas (un
 * registro es un paciente dado de alta, con su primer financiamiento), qué
 * parte de los registros se ha financiado, cuántos siguen activos y cuántos
 * repiten. Con una clínica, solo lo segundo se parte: los pacientes de esa
 * clínica.
 */
export function BloqueGente({ lectura }: { lectura: LecturaGeneral }) {
  const { datos: g, estado, local, reintentar } = lectura
  const conLocal = local ?? undefined
  const partido = local !== null

  return (
    <BloqueGeneral titulo="Pacientes desde el inicio" lectura={lectura}>
      <StatGrid>
        <CifraConTendencia
          titulo={T.registros.titulo}
          info={T.registros.que}
          valor={g?.gente.registros == null ? '' : entero(g.gente.registros)}
          pie={PIE_REGISTROS}
          noSeParte={partido && SIN_LOCAL}
          link={{ to: '/admin/metricas', search: { vista: 'gente' } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.hanComprado.titulo}
          info={T.hanComprado.que}
          valor={g ? pctOGuion(g.gente.hanCompradoPct) : ''}
          pie={g && pieHanComprado(g)}
          noSeParte={partido && 'Es una parte de los registros, que no son de ninguna clínica. Los de esta clínica están en «Pacientes que se financiaron».'}
          link={{ to: '/admin/metricas', search: { vista: 'gente' } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.activos.titulo}
          info={T.activos.que}
          valor={g ? entero(g.gente.activos) : ''}
          pie={g && pieDeQuienesConsumieron(g.gente.activos, g)}
          link={{ to: '/admin/metricas', search: { vista: 'gente', local: conLocal } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.repiten.titulo}
          info={T.repiten.que}
          valor={g ? entero(g.gente.repiten) : ''}
          pie={g && pieDeQuienesConsumieron(g.gente.repiten, g)}
          link={{ to: '/admin/metricas', search: { vista: 'gente', local: conLocal } }}
          estado={estado}
          onReintentar={reintentar}
        />
      </StatGrid>
    </BloqueGeneral>
  )
}
