import { comoDia, unoDe } from '@/lib/busqueda'

// ═══════════════════════════════════════════════════════════════════════════
// Las claves propias de la pestaña Caja en la URL de `/admin/metricas`.
// Nunca `vista`, `sub`, `semana` ni `local`: son del marco.
//
// Las sub-pestañas (Balance, Proyección y banco) las elige el marco desde
// `pestanas.ts`; `/admin/dinero?tab=balance|proyeccion` llega a ellas con
// `redirecciones.ts`. `corte` se llama como en Dinero: el cierre de mes
// enlaza con la fecha del saldo del banco ya puesta, y un enlace guardado la
// conserva.
//
// Cuántas semanas proyectar va en `horizonte` y no en `semanas` (su nombre en
// Dinero): aquí «semana» ya es la del marco.
// ═══════════════════════════════════════════════════════════════════════════

/** Las semanas de proyección que se ofrecen. La base no pasa de doce. */
export const HORIZONTES = ['4', '8', '12'] as const
export type Horizonte = (typeof HORIZONTES)[number]

export type BusquedaCaja = {
  /** Cuántas semanas proyectar. Sin él, cuatro. */
  horizonte?: Horizonte
  /** La fecha con la que se abre el formulario del saldo del banco. */
  corte?: string
}

export function validarCaja(raw: Record<string, unknown>): BusquedaCaja {
  return {
    horizonte: unoDe(HORIZONTES, raw.horizonte),
    corte: comoDia(raw.corte),
  }
}
