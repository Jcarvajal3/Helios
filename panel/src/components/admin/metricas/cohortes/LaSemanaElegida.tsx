import { Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { ArrowRight } from 'lucide-react'

import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { Segmented, SkeletonBlock } from '@/components/ui'
import type { BusquedaCohortes } from '@/features/admin/metricas/cohortes/busqueda'
import { consultaDelDetalle } from '@/features/admin/metricas/cohortes/consultas'
import { destinoQuienDebe } from '@/features/admin/metricas/cohortes/enlaces'
import { cuotaDe } from '@/features/admin/metricas/cohortes/estados'
import { semanaLarga } from '@/features/admin/metricas/cohortes/semanas'
import type { NumeroDeCuota } from '@/features/admin/metricas/cohortes/tipos'
import type { OpcionesDeCambio } from '@/features/admin/metricas/tipos'
import { CurvaDeCobro } from './CurvaDeCobro'
import { PorLocal } from './PorLocal'

const ENLACE =
  'inline-flex items-center gap-1.5 type-panel-label text-on-surface transition-colors duration-[var(--transition-fast)] hover:text-on-surface-variant'

/**
 * Debajo de la comparación de todas las semanas, la semana elegida arriba
 * frente a las demás: la curva de cobro de una de sus cuotas contra la media
 * de las anteriores, y su reparto por local.
 *
 * Sus cuatro cifras, sus dos cuotas y quién la debe viven en Por cobrar ›
 * Cohortes (28-09): es trabajo, no una comparación. Se enlaza.
 */
export function LaSemanaElegida({
  semana,
  local,
  nombreLocal,
  busqueda,
  cambiarBusqueda,
}: {
  semana: string
  local: string | null
  nombreLocal: string | null
  busqueda: BusquedaCohortes
  cambiarBusqueda: (parcial: Partial<BusquedaCohortes>, opciones?: OpcionesDeCambio) => void
}) {
  const detalle = useQuery(consultaDelDetalle(semana, local))
  const d = detalle.data
  const cohorte = d?.cohorte ?? null
  const numero: NumeroDeCuota = busqueda.cuota === '2' ? 2 : 1
  const curva = d?.curvas.find((c) => c.numero === numero)

  return (
    <section
      aria-busy={detalle.isFetching || undefined}
      className={`flex flex-col gap-4 transition-opacity duration-[var(--transition-fast)] ${
        detalle.isPlaceholderData ? 'opacity-60' : ''
      }`}
    >
      <div className="flex min-h-9 flex-wrap items-center gap-x-5 gap-y-2">
        <h2 className="type-panel-section text-on-surface">
          La semana {semanaLarga(semana)}
          {nombreLocal ? ` en ${nombreLocal}` : ''}, frente a las demás
        </h2>
        <div className="ml-auto flex flex-wrap items-center gap-x-5 gap-y-2">
          {cohorte && (
            <Link {...destinoQuienDebe(semana, local)} className={ENLACE}>
              Ver sus cuotas y quién la debe
              <ArrowRight size={14} aria-hidden />
            </Link>
          )}
        </div>
      </div>

      {detalle.isError ? (
        <ErrorConReintento title="No se pudo leer esta semana" error={detalle.error} onReintentar={() => void detalle.refetch()} />
      ) : !d ? (
        <SkeletonBlock className="h-72 w-full rounded-panel-card" />
      ) : cohorte === null ? (
        <p className="type-panel-body text-on-surface-variant">
          {nombreLocal ? `Esa semana no hubo financiamientos en ${nombreLocal}.` : 'Esa semana no hubo financiamientos.'}
        </p>
      ) : (
        <>
          {curva && (
            <CurvaDeCobro
              curva={curva}
              cuota={cuotaDe(cohorte, numero)}
              graciaDias={d.graciaDias}
              controles={
                <Segmented
                  etiqueta="Qué cuota"
                  options={[
                    { value: '1', label: 'Cuota 1' },
                    { value: '2', label: 'Cuota 2' },
                  ]}
                  value={numero === 2 ? '2' : '1'}
                  // La 1 es la de siempre: sin clave en la URL.
                  onChange={(v) => cambiarBusqueda({ cuota: v === '2' ? '2' : undefined }, { reemplazar: true })}
                />
              }
            />
          )}
          {d.porLocal.length > 0 && <PorLocal filas={d.porLocal} hoy={d.hoy} />}
        </>
      )}
    </section>
  )
}
