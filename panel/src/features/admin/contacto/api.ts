import { queryOptions } from '@tanstack/react-query'

import { llamarRpc } from '@/features/admin/metricas/consulta'
import { leerContacto, leerEstadoDeConfiguracion } from './contacto'
import type { ContactoDeHelios } from './contacto'

// ═══════════════════════════════════════════════════════════════════════════
// El contacto de Helios y el estado de la configuración (contrato §2.3).
// ═══════════════════════════════════════════════════════════════════════════

export const CLAVE_CONTACTO = ['admin-platform-contact'] as const
export const CLAVE_ESTADO_CONFIGURACION = ['helios-config-status'] as const

export function consultaContacto() {
  return queryOptions({
    queryKey: CLAVE_CONTACTO,
    queryFn: ({ signal }) => llamarRpc('admin_platform_contact', {}, { signal, leer: leerContacto }),
  })
}

/** Lo que falta configurar: la lee el aviso de Inicio. */
export function consultaEstadoDeConfiguracion() {
  return queryOptions({
    queryKey: CLAVE_ESTADO_CONFIGURACION,
    queryFn: ({ signal }) => llamarRpc('helios_config_status', {}, { signal, leer: leerEstadoDeConfiguracion }),
    staleTime: 5 * 60_000,
  })
}

/** Solo super admin; queda en la bitácora. Devuelve el contacto ya guardado. */
export async function guardarContacto(payload: Record<string, string | null>): Promise<ContactoDeHelios> {
  return llamarRpc('admin_set_platform_contact', { p: payload }, { leer: leerContacto })
}
