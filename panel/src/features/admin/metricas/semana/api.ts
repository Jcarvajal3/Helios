import { OPCIONES_METRICAS, claveMetricas, llamarRpc } from '@/features/admin/metricas/consulta'
import { leerRespuestaSemanas } from './lectura'
import type { RespuestaSemanas } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// La única lectura de la pestaña Semana: `admin_metricas_semanas`.
//
// Una sola RPC para las cinco cifras, la frase, la tabla y las metas: todo
// sale de la misma respuesta, así que no hay dos números del mismo concepto
// que puedan llegar desincronizados.
// ═══════════════════════════════════════════════════════════════════════════

export const RPC_SEMANAS = 'admin_metricas_semanas'

/**
 * Las opciones de `useQuery` para `semanas` semanas que acaban en la de
 * `semana` (su lunes), de todos los locales o de `local`. Al cambiar de
 * semana, de local o de columnas se queda a la vista lo anterior hasta que
 * llega lo nuevo.
 */
export function consultaDeSemanas({
  semana,
  local,
  semanas,
}: {
  semana: string
  local: string | null
  semanas: number
}) {
  return {
    queryKey: claveMetricas('semana', RPC_SEMANAS, semana, local, semanas),
    queryFn: ({ signal }: { signal?: AbortSignal }): Promise<RespuestaSemanas> =>
      llamarRpc(
        RPC_SEMANAS,
        { p_hasta: semana, p_semanas: semanas, p_merchant_id: local },
        { signal, leer: leerRespuestaSemanas },
      ),
    ...OPCIONES_METRICAS,
  }
}
