import { queryOptions } from '@tanstack/react-query'

import { OPCIONES_METRICAS, argumentosComunes, claveMetricas, llamarRpc } from '@/features/admin/metricas/consulta'
import { leerCaja, leerFoto, leerProyeccion } from './lectura'


// ═══════════════════════════════════════════════════════════════════════════
// Las lecturas de Métricas › Caja, con la semana y el local globales. La
// lectura del JSON es pura y vive en `lectura.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Lo que se movió en la semana, la anterior a la misma altura, la caja al
 * cierre y ocho semanas para las chispas (`admin_metricas_caja`).
 */
export function consultaDeLaSemana(semana: string, local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('caja', 'admin_metricas_caja', semana, local),
    queryFn: ({ signal }) =>
      llamarRpc('admin_metricas_caja', argumentosComunes({ semana, local }), { signal, leer: leerCaja }),
    ...OPCIONES_METRICAS,
  })
}

/**
 * La foto de hoy (`admin_cash_position`): lo que se debe, lo perdido y el
 * Comisión Helios, con su desglose. No sigue a la semana: es de hoy.
 */
export function consultaDeLaFoto(local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('caja', 'admin_cash_position', local),
    queryFn: ({ signal }) =>
      llamarRpc('admin_cash_position', { p_merchant_id: local }, { signal, leer: leerFoto }),
    ...OPCIONES_METRICAS,
  })
}

/**
 * Los días que se proyectan. A la clínica se le paga el día siguiente al
 * vencimiento de cada cuota (días 8 y 15 de cada orden), así que lo que hoy
 * está en la calle entra y sale entero en los próximos 15 días.
 */
export const DIAS_DE_PROYECCION = 15

/** La proyección día a día desde hoy (`admin_cash_forecast_days`), con el desglose de lo que vence. */
export function consultaDeLaProyeccion(local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('caja', 'admin_cash_forecast_days', DIAS_DE_PROYECCION, local),
    queryFn: ({ signal }) =>
      llamarRpc(
        'admin_cash_forecast_days',
        { p_days: DIAS_DE_PROYECCION, p_merchant_id: local },
        { signal, leer: leerProyeccion },
      ),
    ...OPCIONES_METRICAS,
  })
}
