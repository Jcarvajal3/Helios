import { comoDia } from '@/lib/busqueda'

// ═══════════════════════════════════════════════════════════════════════════
// Las claves propias de Métricas › Juan Pablo en la URL de `/admin/metricas`.
// Nunca `vista`, `sub`, `semana` ni `local`: son del marco.
//
// El periodo, de `desde` a `hasta` (días operativos, incluidos). Sin ninguna
// de las dos, hoy. Un «desde» sin «hasta» (o al revés) no es un periodo: se
// caen las dos. Lo que pase de hoy lo recorta `rangoElegido`, que sabe qué
// día es.
// ═══════════════════════════════════════════════════════════════════════════

export type BusquedaJuanPablo = {
  /** El primer día del periodo, 'YYYY-MM-DD'. */
  desde?: string
  /** El último, incluido. */
  hasta?: string
}

export function validarJuanPablo(raw: Record<string, unknown>): BusquedaJuanPablo {
  const desde = comoDia(raw.desde)
  const hasta = comoDia(raw.hasta)
  if (!desde || !hasta || desde > hasta) return { desde: undefined, hasta: undefined }
  return { desde, hasta }
}
