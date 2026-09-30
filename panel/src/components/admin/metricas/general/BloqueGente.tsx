import { StatGrid } from '@/components/ui'
import { CifraConTendencia } from '@/components/admin/metricas/kit'
import {
  PIE_REGISTROS,
  entero,
  pctOGuion,
  pieDeQuienesConsumieron,
  pieHanComprado,
  pieSolicitaron,
} from '@/features/admin/metricas/general/cifras'
import { CIFRAS_GENERAL as T } from '@/features/admin/metricas/general/textos'
import { BloqueGeneral } from './BloqueGeneral'
import type { LecturaGeneral } from './lectura'

/** Por qué los registros no tienen local. */
const SIN_LOCAL = 'Registrarse no es de ninguna clínica: esta cifra es de todo Helios. Quita la clínica de arriba para verla.'

/**
 * La gente desde el primer día: cuántos se registraron (un registro es una
 * persona con la verificación de identidad aprobada), cuántos pidieron el
 * código, qué parte de los registros ha comprado, cuántos siguen activos y
 * cuántos repiten. Con un local, solo lo segundo se parte: la gente de ese
 * local.
 */
export function BloqueGente({ lectura }: { lectura: LecturaGeneral }) {
  const { datos: g, estado, local, reintentar } = lectura
  const conLocal = local ?? undefined
  const partido = local !== null

  return (
    <BloqueGeneral titulo="Gente desde el inicio" lectura={lectura}>
      <StatGrid>
        <CifraConTendencia
          titulo={T.registros.titulo}
          info={T.registros.que}
          valor={g?.gente.registros == null ? '' : entero(g.gente.registros)}
          pie={PIE_REGISTROS}
          noSeParte={partido && SIN_LOCAL}
          link={{ to: '/admin/metricas', search: { vista: 'gente', sub: 'resumen' } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.solicitaron.titulo}
          info={T.solicitaron.que}
          valor={g?.gente.solicitaron == null ? '' : entero(g.gente.solicitaron)}
          pie={g && pieSolicitaron(g)}
          noSeParte={partido && SIN_LOCAL}
          link={{ to: '/admin/metricas', search: { vista: 'gente', sub: 'resumen' } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.hanComprado.titulo}
          info={T.hanComprado.que}
          valor={g ? pctOGuion(g.gente.hanCompradoPct) : ''}
          pie={g && pieHanComprado(g)}
          noSeParte={partido && 'Es una parte de los registros, que no son de ninguna clínica. Los de esta clínica están en «Pacientes que se financiaron».'}
          link={{ to: '/admin/metricas', search: { vista: 'gente', sub: 'resumen' } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.activos.titulo}
          info={T.activos.que}
          valor={g ? entero(g.gente.activos) : ''}
          pie={g && pieDeQuienesConsumieron(g.gente.activos, g)}
          link={{ to: '/admin/metricas', search: { vista: 'gente', sub: 'uso', local: conLocal } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.repiten.titulo}
          info={T.repiten.que}
          valor={g ? entero(g.gente.repiten) : ''}
          pie={g && pieDeQuienesConsumieron(g.gente.repiten, g)}
          link={{ to: '/admin/metricas', search: { vista: 'gente', sub: 'uso', local: conLocal } }}
          estado={estado}
          onReintentar={reintentar}
        />
      </StatGrid>
    </BloqueGeneral>
  )
}
