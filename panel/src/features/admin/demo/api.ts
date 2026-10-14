import { queryOptions } from '@tanstack/react-query'

import { llamarRpc } from '@/features/admin/metricas/consulta'
import { leerEstadoDeDemo, leerReinicio } from './demo'
import type { BorradorDePacienteDemo, EstadoDeDemo, ReinicioDeDemo } from './demo'

// ═══════════════════════════════════════════════════════════════════════════
// Los pacientes demo (20261014100100). Lee cualquiera del equipo; crear,
// cambiar el límite y reiniciar son del super admin y quedan en la bitácora.
// ═══════════════════════════════════════════════════════════════════════════

export const CLAVE_DEMO = ['admin-demo-patients'] as const

export function consultaDemo() {
  return queryOptions({
    queryKey: CLAVE_DEMO,
    queryFn: ({ signal }): Promise<EstadoDeDemo> =>
      llamarRpc('admin_demo_patients', {}, { signal, leer: leerEstadoDeDemo }),
  })
}

export async function crearPacienteDemo(b: BorradorDePacienteDemo): Promise<void> {
  await llamarRpc('admin_create_demo_patient', {
    p_document: b.document,
    p_first_name: b.firstName,
    p_last_name: b.lastName,
    p_phone: b.phone,
    p_email: b.email,
  })
}

export async function cambiarLimiteDemo(limitUsd: number): Promise<void> {
  await llamarRpc('admin_set_demo_limit', { p_limit_usd: limitUsd })
}

/** `userId` null: todos los pacientes demo. */
export async function reiniciarDemo(userId: string | null): Promise<ReinicioDeDemo> {
  return llamarRpc('admin_reset_demo', { p_user_id: userId }, { leer: leerReinicio })
}
