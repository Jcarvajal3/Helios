import { comoDia } from '@/lib/busqueda'

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
// La proyección es siempre de 15 días, día a día: a la clínica se le paga el
// día siguiente al vencimiento de cada cuota, no los lunes. Ya no se elige el
// horizonte (un `?horizonte=` viejo se ignora).
// ═══════════════════════════════════════════════════════════════════════════

export type BusquedaCaja = {
  /** La fecha con la que se abre el formulario del saldo del banco. */
  corte?: string
}

export function validarCaja(raw: Record<string, unknown>): BusquedaCaja {
  return {

    corte: comoDia(raw.corte),
  }
}
