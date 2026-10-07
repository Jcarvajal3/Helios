import type { Moneda } from '@/components/ui'
import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'
import { supabase } from '@/lib/supabase'

/**
 * Tasa BCV.
 *
 * Es el único número del sistema que no genera Ronda: entra de fuera, una vez
 * al día, y multiplica todo lo que el usuario paga. El job lo corre la base a
 * las 10 AM (`sync_fx_rate`, migración 20260824100000); esto es la ventana
 * desde la que se ve si llegó, y las dos manos para cuando no llega.
 *
 * Desde el 2026-10-07 son DOS series (`20261007000100_la_tasa_del_euro_vuelve`):
 * `BCV`, la del dólar, y `BCV_EUR`, la del euro. Una orden cobrada en euros se
 * paga en bolívares a la del euro del día del pago; todo lo demás, a la del
 * dólar. Las dos entran a diario con la misma búsqueda.
 */

/** La serie de la base de cada moneda. */
export const SERIE_DE_LA_MONEDA: Record<Moneda, string> = { USD: 'BCV', EUR: 'BCV_EUR' }

export type FxStatus = {
  /** Tasa vigente. null solo si la tabla está vacía — nunca en producción. */
  rate: number | null
  /** Día operativo al que corresponde esa tasa. */
  effectiveDate: string | null
  /** Cuándo entró en la base. */
  fetchedAt: string | null
  /** Día operativo de hoy, según la base (cambia a medianoche de Caracas). */
  businessDate: string
  /** ¿La tasa vigente es la de hoy, o se está arrastrando una anterior? */
  isCurrent: boolean
  ageHours: number | null
  /** Más de 48 h sin que entre una tasa nueva: el job está roto. */
  isStale: boolean
  /**
   * Días **hábiles** que lleva la tasa sin cambiar, saltando fines de semana
   * y feriados del calendario.
   *
   * Es otra cosa que `isStale`, y la que de verdad decide si hay que
   * preocuparse: un jueves santo largo son cuatro días de reloj y cero días
   * hábiles. El BCV no publicó porque no le tocaba.
   */
  businessDaysBehind: number | null
  todayIsHoliday: boolean
  holidayName: string | null
  lastSyncAt: string | null
  lastSyncStatus: string | null
  lastSyncDetail: string | null
}

/** El estado de la tasa de una moneda. Sin moneda, la del dólar: la que lee todo el panel. */
export async function fetchFxStatus(moneda: Moneda = 'USD'): Promise<FxStatus> {
  const { data, error } = await supabase.rpc('fx_rate_status', { p_source: SERIE_DE_LA_MONEDA[moneda] })
  if (error) throw error

  const primera = comoLista(data).at(0)
  if (primera === undefined) throw new Error('La base no devolvió el estado de la tasa')
  const row = comoFila(primera)

  return {
    rate: numeroONulo(row.rate),
    effectiveDate: textoONulo(row.effective_date),
    fetchedAt: textoONulo(row.fetched_at),
    businessDate: String(row.business_date),
    isCurrent: Boolean(row.is_current),
    ageHours: numeroONulo(row.age_hours),
    isStale: Boolean(row.is_stale),
    businessDaysBehind: numeroONulo(row.business_days_behind),
    todayIsHoliday: Boolean(row.today_is_holiday),
    holidayName: textoONulo(row.holiday_name),
    lastSyncAt: textoONulo(row.last_sync_at),
    lastSyncStatus: textoONulo(row.last_sync_status),
    lastSyncDetail: textoONulo(row.last_sync_detail),
  }
}

export type FxHistoryRow = {
  effectiveDate: string
  rate: number
  fetchedAt: string
  sourceKey: string | null
  syncStatus: string | null
  syncDetail: string | null
}

/** Las últimas tasas de una moneda, de la más nueva a la más vieja. */
export async function fetchFxHistory(limit = 30, moneda: Moneda = 'USD'): Promise<FxHistoryRow[]> {
  const { data, error } = await supabase.rpc('admin_fx_rate_history', {
    p_limit: limit,
    p_currency: moneda,
  })
  if (error) throw error

  return comoLista(data)
    .map(comoFila)
    .map((row) => ({
      effectiveDate: String(row.effective_date),
      rate: Number(row.rate),
      fetchedAt: String(row.fetched_at),
      sourceKey: textoONulo(row.source_key),
      syncStatus: textoONulo(row.sync_status),
      syncDetail: textoONulo(row.sync_detail),
    }))
}

/** Lo que trajo la búsqueda de UNA serie. */
export type FxSyncSerie = {
  ok: boolean
  skipped?: boolean
  source?: string
  rate?: number
  effectiveDate?: string
  sourcesTried?: number
  /** Solo si la búsqueda de esa serie reventó en la base. */
  error?: string
}

/** La respuesta de `admin_sync_fx_rate`: la del dólar y, en `eur`, la del euro. */
export type FxSyncResult = FxSyncSerie & { eur: FxSyncSerie | null }

function leerSerie(raw: Record<string, unknown>): FxSyncSerie {
  return {
    ok: Boolean(raw.ok),
    skipped: raw.skipped === undefined ? undefined : Boolean(raw.skipped),
    source: textoONulo(raw.source) ?? undefined,
    rate: raw.rate === undefined || raw.rate === null ? undefined : Number(raw.rate),
    effectiveDate: textoONulo(raw.effective_date) ?? undefined,
    sourcesTried:
      raw.sources_tried === undefined ? undefined : Number(raw.sources_tried),
    error: textoONulo(raw.error) ?? undefined,
  }
}

/** Adelanta el job de las 10 AM, para las dos monedas. No escribe una tasa a dedo: la va a buscar. */
export async function syncFxRate(): Promise<FxSyncResult> {
  const { data, error } = await supabase.rpc('admin_sync_fx_rate')
  if (error) throw error

  const raw = comoFila(data)
  return {
    ...leerSerie(raw),
    eur: raw.eur === undefined || raw.eur === null ? null : leerSerie(comoFila(raw.eur)),
  }
}

/**
 * Carga la tasa a mano. Solo super admin, y queda firmado en la bitácora:
 * quien escribe la tasa decide cuánto paga —y cuánto cobra— todo el mundo ese
 * día. Es la salida para el día en que los espejos estén todos caídos.
 */
export async function setFxRate(params: {
  rate: number
  /** De qué moneda es: la del dólar y la del euro son dos series. */
  moneda: Moneda
  note?: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_fx_rate', {
    p_rate: params.rate,
    p_effective_date: null,
    p_note: params.note?.trim() || null,
    p_currency: params.moneda,
  })
  if (error) throw error
}
