import { CUBOS } from '@/components/admin/crecimiento/cohortes'
import type { Cubo, Medida, VerCohortes } from '@/components/admin/crecimiento/cohortes'
import { comoDia, comoEntero, unoDe } from '@/lib/busqueda'
import { VENTANAS_GENTE } from './ventana'
import type { VentanaGente } from './ventana'

// ═══════════════════════════════════════════════════════════════════════════
// Las claves propias de la pestaña Gente en la URL de `/admin/metricas`.
// Nunca `vista`, `sub`, `semana` ni `local`: son del marco.
//
// Las sub-pestañas (Resumen, Uso, Retención) las elige el marco desde
// `pestanas.ts`. Las claves de la Retención (`cubo`, `cuantos`, `ver`,
// `medida`, `cohorte`) se llaman como en Crecimiento.
//
// Cada clave es `undefined` cuando vale lo de por defecto: así la URL de
// quien no ha tocado nada no se llena.
// ═══════════════════════════════════════════════════════════════════════════

const VER: ReadonlyArray<VerCohortes> = ['una', 'todas']
const MEDIDAS: ReadonlyArray<Medida> = ['gente', 'gasto']

export type BusquedaGente = {
  /** Cuántas semanas mira Resumen y Uso, acabando en la semana elegida. */
  ventana?: VentanaGente
  // La Retención, con su propio eje.
  cubo?: Cubo
  cuantos?: number
  ver?: VerCohortes
  medida?: Medida
  /** El primer día de la cohorte elegida. Sin él, la de la semana elegida. */
  cohorte?: string
}

export function validarGente(raw: Record<string, unknown>): BusquedaGente {
  return {
    ventana: unoDe(VENTANAS_GENTE, raw.ventana),
    cubo: unoDe(CUBOS, raw.cubo),
    cuantos: comoEntero(raw.cuantos, { min: 1, max: 366 }),
    ver: unoDe(VER, raw.ver),
    medida: unoDe(MEDIDAS, raw.medida),
    cohorte: comoDia(raw.cohorte),
  }
}
