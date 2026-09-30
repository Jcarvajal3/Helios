import type { LucideIcon } from 'lucide-react'

import { PANTALLAS } from '@/features/admin/catalogo'

// ═══════════════════════════════════════════════════════════════════════════
// El icono de cada pestaña y sub-pestaña de Métricas: el mismo que su entrada
// de Ctrl K (`metricas-<pestaña>` y `metricas-<pestaña>-<sub>`, en
// `catalogo/metricas/pantallas.ts`). Así el buscador y las pestañas enseñan
// el mismo dibujo, y un icono se cambia en un solo sitio.
//
// Toda pestaña y sub-pestaña tiene su entrada: lo vigila `destinos.test.ts`.
//
// Puro: se prueba en `iconos.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

const POR_ID = new Map(PANTALLAS.map((p) => [p.id, p.icono]))

/** El icono de una pestaña (`sub` sin dar) o de una de sus sub-pestañas. */
export function iconoDeMetricas(vista: string, sub?: string): LucideIcon | undefined {
  return POR_ID.get(sub ? `metricas-${vista}-${sub}` : `metricas-${vista}`)
}
