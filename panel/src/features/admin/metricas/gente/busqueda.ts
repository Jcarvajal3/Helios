import { unoDe } from '@/lib/busqueda'
import { VENTANAS_GENTE } from './ventana'
import type { VentanaGente } from './ventana'

// ═══════════════════════════════════════════════════════════════════════════
// Las claves propias de la pestaña Pacientes en la URL de `/admin/metricas`.
// Nunca `vista`, `sub`, `semana` ni `local`: son del marco.
//
// Solo la ventana: las claves de la antigua Retención (`cubo`, `cuantos`,
// `ver`, `medida`, `cohorte`) se quitaron con ella y un enlace viejo las
// pierde. Cada clave es `undefined` cuando vale lo de por defecto: así la URL
// de quien no ha tocado nada no se llena.
// ═══════════════════════════════════════════════════════════════════════════

export type BusquedaGente = {
  /** Cuántas semanas mira el Resumen, acabando en la semana elegida. */
  ventana?: VentanaGente
}

export function validarGente(raw: Record<string, unknown>): BusquedaGente {
  return {
    ventana: unoDe(VENTANAS_GENTE, raw.ventana),
  }
}
