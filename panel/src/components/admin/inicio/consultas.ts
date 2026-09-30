import { queryOptions } from '@tanstack/react-query'

import { hoyCaracas } from '@/components/ui'
import {
  fetchMerchantPayables,
  fetchPaymentQueue,
  fetchStatementImports,
} from '@/features/admin/api'
import { ESTADOS_POR_COLA } from '@/features/admin/colaDePagos'
import { fetchUnmatchedDeposits } from '@/features/admin/deposits'
import { fetchCashPosition, fetchDailySeries } from '@/features/admin/metrics'
import { fetchWeeklySummary } from '@/features/admin/resumen'
import {
  CLAVES_RIESGO,
  fetchPrimeraCuota,
  fetchRecuentoDeAlertas,
} from '@/features/admin/riesgo/consultas'
import { lunesDe, semanasAPedir } from '@/features/admin/semana'

// ═══════════════════════════════════════════════════════════════════════════
// Las lecturas de Inicio y de las insignias del menú.
//
// Cada clave es LA MISMA que usa la pantalla a la que lleva la cifra, tope
// incluido: entrar desde Inicio no vuelve a consultar, y la cifra de aquí y
// la lista de allí salen de la misma llamada. Las de Cobranza ya viven en
// `features/admin/cobranza/consultas.ts` y se usan desde allí.
//
// Los topes están copiados de sus pantallas porque allí no se exportan. Si una
// pantalla cambia el suyo, hay que cambiarlo aquí: si no, se hacen dos
// llamadas y las dos cifras pueden no coincidir.
// ═══════════════════════════════════════════════════════════════════════════

/** Cada minuto: es lo que tarda una cola en quedarse vieja sin que nadie lo note. */
const CADA_MINUTO = 60_000

/** El `LIMITE` de `AbonosSinDueno`. */
export const TOPE_ABONOS = 100

/** Los meses de `PrimeraCuota`, en Riesgo de crédito. */
const MESES_PRIMERA_CUOTA = 6

/** Los días de la serie diaria del Resumen (`DIAS_DE_SERIE`). */
const DIAS_DE_SERIE = 14

/** Pagos reportados › Pendientes, y la insignia del menú. */
export function consultaPagosPorAprobar() {
  return queryOptions({
    queryKey: ['payment-queue', 'pendientes'],
    queryFn: () => fetchPaymentQueue(ESTADOS_POR_COLA.pendientes),
    refetchInterval: CADA_MINUTO,
  })
}

/** Abonos sin dueño, con su tope. */
export function consultaAbonosSinDueno() {
  return queryOptions({
    queryKey: ['unmatched-deposits', TOPE_ABONOS],
    queryFn: () => fetchUnmatchedDeposits(TOPE_ABONOS),
    refetchInterval: CADA_MINUTO,
  })
}

/** Lo que se debe a cada local: Pagos a locales, Dinero y el Resumen. */
export function consultaDeudaConLocales() {
  return queryOptions({
    queryKey: ['merchant-payables'],
    queryFn: fetchMerchantPayables,
    refetchInterval: CADA_MINUTO,
  })
}

/** La última importación del extracto, la misma que lee el aviso de Pagos reportados. */
export function consultaUltimoExtracto() {
  return queryOptions({
    queryKey: ['statement-imports', 1],
    queryFn: () => fetchStatementImports(1),
  })
}

/** La caja según el libro, la del Resumen. */
export function consultaCaja() {
  return queryOptions({ queryKey: ['admin-cash'], queryFn: fetchCashPosition })
}

/**
 * Cuántas alertas esperan, sin las filas: la insignia, la fila de «Tu cola» y
 * la cifra de Riesgo. Antes se pedían 500 alertas cada minuto para contarlas.
 */
export function consultaRecuentoDeAlertas() {
  return queryOptions({
    queryKey: CLAVES_RIESGO.recuentoDeAlertas,
    queryFn: fetchRecuentoDeAlertas,
    // Cada cinco minutos y no cada uno: es la lectura más cara del super admin
    // —recalcula todas las alertas para contarlas— y crece con los datos. Las
    // alertas salen de altas, aparatos y consumos, que no cambian de un minuto
    // a otro. Revisar una alerta refresca la cifra al momento: su clave cuelga
    // de `CLAVES_RIESGO.alertas`, que es lo que invalida la revisión.
    refetchInterval: 5 * CADA_MINUTO,
  })
}

/** El impago de la primera cuota por mes, como la pestaña Primera cuota. */
export function consultaPrimeraCuotaPorMes() {
  return queryOptions({
    queryKey: CLAVES_RIESGO.primeraCuota(MESES_PRIMERA_CUOTA, 'mes'),
    queryFn: () => fetchPrimeraCuota(MESES_PRIMERA_CUOTA, 'mes'),
  })
}

/** Las semanas del Resumen cuando se mira la semana en curso. */
export function consultaSemanas() {
  const semanas = semanasAPedir(undefined, lunesDe(hoyCaracas()))
  return queryOptions({
    queryKey: ['admin-weekly-summary', semanas],
    queryFn: () => fetchWeeklySummary(semanas),
  })
}

/** La serie diaria del Resumen: la semana en curso se compara con los mismos días de la anterior. */
export function consultaSerieDiaria() {
  return queryOptions({
    queryKey: ['admin-daily-series', DIAS_DE_SERIE],
    queryFn: () => fetchDailySeries(DIAS_DE_SERIE),
  })
}
