import { keepPreviousData } from '@tanstack/react-query'

import { supabase } from '@/lib/supabase'
import type { CarpetaDeMetricas } from './pestanas'

// ═══════════════════════════════════════════════════════════════════════════
// Cómo lee Métricas de la base. Lo usan todas las pestañas, para que las
// claves de caché, los tiempos y los errores sean los mismos en todas.
//
//   const q = useQuery({
//     queryKey: claveMetricas('cohortes', 'admin_metricas_cohortes', semana, local),
//     queryFn: ({ signal }) =>
//       llamarRpc('admin_metricas_cohortes', argumentosComunes({ semana, local }), { signal, leer: leerCohortes }),
//     ...OPCIONES_METRICAS,
//   })
//
// Una consulta que falla se enseña como fallo (`NoSePudoLeer` o
// `ErrorConReintento`), nunca como un cero.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * La clave de caché de una lectura de Métricas:
 * `['metricas', '<carpeta>', '<rpc>', …partes]`. Las partes son lo que cambia
 * la respuesta —la semana, el local, la sub-vista—, en ese orden.
 *
 * Va por la carpeta que lee (`cohortes`, `cobranza`…) y no por la pestaña
 * donde se pinta: las carpetas no cambian de nombre al mover una sub-pestaña
 * de sitio (27-09: Cohortes y Avisos son Cobros, Cobranza es Mora), así que
 * la caché y quien la invalida siguen hablando de lo mismo.
 */
export function claveMetricas(carpeta: CarpetaDeMetricas, rpc: string, ...partes: unknown[]): readonly unknown[] {
  return ['metricas', carpeta, rpc, ...partes]
}

/**
 * Lo que comparten las consultas de Métricas. Al cambiar de semana o de local
 * se queda a la vista la respuesta anterior hasta que llega la nueva (la
 * pantalla no salta a un esqueleto en cada flecha), y un minuto sin volver a
 * pedir lo mismo.
 */
export const OPCIONES_METRICAS = {
  placeholderData: keepPreviousData,
  staleTime: 60_000,
} as const

/**
 * Lo que tarda como mucho una lectura. Una petición sin contestar deja la
 * pantalla esqueleteando para siempre y sin error que enseñar; con reloj,
 * pasado este tiempo es un fallo con su «Reintentar».
 */
export const ESPERA_MAXIMA_MS = 30_000

/** El error de una lectura que no contestó a tiempo. */
export class LecturaSinRespuesta extends Error {
  constructor(nombre: string) {
    super(`La base no contestó a tiempo (${nombre}). Vuelve a intentarlo en un momento.`)
    this.name = 'LecturaSinRespuesta'
  }
}

/**
 * Los parámetros que llevan todas las RPC de Métricas (CONTRATOS §6):
 * `p_semana` (el lunes) y `p_merchant_id` (`null` es todos los locales).
 */
export function argumentosComunes({
  semana,
  local,
}: {
  semana: string
  local: string | null
}): { p_semana: string; p_merchant_id: string | null } {
  return { p_semana: semana, p_merchant_id: local }
}

/** Una señal que se aborta con la de TanStack Query o al pasar `ms`. */
function conReloj(signal: AbortSignal | undefined, ms: number): { signal: AbortSignal; cancelar: () => void } {
  const control = new AbortController()
  const reloj = setTimeout(() => control.abort(new DOMException('Sin respuesta', 'TimeoutError')), ms)
  const alAbortar = () => control.abort(signal?.reason)
  if (signal?.aborted) control.abort(signal.reason)
  else signal?.addEventListener('abort', alAbortar, { once: true })
  return {
    signal: control.signal,
    cancelar: () => {
      clearTimeout(reloj)
      signal?.removeEventListener('abort', alAbortar)
    },
  }
}

/**
 * Llama a una RPC y devuelve su `data`. Un error de la base se lanza tal cual
 * (el `describeError` de la pantalla sabe leer su `hint`), y una lectura que
 * no contesta en `ESPERA_MAXIMA_MS` se lanza como `LecturaSinRespuesta`.
 *
 * Con `leer`, la respuesta pasa por él (de snake_case a lo que use la
 * pestaña, con `@/lib/json`). Sin él, se devuelve como llegó con el tipo que
 * se pida: es la forma corta para una RPC cuyo JSON ya tiene esa forma.
 *
 * Pasa el `signal` de TanStack Query: si la consulta deja de hacer falta (se
 * cambia de semana antes de que conteste), la petición se corta.
 */
export async function llamarRpc<T>(
  nombre: string,
  args?: Record<string, unknown>,
  opciones: { signal?: AbortSignal; leer?: (crudo: unknown) => T } = {},
): Promise<T> {
  const reloj = conReloj(opciones.signal, ESPERA_MAXIMA_MS)
  try {
    const { data, error } = await supabase.rpc(nombre, args).abortSignal(reloj.signal)
    if (reloj.signal.aborted && !opciones.signal?.aborted) throw new LecturaSinRespuesta(nombre)
    if (error) throw error
    const crudo: unknown = data
    // Sin `leer`, quien llama promete la forma: es la misma promesa que hace
    // `supabase.rpc` sin tipos de la base.
    return opciones.leer ? opciones.leer(crudo) : (crudo as T)
  } finally {
    reloj.cancelar()
  }
}
