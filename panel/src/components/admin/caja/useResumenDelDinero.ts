import { useQuery } from '@tanstack/react-query'

import { fetchOverview } from '@/features/admin/metrics'

/** La ventana con la que Dinero pide el resumen. */
export const DIAS_DEL_BALANCE = 30

/**
 * El resumen del negocio con el que Dinero lee su caja.
 *
 * «Dinero en caja» sale SIEMPRE de aquí, también en la proyección: la
 * proyección traía su propia caja (`admin_cash_forecast.cash_now_usd`) y,
 * aunque las dos son el mismo saldo del libro (CONTRATOS-D3 §3), dos lecturas
 * de la misma cifra acaban enseñando dos números en cuanto una se refresca
 * antes que la otra. Con una sola clave, las dos pestañas leen el mismo dato.
 */
export function useResumenDelDinero() {
  return useQuery({
    queryKey: ['admin-overview', DIAS_DEL_BALANCE],
    queryFn: () => fetchOverview(DIAS_DEL_BALANCE),
  })
}
