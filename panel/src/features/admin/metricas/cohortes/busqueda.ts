import { unoDe } from '@/lib/busqueda'

// ═══════════════════════════════════════════════════════════════════════════
// Las claves propias de lo que pinta la carpeta Cohortes (Métricas › Cobros ›
// Resumen y Calendario) en la URL de `/admin/metricas`. Nunca `vista`, `sub`,
// `semana` ni `local`: son del marco. La semana global ES la cohorte
// elegida: elegir una semana en la lista cambia `semana`, no una clave de
// aquí.
//
// «Una semana» y «Comparar todas» ya no son un `modo` de aquí: son las
// sub-pestañas Resumen y Calendario de Cobros, y las elige el marco
// (`pestanas.ts`). Un enlace viejo con `vista=cohortes&modo=todas` lo lleva
// a Calendario `traducirEnlaceViejo`, en `metricas/busqueda.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** La cuota cuya curva de cobro se mira en el detalle. Sin la clave, la 1. */
export const CUOTAS_DE_LA_CURVA = ['1', '2'] as const
export type CuotaDeLaCurva = (typeof CUOTAS_DE_LA_CURVA)[number]

export type BusquedaCohortes = {
  cuota?: CuotaDeLaCurva
}

export function validarCohortes(raw: Record<string, unknown>): BusquedaCohortes {
  return { cuota: unoDe(CUOTAS_DE_LA_CURVA, raw.cuota) }
}
