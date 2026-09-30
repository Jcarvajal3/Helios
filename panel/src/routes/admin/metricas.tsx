import { createFileRoute, useNavigate } from '@tanstack/react-router'

import { MarcoMetricas } from '@/components/admin/metricas/MarcoMetricas'
import { diaOperativo } from '@/components/ui'
import { validarBusquedaMetricas } from '@/features/admin/metricas/busqueda'
import type { BusquedaMetricas } from '@/features/admin/metricas/busqueda'

/**
 * Métricas: todas las cifras del super admin en una pantalla, con la semana
 * y el local arriba, siete pestañas y sus sub-pestañas
 * (`features/admin/metricas/pestanas.ts`).
 */
export const Route = createFileRoute('/admin/metricas')({
  staticData: { title: 'Métricas', width: 'wide' },
  // Lo común (`vista`, `sub`, `semana`, `local`) y solo las claves de la
  // pestaña activa, con su validador. La semana se lleva a su lunes y nunca
  // es futura; la en curso no se escribe, para no reescribir la URL de quien
  // entra sin elegir nada.
  validateSearch: (search: Record<string, unknown>): BusquedaMetricas =>
    validarBusquedaMetricas(search, diaOperativo()),
  component: MetricasPage,
})

function MetricasPage() {
  const navigate = useNavigate({ from: '/admin/metricas' })
  const busqueda = Route.useSearch()

  return (
    <MarcoMetricas
      busqueda={busqueda}
      hoy={diaOperativo()}
      navegar={(search, opciones) => void navigate({ search, replace: opciones?.reemplazar ?? false })}
    />
  )
}
