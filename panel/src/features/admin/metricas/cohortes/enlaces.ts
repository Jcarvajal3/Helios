import { busquedaDeMetricas } from '@/features/admin/metricas/busqueda'
import type { BusquedaMetricas } from '@/features/admin/metricas/busqueda'
import { lunesDe } from '@/features/admin/semana'
import type { BusquedaCohortes } from './busqueda'

// ═══════════════════════════════════════════════════════════════════════════
// Adónde llevan los enlaces de lo que pinta Cohortes (Métricas › Cobros ›
// Semanas).
//
// La semana global ES la cohorte elegida: pulsar una fila de la tabla la
// elige (su curva y su reparto por local salen debajo), cambiando `semana`
// en la URL, con el mismo local. Sus cuotas y quién la debe son de Por
// cobrar › Cohortes. La semana en curso no se escribe
// (el marco la quita igual), para que «esta semana» tenga una sola URL.
//
// Puro: se prueba en `enlaces.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

function semanaEnLaUrl(lunes: string, hoy: string): string | undefined {
  return lunes >= lunesDe(hoy) ? undefined : lunes
}

/**
 * Cobros › Semanas con otra semana elegida, el mismo local y las claves que
 * se pasen.
 */
export function busquedaDeLaSemana(
  lunes: string,
  hoy: string,
  local: string | null,
  propia: BusquedaCohortes,
): BusquedaMetricas {
  return busquedaDeMetricas(
    'cobros',
    propia,
    { semana: semanaEnLaUrl(lunes, hoy), local: local ?? undefined },
    'calendario',
  )
}

/**
 * «Ver sus cuotas y quién la debe»: Por cobrar › Cohortes con esa semana y
 * el mismo local.
 */
export function destinoQuienDebe(lunes: string, local: string | null = null) {
  return {
    to: '/admin/cobranza',
    search: { vista: 'semana', cohorte: lunes, local: local ?? undefined },
  } as const
}
