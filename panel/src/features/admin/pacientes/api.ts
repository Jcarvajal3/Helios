import { queryOptions } from '@tanstack/react-query'

import { llamarRpc } from '@/features/admin/metricas/consulta'
import { comoLista } from '@/lib/json'
import { leerCambioPropuesto } from './datos'
import type { CampoEditable, EstadoDeCambio } from './datos'

// ═══════════════════════════════════════════════════════════════════════════
// Corregir los datos de un paciente y resolver los cambios que propone la
// clínica (contrato §2.4). Operador o super admin; todo pide motivo.
// ═══════════════════════════════════════════════════════════════════════════

export const CLAVE_CAMBIOS_PROPUESTOS = ['admin-profile-change-requests'] as const

export function consultaCambiosPropuestos(estado: EstadoDeCambio = 'pendiente') {
  return queryOptions({
    queryKey: [...CLAVE_CAMBIOS_PROPUESTOS, estado],
    queryFn: ({ signal }) =>
      llamarRpc('admin_profile_change_requests', { p_status: estado }, {
        signal,
        leer: (d) => comoLista(d).map(leerCambioPropuesto),
      }),
    refetchInterval: 5 * 60_000,
  })
}

/** Solo los campos que cambian; el motivo es obligatorio y queda en la bitácora. */
export async function actualizarContactoDelPaciente(params: {
  userId: string
  cambios: Partial<Record<CampoEditable, string | null>>
  motivo: string
}): Promise<void> {
  await llamarRpc<unknown>('admin_update_patient_contact', {
    p_user: params.userId,
    p: params.cambios,
    p_reason: params.motivo.trim(),
  })
}

export async function resolverCambioPropuesto(params: {
  id: string
  aprobar: boolean
  nota: string
}): Promise<void> {
  await llamarRpc<unknown>('admin_resolve_profile_change', {
    p_id: params.id,
    p_approve: params.aprobar,
    p_note: params.nota.trim() || null,
  })
}
