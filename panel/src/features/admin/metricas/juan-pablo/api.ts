import type { Rango } from '@/components/ui'
import { OPCIONES_METRICAS, claveMetricas, llamarRpc } from '@/features/admin/metricas/consulta'
import { RPC_JUAN_PABLO, leerJuanPablo } from './lectura'
import type { JuanPablo } from './lectura'

// ═══════════════════════════════════════════════════════════════════════════
// La única lectura de Métricas › Juan Pablo. La clave lleva el periodo y no
// la semana ni la clínica: Juan Pablo no mira ninguna de las dos.
// ═══════════════════════════════════════════════════════════════════════════

/** Las opciones de `useQuery` para un periodo. No se parte por clínica. */
export function consultaDeJuanPablo(rango: Rango) {
  return {
    queryKey: claveMetricas('juan-pablo', RPC_JUAN_PABLO, rango.from, rango.to),
    queryFn: ({ signal }: { signal?: AbortSignal }): Promise<JuanPablo> =>
      llamarRpc(RPC_JUAN_PABLO, { p_desde: rango.from, p_hasta: rango.to }, { signal, leer: leerJuanPablo }),
    ...OPCIONES_METRICAS,
  }
}
