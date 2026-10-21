import { queryOptions } from '@tanstack/react-query'

import type { Rango } from '@/components/ui'
import { leerGrowthOverview, leerUserBehavior } from '@/features/admin/growth'
import { OPCIONES_METRICAS, claveMetricas, llamarRpc } from '@/features/admin/metricas/consulta'

// ═══════════════════════════════════════════════════════════════════════════
// Las lecturas de Métricas › Gente. Cada una lleva la ventana (o su propio
// eje) y el local global, y su clave es `['metricas', 'gente', <rpc>, …]`:
// dos bloques que leen lo mismo comparten caché (Resumen y Uso piden el mismo
// tablero y solo se consulta una vez).
//
// La lectura del JSON es pura y vive en `features/admin/growth.ts` y
// `features/admin/persona.ts`; aquí solo se arma la llamada.
// ═══════════════════════════════════════════════════════════════════════════

/** Los parámetros de ventana de las RPC de Crecimiento. */
function argsDeVentana(rango: Rango, local: string | null) {
  return { p_from: rango.from, p_to: rango.to, p_merchant_id: local }
}

/** Solicitudes del código, registros, primeros consumos, gente que consumió y consumo de la ventana. */
export function consultaDelTablero(rango: Rango, local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('gente', 'admin_growth_overview', rango.from, rango.to, local),
    queryFn: ({ signal }) =>
      llamarRpc('admin_growth_overview', argsDeVentana(rango, local), { signal, leer: leerGrowthOverview }),
    ...OPCIONES_METRICAS,
  })
}

/** Los estados de las cuentas y los niveles (`admin_user_behavior`). */
export function consultaDelUso(rango: Rango, local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('gente', 'admin_user_behavior', rango.from, rango.to, local),
    queryFn: ({ signal }) =>
      llamarRpc('admin_user_behavior', argsDeVentana(rango, local), { signal, leer: leerUserBehavior }),
    ...OPCIONES_METRICAS,
  })
}
