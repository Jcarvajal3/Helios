import { comoFila, comoLista, numeroONulo } from '@/lib/json'
import type { Rango } from '@/components/ui'
import { supabase } from '@/lib/supabase'

// ═══════════════════════════════════════════════════════════════════════════
// Las lecturas del Resumen de Gerencia (migraciones 20260925115000 y
// 20260925117000).
//
// Como en `metrics.ts`, aquí no se hace aritmética de negocio: la semana, la
// mora al cierre y la economía por cada cien euros las calcula la base, que
// también deja fuera las cuentas y los locales de prueba. Esto solo traduce
// nombres.
//
// Cada importe lleva su clase en el nombre: `financedUsd` es consumo sin el
// service fee; `serviceFeeUsd` es el service fee sin IVA y va siempre
// aparte; `…DebtUsd` es deuda por cobrar, con el service fee dentro, y no se
// mezcla con el consumo.
// ═══════════════════════════════════════════════════════════════════════════

// ── La semana ──────────────────────────────────────────────────────────────

/** Una semana operativa, de lunes a domingo por día operativo. */
export type SemanaResumen = {
  /** El lunes. */
  weekStart: string
  /** El domingo. */
  weekEnd: string
  /** Falso en la semana en curso: sus cifras van a medias. */
  complete: boolean
  /** 7, o los días que lleva la semana en curso (hoy incluido). */
  daysElapsed: number
  /** Consumo, sin el service fee. */
  financedUsd: number
  chargeCount: number
  /** Service fee sin IVA. Nunca se suma al consumo. */
  serviceFeeUsd: number
  /** Cargos por atraso caídos en la semana, sin los condonados. */
  lateFeeUsd: number
  lateFeeCollectedUsd: number
  /** Personas que consumieron (por cuotas). No es la suma de los días. */
  activeUsers: number
  merchantsWithSales: number
  newUsers: number
  firstTimeBuyers: number
  writtenOffFinancedUsd: number
  /** Lo mismo en deuda, con el service fee dentro. No se mezcla con lo anterior. */
  writtenOffDebtUsd: number
  /** Deuda viva al cierre del domingo (o ahora, en la semana en curso). */
  openDebtUsd: number
  overdueDebtUsd: number
  /**
   * El desglose de las dos deudas: consumo (sin fee) y service fee (con su
   * IVA), que suman la deuda. `null` si la base todavía no lo manda: no se
   * inventa. Opcionales para no obligar a quien arma una semana a mano.
   */
  openFinancedUsd?: number | null
  openFeeUsd?: number | null
  overdueFinancedUsd?: number | null
  overdueFeeUsd?: number | null
  /**
   * Los usuarios de esas dos deudas, por sus cuotas y sin lo dado por perdido
   * (20260927690000). `null` si la base todavía no los manda.
   */
  overdueUsers?: number | null
  openUsers?: number | null
  /** Mora al cierre. `null` sin deuda viva: no es un 0 %. */
  overduePct: number | null
}

export type ResumenSemanal = {
  businessDate: string
  weeks: number
  from: string
  /** Del lunes más viejo al más nuevo; la última es la semana en curso. */
  rows: SemanaResumen[]
}

function leerSemana(raw: unknown): SemanaResumen {
  const r = comoFila(raw)
  return {
    weekStart: String(r.week_start),
    weekEnd: String(r.week_end),
    complete: r.complete === true,
    daysElapsed: Number(r.days_elapsed ?? 0),
    financedUsd: Number(r.financed_usd ?? 0),
    chargeCount: Number(r.charge_count ?? 0),
    serviceFeeUsd: Number(r.service_fee_usd ?? 0),
    lateFeeUsd: Number(r.late_fee_usd ?? 0),
    lateFeeCollectedUsd: Number(r.late_fee_collected_usd ?? 0),
    activeUsers: Number(r.active_users ?? 0),
    merchantsWithSales: Number(r.merchants_with_sales ?? 0),
    newUsers: Number(r.new_users ?? 0),
    firstTimeBuyers: Number(r.first_time_buyers ?? 0),
    writtenOffFinancedUsd: Number(r.written_off_financed_usd ?? 0),
    writtenOffDebtUsd: Number(r.written_off_debt_usd ?? 0),
    openDebtUsd: Number(r.open_debt_usd ?? 0),
    overdueDebtUsd: Number(r.overdue_debt_usd ?? 0),
    openFinancedUsd: numeroONulo(r.open_financed_usd),
    openFeeUsd: numeroONulo(r.open_fee_usd),
    overdueFinancedUsd: numeroONulo(r.overdue_financed_usd),
    overdueFeeUsd: numeroONulo(r.overdue_fee_usd),
    overdueUsers: numeroONulo(r.overdue_users),
    openUsers: numeroONulo(r.open_users),
    overduePct: numeroONulo(r.overdue_pct),
  }
}

