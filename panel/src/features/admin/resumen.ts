import { comoFila, comoLista, numeroONulo } from '@/lib/json'
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
// Comisión Helios; `serviceFeeUsd` es la Comisión Helios sin IVA y va siempre
// aparte; `…DebtUsd` es deuda por cobrar, con la Comisión Helios dentro, y no se
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
  /** Consumo, sin la Comisión Helios. */
  financedUsd: number
  chargeCount: number
  /** Comisión Helios sin IVA. Nunca se suma al consumo. */
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
  /** Lo mismo en deuda, con la Comisión Helios dentro. No se mezcla con lo anterior. */
  writtenOffDebtUsd: number
  /** Deuda viva al cierre del domingo (o ahora, en la semana en curso). */
  openDebtUsd: number
  overdueDebtUsd: number
  /**
   * El desglose de las dos deudas: consumo (sin comisión) y Comisión Helios (con su
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
