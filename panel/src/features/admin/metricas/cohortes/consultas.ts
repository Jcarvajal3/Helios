import { OPCIONES_METRICAS, claveMetricas, llamarRpc } from '@/features/admin/metricas/consulta'
import { leerDetalleDeCohorte, leerListaDeCohortes } from './lectura'

// ═══════════════════════════════════════════════════════════════════════════
// Las dos lecturas de la pestaña Cohortes, listas para `useQuery`:
//
//   const lista = useQuery(consultaDeLaLista(local))
//   const detalle = useQuery(consultaDelDetalle(semana, local))
//
// La lista no depende de la semana (es entre la que se elige): cambiar de
// semana no la vuelve a pedir. El detalle sí.
// ═══════════════════════════════════════════════════════════════════════════

export const RPC_LISTA = 'admin_metricas_cohortes'
export const RPC_DETALLE = 'admin_metricas_cohorte'

/** Todas las cohortes, de un local o de todos. */
export function consultaDeLaLista(local: string | null) {
  return {
    queryKey: claveMetricas('cohortes', RPC_LISTA, local),
    queryFn: ({ signal }: { signal?: AbortSignal }) =>
      llamarRpc(RPC_LISTA, { p_merchant_id: local }, { signal, leer: leerListaDeCohortes }),
    ...OPCIONES_METRICAS,
  }
}

/** El detalle de la cohorte de una semana (su lunes), de un local o de todos. */
export function consultaDelDetalle(semana: string, local: string | null) {
  return {
    queryKey: claveMetricas('cohortes', RPC_DETALLE, semana, local),
    queryFn: ({ signal }: { signal?: AbortSignal }) =>
      llamarRpc(RPC_DETALLE, { p_semana: semana, p_merchant_id: local }, { signal, leer: leerDetalleDeCohorte }),
    ...OPCIONES_METRICAS,
  }
}
