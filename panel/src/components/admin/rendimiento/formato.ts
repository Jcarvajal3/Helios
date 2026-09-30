import { formatDay, formatPct } from '@/components/ui'
import { rotuloDeTramo } from '@/features/admin/tramos'
import type { CortesDeTramo, TramoVencido } from '@/features/admin/tramos'

/** «Sin datos» y no «0 %»: un porcentaje sin denominador no es un cero. */
export function pctOSinDatos(pct: number | null): string {
  return pct === null ? 'Sin datos' : formatPct(pct)
}

/** El rótulo de un tramo con los cortes vigentes, o su clave si todavía no llegan. */
export function rotuloDelTramo(t: TramoVencido, cortes: CortesDeTramo | null): string {
  return cortes ? rotuloDeTramo(t, cortes) : t
}

/** 'del 18/09/26 al 25/09/26'. */
export function describirPeriodo(desde: string, hasta: string): string {
  return `del ${formatDay(desde)} al ${formatDay(hasta)}`
}
