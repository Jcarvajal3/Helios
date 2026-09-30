import { supabase } from '@/lib/supabase'

/**
 * Cliente de las RPC de métricas del comercio.
 *
 * Ninguna recibe el id del comercio: lo resuelve la base desde la sesión
 * (`my_merchant_id_as_gerente`). Si lo recibiera, el panel podría pedir el de
 * otro local y toda la seguridad dependería de que la RPC se acuerde de
 * comprobarlo — ver 20260822220000.
 *
 * Aquí tampoco se suma ni se promedia nada: los números vienen calculados
 * para que el local y Ronda lean siempre lo mismo.
 */

export type MerchantOverview = {
  businessDate: string
  windowDays: number
  soldUsd: number
  /** Órdenes del periodo. Un cobro de grupo cuenta UNA vez, aunque lo paguen
   *  cinco: el local hizo una venta. La pantalla lo llama "Nro. de órdenes". */
  chargeCount: number
  /** Vendido ÷ órdenes, calculado por `helios_avg_ticket_usd`. La misma cuenta
   *  que usa el historial: antes cada pantalla dividía por su cuenta. */
  avgTicketUsd: number
  /** Días con al menos una venta dentro de la ventana. */
  activeDays: number
  previousSoldUsd: number
  previousChargeCount: number
  commissionPct: number
  /** Lo que le queda al local después de la comisión de Ronda. */
  netUsd: number
  bestDate: string | null
  bestUsd: number
}

export async function fetchMerchantOverview(days = 30): Promise<MerchantOverview> {
  const { data, error } = await supabase.rpc('merchant_overview', { p_days: days })
  if (error) throw error

  const raw = data as Record<string, unknown>
  return {
    businessDate: String(raw.business_date),
    windowDays: Number(raw.window_days),
    soldUsd: Number(raw.sold_usd),
    chargeCount: Number(raw.charge_count),
    avgTicketUsd: Number(raw.avg_ticket_usd),
    activeDays: Number(raw.active_days),
    previousSoldUsd: Number(raw.previous_sold_usd),
    previousChargeCount: Number(raw.previous_charge_count),
    commissionPct: Number(raw.commission_pct),
    netUsd: Number(raw.net_usd),
    bestDate: raw.best_date ? String(raw.best_date) : null,
    bestUsd: Number(raw.best_usd),
  }
}

export type MerchantDayPoint = {
  businessDate: string
  soldUsd: number
  chargeCount: number
}

export async function fetchMerchantDailySeries(days = 30): Promise<MerchantDayPoint[]> {
  const { data, error } = await supabase.rpc('merchant_daily_series', { p_days: days })
  if (error) throw error

  return (data as Array<Record<string, unknown>>).map((row) => ({
    businessDate: String(row.business_date),
    soldUsd: Number(row.sold_usd),
    chargeCount: Number(row.charge_count),
  }))
}

/**
 * CUÁNTAS VECES VUELVE LA GENTE.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Una **visita** es una persona que asumió parte de un cobro confirmado. Un
 * cobro de grupo son cinco visitas y una sola orden, y las dos cifras son
 * ciertas: la orden es la venta, la visita es alguien que volvió a entrar.
 *
 * Por eso esto no se puede derivar del resumen: `chargeCount` cuenta ventas y
 * aquí se cuentan personas.
 */
export type RecurrenceBucket = {
  /** 1, 2, 3 o 4 — donde 4 significa "cuatro o más". */
  times: number
  customers: number
  visits: number
  /** La venta del comercio atribuida a esa gente, repartida por lo que cada
   *  quien asumió de cada cuenta. */
  saleUsd: number
}

export type MerchantRecurrence = {
  businessDate: string
  windowDays: number
  /** Personas distintas que pagaron algo en el local durante la ventana. */
  customers: number
  visits: number
  /** Las que vinieron dos veces o más. */
  returningCustomers: number
  returningPct: number
  saleUsd: number
  returningSaleUsd: number
  /** Siempre los cuatro cubos, aunque estén vacíos: el filtro de la pantalla
   *  tiene que poder responder a los tres botones. */
  buckets: RecurrenceBucket[]
}

export async function fetchMerchantRecurrence(days = 30): Promise<MerchantRecurrence> {
  const { data, error } = await supabase.rpc('merchant_recurrence', { p_days: days })
  if (error) throw error

  const raw = data as Record<string, unknown>
  return {
    businessDate: String(raw.business_date),
    windowDays: Number(raw.window_days),
    customers: Number(raw.customers),
    visits: Number(raw.visits),
    returningCustomers: Number(raw.returning_customers),
    returningPct: Number(raw.returning_pct),
    saleUsd: Number(raw.sale_usd),
    returningSaleUsd: Number(raw.returning_sale_usd),
    buckets: (raw.buckets as Array<Record<string, unknown>>).map((b) => ({
      times: Number(b.times),
      customers: Number(b.customers),
      visits: Number(b.visits),
      saleUsd: Number(b.sale_usd),
    })),
  }
}
