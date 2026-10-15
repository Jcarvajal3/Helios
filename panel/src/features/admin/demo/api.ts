import { queryOptions } from '@tanstack/react-query'

import { llamarRpc } from '@/features/admin/metricas/consulta'
import { leerEstadoDeDemo, leerReinicio } from './demo'
import type { BorradorDeNumero, EstadoDeDemo, ReinicioDeDemo } from './demo'

// ═══════════════════════════════════════════════════════════════════════════
// Los números de capacitación (20261014100200). Lee cualquiera del equipo;
// añadir, quitar y reiniciar son del super admin y quedan en la bitácora.
// ═══════════════════════════════════════════════════════════════════════════

export const CLAVE_DEMO = ['admin-demo-phones'] as const

export function consultaDemo() {
  return queryOptions({
    queryKey: CLAVE_DEMO,
    queryFn: ({ signal }): Promise<EstadoDeDemo> =>
      llamarRpc('admin_demo_phones', {}, { signal, leer: leerEstadoDeDemo }),
  })
}

export async function anadirNumero(b: BorradorDeNumero): Promise<void> {
  await llamarRpc('admin_add_demo_phone', { p_phone: b.phone, p_label: b.label })
}

export async function quitarNumero(phone: string): Promise<void> {
  await llamarRpc('admin_remove_demo_phone', { p_phone: phone })
}

/** `phone` null: todos los números. */
export async function reiniciarDemo(phone: string | null): Promise<ReinicioDeDemo> {
  return llamarRpc('admin_reset_demo', { p_phone: phone }, { leer: leerReinicio })
}
