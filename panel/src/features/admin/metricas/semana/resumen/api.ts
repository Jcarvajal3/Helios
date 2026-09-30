import { queryOptions } from '@tanstack/react-query'

import { OPCIONES_METRICAS, argumentosComunes, claveMetricas, llamarRpc } from '@/features/admin/metricas/consulta'
import { leerResumen } from './lectura'

// ═══════════════════════════════════════════════════════════════════════════
// La lectura de Semana › Resumen, con las claves y los tiempos de Métricas
// (`features/admin/metricas/consulta.ts`). Una sola: las cinco cifras, sus
// chispas y la tabla de noches salen de la misma respuesta, así que no pueden
// decir cosas distintas. Sin React: el componente la pasa a `useQuery`.
// ═══════════════════════════════════════════════════════════════════════════

/** La semana elegida (o la de un local): cifras, comparación, chispa y noches. */
export function consultaDelResumen(semana: string, local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('semana', 'admin_metricas_semana_resumen', semana, local),
    queryFn: ({ signal }) =>
      llamarRpc('admin_metricas_semana_resumen', argumentosComunes({ semana, local }), {
        signal,
        leer: leerResumen,
      }),
    ...OPCIONES_METRICAS,
  })
}
