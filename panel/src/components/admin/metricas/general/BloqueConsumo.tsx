import { StatGrid, formatUsd } from '@/components/ui'
import { CifraConTendencia } from '@/components/admin/metricas/kit'
import { SIN_DATO, entero, pieLocalesActivos } from '@/features/admin/metricas/general/cifras'
import { CIFRAS_GENERAL as T } from '@/features/admin/metricas/general/textos'
import { BloqueGeneral } from './BloqueGeneral'
import type { LecturaGeneral } from './lectura'

/**
 * El consumo desde el primer día, sin la Comisión Helios: cuánto, en cuántos
 * consumos, el ticket, cuánta gente y en cuántos locales. Con un local, todo
 * es de ese local salvo cuántos locales hay.
 */
export function BloqueConsumo({ lectura }: { lectura: LecturaGeneral }) {
  const { datos: g, estado, local, reintentar } = lectura
  const conLocal = local ?? undefined

  return (
    <BloqueGeneral titulo="Financiamiento desde el inicio" lectura={lectura}>
      <StatGrid>
        <CifraConTendencia
          titulo={T.consumo.titulo}
          info={T.consumo.que}
          valor={g ? formatUsd(g.consumo.financedUsd) : ''}
          link={{ to: '/admin/metricas', search: { vista: 'semana', local: conLocal } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.consumos.titulo}
          info={T.consumos.que}
          valor={g ? entero(g.consumo.consumos) : ''}
          link={{ to: '/admin/metricas', search: { vista: 'semana', local: conLocal } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.ticket.titulo}
          info={T.ticket.que}
          valor={g ? (g.consumo.ticketUsd === null ? SIN_DATO : formatUsd(g.consumo.ticketUsd)) : ''}
          pie={g && g.consumo.ticketUsd === null ? 'Todavía no hay financiamientos' : undefined}
          link={{ to: '/admin/metricas', search: { vista: 'gente', local: conLocal } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.personas.titulo}
          info={T.personas.que}
          valor={g ? entero(g.consumo.personas) : ''}
          pie="Cada paciente cuenta una vez"
          link={{ to: '/admin/metricas', search: { vista: 'gente', local: conLocal } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.localesActivos.titulo}
          info={T.localesActivos.que}
          valor={g?.consumo.localesActivos == null ? '' : entero(g.consumo.localesActivos)}
          pie={g && pieLocalesActivos(g)}
          noSeParte={local !== null && 'Con una clínica elegida no hay clínicas que contar. Quita la clínica de arriba para verlas.'}
          link={{ to: '/admin/metricas', search: { vista: 'locales' } }}
          estado={estado}
          onReintentar={reintentar}
        />
      </StatGrid>
    </BloqueGeneral>
  )
}
