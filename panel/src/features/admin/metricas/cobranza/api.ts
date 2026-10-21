import { queryOptions } from '@tanstack/react-query'

import { OPCIONES_METRICAS, claveMetricas, llamarRpc } from '@/features/admin/metricas/consulta'
import { leerEfectividadDeCobranza, leerCura, leerRecuperado } from '@/features/admin/cobranza/rendimiento'
import { leerPromesas } from '@/features/admin/cobranza/promesas'
import { leerPrimeraCuota, leerUsoDelCupo } from '@/features/admin/riesgo/credito'
import type { DimensionPrimeraCuota, NumeroDeCuota } from '@/features/admin/riesgo/credito'
import { leerFlujo } from '@/features/admin/riesgo/flujo'
import { leerRecuentoDeAlertas } from '@/features/admin/riesgo/alertas'
import { leerCobroATiempo, leerDiasDeCobro, leerResumenDeCobranza } from './semana'

// ═══════════════════════════════════════════════════════════════════════════
// Las lecturas de Cobranza y riesgo en Métricas, listas para `useQuery`.
//
// Cada una es UNA RPC con la semana y el local de arriba, su clave de caché
// `['metricas', 'cobranza', '<rpc>', …]` y su lectura tipada. Cada bloque de
// la pestaña pide la suya: una que falla deja su hueco con «No se pudo leer»
// y las demás siguen.
//
// Las RPC son las de siempre (Inicio, Por cobrar y el asistente las llaman
// sin local ni semana y reciben lo de antes) más `admin_metricas_cobranza` y
// `admin_deudores_por_perfil`. Ninguna cifra se calcula aquí.
// ═══════════════════════════════════════════════════════════════════════════

/** Cuántos meses de consumos mira el impago por cuota: los mismos que tenía Riesgo. */
export const MESES_IMPAGO_POR_CUOTA = 6

/**
 * Para las tarjetas de la cuota 1 y la 2 basta con los últimos meses: la
 * semana que se juzga está a dos o tres semanas de la elegida.
 */
const MESES_TARJETA_IMPAGO = 3

/** Las semanas de la cura por tramo (Rendimiento): dos meses de lunes. */
export const SEMANAS_DE_CURA = 8

/** La cartera al corte de la semana: vencido, mora, tramos e impago. */
export function consultaResumenDeCobranza(semana: string, local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('cobranza', 'admin_metricas_cobranza', semana, local),
    queryFn: ({ signal }) =>
      llamarRpc(
        'admin_metricas_cobranza',
        { p_semana: semana, p_merchant_id: local },
        { signal, leer: leerResumenDeCobranza },
      ),
    ...OPCIONES_METRICAS,
  })
}

/** Lo que vencía cada día de la semana y lo que entró de eso. */
export function consultaDiasDeCobro(domingo: string, local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('cobranza', 'admin_due_vs_collected', domingo, local),
    queryFn: ({ signal }) =>
      llamarRpc(
        'admin_due_vs_collected',
        { p_days: 7, p_merchant_id: local, p_hasta: domingo },
        { signal, leer: leerDiasDeCobro },
      ),
    ...OPCIONES_METRICAS,
  })
}

/**
 * El paso entre tramos: `semanas` semanas que acaban en el corte (el cierre
 * del domingo, o ahora si la semana está en curso).
 */
export function consultaFlujo(corte: string, local: string | null, semanas = 1) {
  return queryOptions({
    queryKey: claveMetricas('cobranza', 'admin_collection_flow', corte, local, semanas),
    queryFn: ({ signal }) =>
      llamarRpc(
        'admin_collection_flow',
        { p_weeks: semanas, p_merchant_id: local, p_hasta: corte },
        { signal, leer: leerFlujo },
      ),
    ...OPCIONES_METRICAS,
  })
}

/** El cobro a tiempo de las cuotas que vencían en la semana (o las últimas que se pueden juzgar). */
export function consultaCobroATiempo(domingo: string, local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('cobranza', 'admin_on_time_collection', domingo, local),
    queryFn: ({ signal }) =>
      llamarRpc(
        'admin_on_time_collection',
        { p_days: 7, p_merchant_id: local, p_hasta: domingo },
        { signal, leer: leerCobroATiempo },
      ),
    ...OPCIONES_METRICAS,
  })
}

