import { Link } from '@tanstack/react-router'

import { NoSeParte, SeccionMetricas } from '@/components/admin/metricas/kit'
import { topeDelMedidor } from '@/components/admin/tableros/senales'
import { Badge, Meter, NoSePudoLeer, SkeletonList, formatPorcentaje } from '@/components/ui'
import type { BusquedaComun } from '@/features/admin/metricas/busqueda'
import { busquedaDeDestino } from '@/features/admin/metricas/semana/filas'
import type { MetaDeLaSemana } from '@/features/admin/metricas/semana/metas'

const INFO =
  'Cada meta del negocio (Ajustes › Parámetros) con la cifra de la semana elegida, la misma de su fila en la tabla; la marca del medidor es la meta. El total financiado se mide sin la Comisión Helios. Una meta de las que se alcanzan (financiado, pacientes, clínicas) no se pinta de aviso mientras la semana está en curso.'

const MOTIVO_LOCAL = 'Las metas son de todo Helios, no de una clínica. Quita la clínica de arriba para verlas.'

/**
 * Las metas de la semana: cada una con su cifra, un medidor con la meta
 * marcada y un veredicto. Una meta sin valor dice «Sin meta» y, para el
 * super admin, lleva a donde se pone.
 */
export function MetasDeLaSemana({
  metas,
  estado,
  onReintentar,
  comun,
  local,
  esSuperAdmin,
}: {
  metas: ReadonlyArray<MetaDeLaSemana> | null
  estado: 'listo' | 'cargando' | 'error'
  onReintentar: () => void
  comun: BusquedaComun
  local: string | null
  esSuperAdmin: boolean
}) {
  if (local !== null) {
    return (
      <SeccionMetricas titulo="Metas" info={INFO}>
        <NoSeParte variante="bloque" motivo={MOTIVO_LOCAL} />
      </SeccionMetricas>
    )
  }

  const sinNinguna = metas !== null && metas.every((m) => m.meta === null)

  return (
    <SeccionMetricas titulo="Metas" info={INFO}>
      {estado === 'cargando' && <SkeletonList rows={5} />}
      {estado === 'error' && <NoSePudoLeer onReintentar={onReintentar} />}
      {estado === 'listo' && metas && sinNinguna && (
        <p className="type-panel-body text-on-surface-variant">
          Ninguna meta tiene valor todavía. <PonerMetas esSuperAdmin={esSuperAdmin} />
        </p>
      )}
      {estado === 'listo' && metas && !sinNinguna && (
        <ul className="flex flex-col divide-y divide-panel-hairline">
          {metas.map((m) => (
            <FilaDeMeta key={m.clave} meta={m} comun={comun} esSuperAdmin={esSuperAdmin} />
          ))}
        </ul>
      )}
    </SeccionMetricas>
  )
}

function PonerMetas({ esSuperAdmin }: { esSuperAdmin: boolean }) {
  if (!esSuperAdmin) return <>Las pone el super admin en Ajustes › Parámetros.</>
  return (
    <Link
      to="/admin/ajustes"
      search={{ tab: 'parametros' }}
      className="text-on-surface underline decoration-panel-hairline-strong underline-offset-2 hover:decoration-on-surface"
    >
      Ponerlas en Ajustes › Parámetros
    </Link>
  )
}

function FilaDeMeta({
  meta: m,
  comun,
  esSuperAdmin,
}: {
  meta: MetaDeLaSemana
  comun: BusquedaComun
  esSuperAdmin: boolean
}) {
  const escrito = m.valor === null ? 'Sin dato' : m.def.formato(m.valor)

  return (
    <li className="grid gap-2 py-3.5 first:pt-0 last:pb-0 sm:grid-cols-[minmax(0,16rem)_minmax(0,1fr)_minmax(0,11rem)] sm:items-center sm:gap-5">
      <Link
        to="/admin/metricas"
        search={busquedaDeDestino(m.destino, comun)}
        className="type-panel-body font-semibold text-on-surface underline-offset-2 hover:underline"
      >
        {m.rotulo}
      </Link>

      {m.meta === null ? (
        <p className="type-panel-body text-on-surface-variant sm:col-span-2">
          Sin meta. <PonerMetas esSuperAdmin={esSuperAdmin} />
        </p>
      ) : (
        <>
          <div className="flex min-w-0 flex-col gap-1.5">
            <p className="type-panel-body text-on-surface">
              {escrito} <span className="text-panel-muted">de {m.def.formato(m.meta)}</span>
            </p>
            <Meter
              valor={m.valor ?? 0}
              max={topeDelMedidor([m.valor, m.meta])}
              tono={m.veredicto.tono === 'neutral' ? 'area' : m.veredicto.tono}
              marcas={[{ valor: m.meta, rotulo: 'Meta' }]}
              rotulo={`${m.rotulo}: ${escrito} de una meta de ${m.def.formato(m.meta)}`}
            />
          </div>
          <div className="flex flex-wrap items-center gap-2 sm:justify-end">
            {m.progreso?.pct != null && (
              <span className="type-panel-caption text-panel-muted">{formatPorcentaje(m.progreso.pct)}</span>
            )}
            {m.veredicto.tono === 'neutral' ? (
              <span className="type-panel-caption text-on-surface-variant">{m.veredicto.texto}</span>
            ) : (
              <Badge tone={m.veredicto.tono} icono>
                {m.veredicto.texto}
              </Badge>
            )}
          </div>
        </>
      )}
    </li>
  )
}
