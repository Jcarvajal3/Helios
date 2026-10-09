import { queryOptions } from '@tanstack/react-query'

import { llamarRpc } from '@/features/admin/metricas/consulta'
import { filas } from '@/lib/json'
import { datosDeAlta, leerCuentaDePago, leerSolicitud } from './clinicas'
import type { AltaDeClinica, CuentaDePagoDeClinica } from './clinicas'

// ═══════════════════════════════════════════════════════════════════════════
// La cuenta a la que Helios le paga a cada clínica (contrato §2.5).
// ═══════════════════════════════════════════════════════════════════════════

export function claveCuentaDePago(merchantId: string) {
  return ['admin-merchant-payout-account', merchantId] as const
}

export function consultaCuentaDePago(merchantId: string) {
  return queryOptions({
    queryKey: claveCuentaDePago(merchantId),
    queryFn: ({ signal }) =>
      llamarRpc('admin_merchant_payout_account', { p_merchant_id: merchantId }, { signal, leer: leerCuentaDePago }),
  })
}

/** Solo super admin; queda en la bitácora. Devuelve la cuenta ya guardada. */
export async function guardarCuentaDePago(params: {
  merchantId: string
  payload: Record<string, string | null>
}): Promise<CuentaDePagoDeClinica | null> {
  return llamarRpc(
    'admin_set_merchant_payout_account',
    { p_merchant_id: params.merchantId, p: params.payload },
    { leer: leerCuentaDePago },
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// El alta y las solicitudes de afiliación de la portada.
// ═══════════════════════════════════════════════════════════════════════════

/** Da de alta una clínica con su titular y su Pago Móvil. Solo super admin. */
export async function crearClinica(alta: AltaDeClinica): Promise<string> {
  const r = await llamarRpc<{ merchant_id: string }>('admin_create_clinic', { p: datosDeAlta(alta) })
  return r.merchant_id
}

export const CLAVE_SOLICITUDES = ['admin-merchant-applications'] as const

/** Las solicitudes pendientes, las más nuevas primero. */
export function consultaSolicitudes() {
  return queryOptions({
    queryKey: CLAVE_SOLICITUDES,
    queryFn: ({ signal }) =>
      llamarRpc('admin_merchant_applications', { p_status: 'pending' }, {
        signal,
        leer: (crudo) => filas(crudo).map(leerSolicitud),
      }),
  })
}

/**
 * Aprueba la solicitud y nace la clínica. `correcciones`: lo que el equipo
 * cambió de los datos del médico (ver `correccionesDeSolicitud`).
 */
export async function aprobarSolicitud(params: {
  id: string
  correcciones: Record<string, string> | null
}): Promise<string> {
  const r = await llamarRpc<{ merchant_id: string }>('admin_approve_merchant_application', {
    p_id: params.id,
    p: params.correcciones,
  })
  return r.merchant_id
}

export async function rechazarSolicitud(params: { id: string; motivo: string }): Promise<void> {
  await llamarRpc('admin_reject_merchant_application', { p_id: params.id, p_reason: params.motivo })
}

/** Corrige el titular: `null` = no tocar, `''` = borrar. Solo super admin. */
export async function guardarTitular(params: {
  merchantId: string
  cambios: { owner_name: string | null; owner_document: string | null; college_number: string | null }
}): Promise<void> {
  await llamarRpc('admin_set_merchant_owner', { p_merchant_id: params.merchantId, p: params.cambios })
}
