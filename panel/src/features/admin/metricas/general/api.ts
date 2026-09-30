import { OPCIONES_METRICAS, claveMetricas, llamarRpc } from '@/features/admin/metricas/consulta'
import { RPC_GENERAL, leerGeneral } from './lectura'
import type { General } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// La lectura de la pestaña General: una sola RPC para todos sus bloques.
//
// La clave de caché lleva el local y NO la semana: General mira desde el
// primer día, así que cambiar de semana arriba no vuelve a pedir nada.
// ═══════════════════════════════════════════════════════════════════════════

/** La clave de caché: `['metricas', 'general', 'admin_metricas_general', local]`. */
export function claveGeneral(local: string | null): readonly unknown[] {
  return claveMetricas('general', RPC_GENERAL, local)
}

/** Las opciones de `useQuery` para General con un local o sin él. */
export function consultaGeneral(local: string | null) {
  return {
    queryKey: claveGeneral(local),
    queryFn: ({ signal }: { signal?: AbortSignal }): Promise<General> =>
      llamarRpc(RPC_GENERAL, { p_merchant_id: local }, { signal, leer: leerGeneral }),
    ...OPCIONES_METRICAS,
  }
}
