import { supabase } from '@/lib/supabase'
import { leerAlertas, leerRecuentoDeAlertas } from './alertas'
import type { Alertas, RecuentoDeAlertas, TipoAlerta } from './alertas'
import { leerCosechas, leerCurvas } from './cosechas'
import type { Cosechas, CurvasDeCosecha } from './cosechas'
import { leerLocalesPorVolumen, leerPrimeraCuota, leerUsoDelCupo } from './credito'
import type {
  DimensionPrimeraCuota,
  LocalPorVolumen,
  PrimeraCuota,
  UsoDelCupo,
} from './credito'
import { leerFlujo } from './flujo'
import type { FlujoEntreTramos } from './flujo'

// Las llamadas a la base de Riesgo. Van aparte de la lectura (`flujo.ts`,
// `cosechas.ts`, `credito.ts`, `alertas.ts`) para que esa lógica se pruebe en
// Node sin arrastrar el cliente de Supabase.

/** Cómo se mueve la cartera vencida de un lunes al siguiente. */
export async function fetchFlujoEntreTramos(semanas: number): Promise<FlujoEntreTramos> {
  const { data, error } = await supabase.rpc('admin_collection_flow', { p_weeks: semanas })
  if (error) throw error
  return leerFlujo(data)
}

/** Cada cosecha y en qué acabó, hoy. */
export async function fetchCosechas(meses: number): Promise<Cosechas> {
  const { data, error } = await supabase.rpc('admin_credit_cohorts', { p_months: meses })
  if (error) throw error
  return leerCosechas(data)
}

/** Cada cosecha semana a semana de edad. */
export async function fetchCurvasDeCosecha(meses: number): Promise<CurvasDeCosecha> {
  const { data, error } = await supabase.rpc('admin_cohort_curves', { p_months: meses })
  if (error) throw error
  return leerCurvas(data)
}

/** El impago de la primera cuota, partido por `dimension`. */
export async function fetchPrimeraCuota(
  meses: number,
  dimension: DimensionPrimeraCuota,
): Promise<PrimeraCuota> {
  const { data, error } = await supabase.rpc('admin_first_payment_default', {
    p_months: meses,
    p_dim: dimension,
  })
  if (error) throw error
  return leerPrimeraCuota(data, dimension)
}

/** El uso del cupo por nivel. Es la cuenta que frena una compra. */
export async function fetchUsoDelCupo(): Promise<UsoDelCupo> {
  const { data, error } = await supabase.rpc('admin_credit_utilization')
  if (error) throw error
  return leerUsoDelCupo(data)
}

/** Los locales ordenados por consumo del periodo, con su mora. */
export async function fetchLocalesPorVolumen(dias: number): Promise<LocalPorVolumen[]> {
  const { data, error } = await supabase.rpc('admin_merchant_risk', { p_days: dias })
  if (error) throw error
  return leerLocalesPorVolumen(data)
}

/** Las alertas de riesgo. `tipos` en `null` trae todas. */
export async function fetchAlertas(params: {
  limite: number
  tipos: TipoAlerta[] | null
}): Promise<Alertas> {
  const { data, error } = await supabase.rpc('admin_risk_alerts', {
    p_limit: params.limite,
    p_kinds: params.tipos,
  })
  if (error) throw error
  return leerAlertas(data)
}

/**
 * Cuántas alertas esperan, sin las filas. Es lo que piden la insignia del
 * menú y las cifras de Inicio cada minuto; las filas solo las pide su pantalla.
 */
export async function fetchRecuentoDeAlertas(): Promise<RecuentoDeAlertas> {
  const { data, error } = await supabase.rpc('admin_risk_alert_counts')
  if (error) throw error
  return leerRecuentoDeAlertas(data)
}

/** Marca una alerta como revisada. Volver a revisarla pisa la nota y la fecha. */
export async function revisarAlerta(clave: string, nota: string): Promise<void> {
  const { error } = await supabase.rpc('admin_review_risk_alert', {
    p_alert_key: clave,
    p_note: nota || null,
  })
  if (error) throw error
}

/** Las claves de caché de Riesgo, en un solo sitio para poder invalidarlas. */
export const CLAVES_RIESGO = {
  flujo: (semanas: number) => ['riesgo', 'flujo', semanas] as const,
  cosechas: (meses: number) => ['riesgo', 'cosechas', meses] as const,
  curvas: (meses: number) => ['riesgo', 'curvas', meses] as const,
  primeraCuota: (meses: number, dimension: DimensionPrimeraCuota) =>
    ['riesgo', 'primera-cuota', meses, dimension] as const,
  usoDelCupo: ['riesgo', 'uso-del-cupo'] as const,
  locales: (dias: number) => ['riesgo', 'locales', dias] as const,
  alertas: ['riesgo', 'alertas'] as const,
  // Debajo de `alertas`: revisar una alerta invalida las dos.
  recuentoDeAlertas: ['riesgo', 'alertas', 'recuento'] as const,
}
