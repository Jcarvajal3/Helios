import type { UseQueryResult } from '@tanstack/react-query'
import { CalendarRange } from 'lucide-react'

import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { FraseConCifras } from '@/components/admin/metricas/kit'
import { EmptyState, SkeletonBlock } from '@/components/ui'
import type { BusquedaCohortes } from '@/features/admin/metricas/cohortes/busqueda'
import { comoSeLee, semanaDeEjemplo } from '@/features/admin/metricas/cohortes/frases'
import type { ListaDeCohortes } from '@/features/admin/metricas/cohortes/tipos'
import type { OpcionesDeCambio } from '@/features/admin/metricas/tipos'
import { GraficoDelCobro } from './GraficoDelCobro'
import { LaSemanaElegida } from './LaSemanaElegida'
import { TablaComparada } from './TablaComparada'

/**
 * Cobros › Semanas: lo que hay que cobrar de cada semana en un gráfico
 * (partido por estado) y en la tabla con todas las cohortes, «Cómo se lee»
 * con los números de una semana de verdad (la elegida arriba, si su cuota 1
 * ya vence), y la semana elegida frente a las demás: su curva de cobro y su
 * reparto por local.
 */
export function TodasLasSemanas({
  lista,
  semana,
  local,
  nombreLocal,
  busqueda,
  cambiarBusqueda,
}: {
  lista: UseQueryResult<ListaDeCohortes>
  semana: string
  local: string | null
  nombreLocal: string | null
  busqueda: BusquedaCohortes
  cambiarBusqueda: (parcial: Partial<BusquedaCohortes>, opciones?: OpcionesDeCambio) => void
}) {
  if (lista.isPending) {
    return (
      <div aria-busy className="flex flex-col gap-4">
        <SkeletonBlock className="h-64 w-full rounded-panel-card" />
        <SkeletonBlock className="h-96 w-full rounded-panel-card" />
      </div>
    )
  }
  if (lista.isError) {
    return (
      <ErrorConReintento
        title="No se pudieron leer las semanas"
        error={lista.error}
        onReintentar={() => void lista.refetch()}
      />
    )
  }

  const { cohortes } = lista.data
  const hoyUsado = lista.data.hoy
  if (cohortes.length === 0) {
    return (
      <EmptyState
        icon={<CalendarRange size={40} aria-hidden />}
        title={nombreLocal ? `${nombreLocal} todavía no tiene financiamientos` : 'Todavía no hay financiamientos'}
        description="Cuando haya financiamientos, cada semana saldrá aquí con lo que hay que cobrar de ella."
      />
    )
  }

  return (
    <div
      aria-busy={lista.isFetching || undefined}
      className={`flex flex-col gap-4 transition-opacity duration-[var(--transition-fast)] ${
        lista.isPlaceholderData ? 'opacity-60' : ''
      }`}
    >
      <GraficoDelCobro cohortes={cohortes} semana={semana} />
      <TablaComparada
        cohortes={cohortes}
        semana={semana}
        hoy={hoyUsado}
        local={local}
        nombreLocal={nombreLocal}
        busqueda={busqueda}
      />
      <FraseConCifras
        partes={[{ cifra: 'Cómo se lee: ' }, ...comoSeLee(semanaDeEjemplo(cohortes, semana, hoyUsado), hoyUsado)]}
      />
      <LaSemanaElegida
        semana={semana}
        local={local}
        nombreLocal={nombreLocal}
        busqueda={busqueda}
        cambiarBusqueda={cambiarBusqueda}
      />
    </div>
  )
}