/** Las últimas `semanas` semanas operativas, la en curso incluida (1 a 52). */
export async function fetchWeeklySummary(semanas: number): Promise<ResumenSemanal> {
  const { data, error } = await supabase.rpc('admin_weekly_summary', { p_weeks: semanas })
  if (error) throw error

  const raw = comoFila(data)
  return {
    businessDate: String(raw.business_date),
    weeks: Number(raw.weeks ?? semanas),
    from: String(raw.from),
    rows: comoLista(raw.rows).map(leerSemana),
  }
}

// ── Por cada cien euros financiados ────────────────────────────────────────

/**
 * Lo que dejaron los consumos de un rango, por cosecha
 * (`admin_unit_economics`).
 *
 * Todo sigue a los consumos del rango: su service fee, sus cargos por atraso y lo
 * que de ellos se dio por perdido después. Mientras `matured` sea falso, lo
 * perdido todavía puede subir.
 */
export type EconomiaUnitaria = {
  businessDate: string
  /** El rango que usó el servidor, que recorta un «hasta» futuro a hoy. */
  from: string
  to: string
  windowDays: number
  /** Lo que tarda una cosecha en tener su número final. */
  seasonDays: number
  matured: boolean
  financedUsd: number
  chargeCount: number
  /** Service fee sin IVA, devengado. */
  serviceFeeUsd: number
  /** Cargos por atraso de esas cuotas, sin los condonados. */
  lateFeeUsd: number
  lateFeeCollectedUsd: number
  writtenOffFinancedUsd: number
  writtenOffPct: number | null
  /** El impago al que Ronda deja de ganar dinero con esos consumos. */
  breakEvenPct: number | null
  /** `null` si no hubo consumo en el rango. */
  per100: {
    serviceFeeUsd: number
    lateFeeUsd: number
    writtenOffFinancedUsd: number
  } | null
}

export async function fetchUnitEconomics(rango: Rango): Promise<EconomiaUnitaria> {
  const { data, error } = await supabase.rpc('admin_unit_economics', {
    p_from: rango.from,
    p_to: rango.to,
  })
  if (error) throw error

  const raw = comoFila(data)
  const per100 = raw.per_100 == null ? null : comoFila(raw.per_100)

  return {
    businessDate: String(raw.business_date),
    from: String(raw.from),
    to: String(raw.to),
    windowDays: Number(raw.window_days ?? 0),
    seasonDays: Number(raw.season_days ?? 0),
    matured: raw.matured === true,
    financedUsd: Number(raw.financed_usd ?? 0),
    chargeCount: Number(raw.charge_count ?? 0),
    serviceFeeUsd: Number(raw.service_fee_usd ?? 0),
    lateFeeUsd: Number(raw.late_fee_usd ?? 0),
    lateFeeCollectedUsd: Number(raw.late_fee_collected_usd ?? 0),
    writtenOffFinancedUsd: Number(raw.written_off_financed_usd ?? 0),
    writtenOffPct: numeroONulo(raw.written_off_pct),
    breakEvenPct: numeroONulo(raw.break_even_pct),
    per100: per100
      ? {
          serviceFeeUsd: Number(per100.service_fee_usd ?? 0),
          lateFeeUsd: Number(per100.late_fee_usd ?? 0),
          writtenOffFinancedUsd: Number(per100.written_off_financed_usd ?? 0),
        }
      : null,
  }
}
