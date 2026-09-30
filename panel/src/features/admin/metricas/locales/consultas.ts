import { queryOptions } from '@tanstack/react-query'

import { argumentosDeMerchantStats, leerMerchantStats } from '@/features/admin/api'
import { busquedaDeMetricas } from '@/features/admin/metricas/busqueda'
import type { BusquedaMetricas } from '@/features/admin/metricas/busqueda'
import { OPCIONES_METRICAS, argumentosComunes, claveMetricas, llamarRpc } from '@/features/admin/metricas/consulta'

import { leerLocalesDeLaSemana } from './lectura'

// ═══════════════════════════════════════════════════════════════════════════
// Las tres lecturas de la pestaña Locales, con las claves y los tiempos de
// Métricas (`features/admin/metricas/consulta.ts`):
//
//   admin_metricas_locales  la semana de todos los locales, o de uno.
//   admin_nights            las noches de un local en la semana.
//   admin_merchant_stats    la cartera de un local al cierre de la semana.
//
// Sin React: los componentes las pasan a `useQuery`.
// ═══════════════════════════════════════════════════════════════════════════

/** La semana de los locales (o de uno): lo que pintan la tabla, los gráficos y la ficha. */
export function consultaDeLocales(semana: string, local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('locales', 'admin_metricas_locales', semana, local),
    queryFn: ({ signal }) =>
      llamarRpc('admin_metricas_locales', argumentosComunes({ semana, local }), {
        signal,
        leer: leerLocalesDeLaSemana,
      }),
    ...OPCIONES_METRICAS,
  })
}

/** La cartera de su gente al cierre de la semana, su mora y su punto de empate. */
export function consultaDeCartera(semana: string, local: string) {
  return queryOptions({
    queryKey: claveMetricas('locales', 'admin_merchant_stats', semana, local),
    queryFn: ({ signal }) =>
      llamarRpc('admin_merchant_stats', argumentosDeMerchantStats(local, 7, semana), {
        signal,
        leer: leerMerchantStats,
      }),
    ...OPCIONES_METRICAS,
  })
}

/**
 * La URL de esta pestaña con un local puesto (o quitado, con `null`) y la
 * misma semana. La semana en curso no se escribe: así el enlace sigue siendo
 * «esta semana» mañana.
 */
export function busquedaConLocal({
  semana,
  enCurso,
  local,
}: {
  semana: string
  enCurso: boolean
  local: string | null
}): BusquedaMetricas {
  return busquedaDeMetricas('locales', {}, { semana: enCurso ? undefined : semana, local: local ?? undefined })
}
