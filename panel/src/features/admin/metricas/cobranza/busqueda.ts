import { unoDe } from '@/lib/busqueda'
import { DIMENSIONES_PRIMERA_CUOTA } from '@/features/admin/riesgo/credito'
import type { DimensionPrimeraCuota, NumeroDeCuota } from '@/features/admin/riesgo/credito'

// ═══════════════════════════════════════════════════════════════════════════
// Las claves propias de lo que pinta la carpeta Cobranza en la URL de
// `/admin/metricas`. Nunca `vista`, `sub`, `semana` ni `local`: son del marco.
//
// Riesgo (Resumen, Cupos, Rendimiento) no tiene claves propias. Impago por
// cuota, que la pinta esta carpeta, vive en Cobros y usa dos:
//   `dim`    el «Partido por»: el mismo nombre que tenía en Riesgo de
//            crédito, así un enlace guardado de allí llega con él;
//   `cuota`  la cuota que se juzga, la misma clave (y los mismos valores,
//            '1' | '2') que el resto de Cobros: la cuota elegida se queda al
//            cambiar de sub-pestaña.
// Los enlaces viejos (`vista=mora&sub=impago-por-cuota`, `sub=deudores`…) los
// lleva a su sitio `traducirEnlaceViejo`, en `metricas/busqueda.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Riesgo no guarda nada suyo en la URL. */
export type BusquedaCobranza = Record<never, never>

export function validarCobranza(_raw: Record<string, unknown>): BusquedaCobranza {
  return {}
}

/** Impago por cuota: por qué se parte. Sin él, por semana. */
export type BusquedaImpago = {
  dim?: DimensionPrimeraCuota
}

export function validarImpago(raw: Record<string, unknown>): BusquedaImpago {
  return { dim: unoDe(DIMENSIONES_PRIMERA_CUOTA.map((d) => d.value), raw.dim) }
}

/** La cuota de la búsqueda de Cobros, con la 1 por defecto. */
export function cuotaDe(b: { cuota?: '1' | '2' }): NumeroDeCuota {
  return b.cuota === '2' ? 2 : 1
}
