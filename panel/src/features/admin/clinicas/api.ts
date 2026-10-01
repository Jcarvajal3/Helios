import { queryOptions } from '@tanstack/react-query'

import { llamarRpc } from '@/features/admin/metricas/consulta'
import { leerCuentaDePago } from './clinicas'
import type { CuentaDePagoDeClinica } from './clinicas'

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