/**
 * El impago de la cuota `cuota` (1 o 2) tras la gracia, partido por
 * `dimension`, con los consumos hasta el domingo elegido.
 *
 * `p_cuota` solo viaja con la 2: la llamada de la 1 es la de siempre y sigue
 * contestando aunque la base aún no sepa juzgar la 2.
 */
export function consultaImpagoDeCuota(
  cuota: NumeroDeCuota,
  dimension: DimensionPrimeraCuota,
  domingo: string,
  local: string | null,
  meses = MESES_IMPAGO_POR_CUOTA,
) {
  return queryOptions({
    queryKey: claveMetricas('cobranza', 'admin_first_payment_default', cuota, dimension, domingo, local, meses),
    queryFn: ({ signal }) =>
      llamarRpc(
        'admin_first_payment_default',
        {
          p_months: meses,
          p_dim: dimension,
          p_merchant_id: local,
          p_hasta: domingo,
          ...(cuota === 1 ? {} : { p_cuota: cuota }),
        },
        { signal, leer: (crudo) => leerPrimeraCuota(crudo, dimension) },
      ),
    ...OPCIONES_METRICAS,
  })
}

/** El impago de una cuota por semana de consumo, para su tarjeta del resumen. */
export function consultaImpagoPorSemana(cuota: NumeroDeCuota, domingo: string, local: string | null) {
  return consultaImpagoDeCuota(cuota, 'semana', domingo, local, MESES_TARJETA_IMPAGO)
}

/** Lo recuperado de lo vencido entre dos días operativos. */
export function consultaRecuperado(desde: string, hasta: string, local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('cobranza', 'admin_collection_recovered', desde, hasta, local),
    queryFn: ({ signal }) =>
      llamarRpc(
        'admin_collection_recovered',
        { p_from: desde, p_to: hasta, p_merchant_id: local },
        { signal, leer: leerRecuperado },
      ),
    ...OPCIONES_METRICAS,
  })
}

/** Las gestiones de esos días y cuántas acabaron en un pago en 72 h. */
export function consultaEfectividad(desde: string, hasta: string, local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('cobranza', 'admin_contact_effectiveness', desde, hasta, local),
    queryFn: ({ signal }) =>
      llamarRpc(
        'admin_contact_effectiveness',
        { p_from: desde, p_to: hasta, p_merchant_id: local },
        { signal, leer: leerEfectividadDeCobranza },
      ),
    ...OPCIONES_METRICAS,
  })
}

/**
 * Las promesas con fecha entre dos días. Sin días, las de siempre (los
 * últimos 30 y todas las futuras): de ahí salen las que vencen hoy.
 */
export function consultaPromesas(local: string | null, desde: string | null = null, hasta: string | null = null) {
  return queryOptions({
    queryKey: claveMetricas('cobranza', 'admin_collection_promises', desde, hasta, local),
    queryFn: ({ signal }) =>
      llamarRpc(
        'admin_collection_promises',
        { p_from: desde, p_to: hasta, p_merchant_id: local },
        { signal, leer: leerPromesas },
      ),
    ...OPCIONES_METRICAS,
  })
}

/** La cura por tramo de las semanas que acaban en el corte. */
export function consultaCura(corte: string, local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('cobranza', 'admin_collection_flow', 'cura', corte, local, SEMANAS_DE_CURA),
    queryFn: ({ signal }) =>
      llamarRpc(
        'admin_collection_flow',
        { p_weeks: SEMANAS_DE_CURA, p_merchant_id: local, p_hasta: corte },
        { signal, leer: leerCura },
      ),
    ...OPCIONES_METRICAS,
  })
}

/** El uso del cupo por nivel (de la gente del local, con local). Es de hoy. */
export function consultaUsoDelCupo(local: string | null) {
  return queryOptions({
    queryKey: claveMetricas('cobranza', 'admin_credit_utilization', local),
    queryFn: ({ signal }) =>
      llamarRpc('admin_credit_utilization', { p_merchant_id: local }, { signal, leer: leerUsoDelCupo }),
    ...OPCIONES_METRICAS,
  })
}

/** Cuántas alertas de riesgo esperan revisión. No se parten por local. */
export function consultaAlertasPendientes() {
  return queryOptions({
    queryKey: claveMetricas('cobranza', 'admin_risk_alert_counts'),
    queryFn: ({ signal }) =>
      llamarRpc('admin_risk_alert_counts', {}, { signal, leer: leerRecuentoDeAlertas }),
    ...OPCIONES_METRICAS,
  })
}
