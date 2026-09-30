import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'
import { supabase } from '@/lib/supabase'

/**
 * Cliente de las RPC del tablero: el resumen, la serie diaria, el cobro a
 * tiempo y lo que vencía frente a lo cobrado. Los asientos del libro están en
 * `asientos.ts` y la proyección de caja con el saldo del banco, en
 * `proyeccionDeCaja.ts`.
 *
 * Todas devuelven ya el número con el signo que un humano espera leer — el
 * servidor se encarga de la convención contable (pasivo con saldo acreedor).
 * Aquí no se hace ninguna aritmética de negocio a propósito: si el panel
 * calculara la mora por su cuenta, tarde o temprano diría algo distinto de lo
 * que dice el libro.
 *
 * Las respuestas se leen con `comoFila` y `comoLista`, sin `any`: un bloque
 * que falte llega vacío y el número que no venga es `null`, nunca un cero.
 */

// ── Caja y exposición ──────────────────────────────────────────────────────

export type CashPosition = {
  cash: number
  userReceivable: number
  overdueReceivable: number
  /**
   * El principal que sigue fuera, sin el service fee.
   *
   * Sale de `installments.financed_usd`, que es la única columna que sabe
   * repartir una cuota entre lo que descuenta cupo y lo que es fee. El libro
   * no puede darlo: lleva el service fee en una sola cuenta.
   */
  principalOutstanding: number
  merchantPayable: number
  /** Ganada al confirmarse el consumo. */
  platformRevenue: number
  /** La parte de ese service fee que los usuarios ya pagaron de verdad. */
  commissionCollected: number
  writtenOff: number
  fxDifference: number
  committed: number
  freeCapital: number
}

function mapCash(raw: Record<string, unknown>): CashPosition {
  return {
    cash: Number(raw.cash),
    userReceivable: Number(raw.user_receivable),
    overdueReceivable: Number(raw.overdue_receivable),
    principalOutstanding: Number(raw.principal_outstanding ?? 0),
    merchantPayable: Number(raw.merchant_payable),
    platformRevenue: Number(raw.platform_revenue),
    commissionCollected: Number(raw.commission_collected ?? 0),
    writtenOff: Number(raw.written_off),
    fxDifference: Number(raw.fx_difference),
    committed: Number(raw.committed),
    freeCapital: Number(raw.free_capital),
  }
}

export async function fetchCashPosition(): Promise<CashPosition> {
  const { data, error } = await supabase.rpc('admin_cash_position')
  if (error) throw error
  return mapCash(comoFila(data))
}

// ── Cobro a tiempo ─────────────────────────────────────────────────────────

/**
 * Cuántas cuotas se pagaron dentro de plazo, por número de cuota.
 *
 * Es el indicador que avisa antes que la mora: la mora necesita que la cuota
 * ya esté vencida y el impago, sesenta días. Si la cuota 1 se pagaba al día en
 * el 91 % y esta semana va por el 78 %, algo se rompió ahora.
 *
 * `ratePct` es null cuando no venció ninguna cuota en la ventana: un 0 % sin
 * denominador es una alarma inventada.
 */
export type OnTimeRate = {
  sequence: number
  dueCount: number
  onTimeCount: number
  dueUsd: number
  onTimeUsd: number
  ratePct: number | null
}

export type OnTimeCollection = {
  businessDate: string
  windowDays: number
  /**
   * Los vencimientos que se juzgaron: solo los que ya cerraron su plazo, así
   * que `to` es hoy menos la gracia menos uno. `null` si la base no los manda.
   */
  from: string | null
  to: string | null
  /** Los días de gracia que siguen contando como "a tiempo" (los mismos del cargo por atraso). */
  graceDays: number
  /** Por número de cuota: 1 y 2. */
  installments: OnTimeRate[]
}

export async function fetchOnTimeCollection(days = 30): Promise<OnTimeCollection> {
  const { data, error } = await supabase.rpc('admin_on_time_collection', { p_days: days })
  if (error) throw error

  const raw = comoFila(data)

  return {
    businessDate: String(raw.business_date),
    windowDays: Number(raw.window_days),
    from: textoONulo(raw.from),
    to: textoONulo(raw.to),
    graceDays: Number(raw.grace_days),
    installments: Object.values(comoFila(raw.installments))
      .map((cuota) => {
        const r = comoFila(cuota)
        return {
          sequence: Number(r.sequence),
          dueCount: Number(r.due_count),
          onTimeCount: Number(r.on_time_count),
          dueUsd: Number(r.due_usd),
          onTimeUsd: Number(r.on_time_usd),
          ratePct: numeroONulo(r.rate_pct),
        }
      })
      .sort((a, b) => a.sequence - b.sequence),
  }
}

// ── Resumen ────────────────────────────────────────────────────────────────

export type Overview = {
  businessDate: string
  windowDays: number
  /**
   * Desde 20260925120000 hay dos clases de cifra aquí. Las de consumo, sin el
   * service fee, son `financedVolumeUsd`, `previousFinancedVolumeUsd`,
   * `avgTicketFinancedUsd` y `activePeople`. Las de siempre —`financedUsd`,
   * `previousUsd`, `avgTicketUsd`— suman `charges.amount_usd`, que lleva el
   * service fee y su IVA dentro: no se enseñan como consumo ni como volumen.
   */
  volume: {
    /** Lleva el service fee dentro: no es consumo. Usar `financedVolumeUsd`. */
    financedUsd: number
    /** Lleva el service fee dentro. Usar `previousFinancedVolumeUsd`. */
    previousUsd: number
    chargeCount: number
    /** Cuenta a quien abrió el consumo, no a cada persona de un grupo. Usar `activePeople`. */
    activeUsers: number
    /** Lleva el service fee dentro. Usar `avgTicketFinancedUsd`. */
    avgTicketUsd: number
    /** Consumo de la ventana, sin el service fee. */
    financedVolumeUsd: number
    /** Lo mismo en la ventana anterior, del mismo largo. */
    previousFinancedVolumeUsd: number
    /** `null` si la ventana anterior no tuvo consumo. */
    financedChangePct: number | null
    /** Gasto medio por consumo, sin el service fee. `null` sin consumos. */
    avgTicketFinancedUsd: number | null
    /** Personas con cuota en un consumo de la ventana: en un grupo, cada una. */
    activePeople: number
  }
  arrears: {
    /** Lo que queda por cobrar (payable): se enseña con su desglose, `openFinancedUsd` + `openFeeUsd`. */
    openUsd: number
    openFinancedUsd: number
    openFeeUsd: number
    /** Lo vencido (payable), con su desglose. */
    overdueUsd: number
    overdueFinancedUsd: number
    overdueFeeUsd: number
    overdueUsers: number
    dueTodayUsd: number
    /** Deuda vencida sobre deuda viva: las dos llevan el service fee y está bien así. */
    ratePct: number
    /**
     * Los tramos de la escalera, y los umbrales que los definen.
     *
     * Los nombres no llevan el número dentro a propósito: la escalera ya se
     * alargó una vez (15/30 → 30/60 días) y unas claves llamadas `1to14`
     * habrían quedado describiendo un tramo que ya no existe. El servidor manda
     * los días para que las etiquetas se escriban solas.
     */
    demotionDays: number
    expulsionDays: number
    /** Congelado, sin más consecuencia todavía. */
    bucketFrozenUsd: number
    /** Ya cuesta un nivel. */
    bucketDemotionUsd: number
    /** Ya cuesta la cuenta, y con ella el castigo contable. */
    bucketExpulsionUsd: number
  }
  /**
   * Lo que ya se dio por perdido, que no es lo mismo que la mora.
   *
   * `arrears` cuenta lo vencido que TODAVÍA se puede cobrar; esto, lo que se
   * castigó al expulsar. Hasta el 2026-09-02 eran el mismo número mal medido:
   * la deuda castigada seguía en `pending` y la mora del panel no podía bajar
   * nunca.
   *
   * Las cifras de siempre son deuda, con el service fee dentro; las `…Financed…`
   * (desde 20260925120000) son consumo, y la tasa de impago que se enseña es
   * `rateFinancedPct`: el principal que no vuelve sobre lo consumido.
   */
  badDebt: {
    /** Deuda dada por perdida, con el service fee dentro. */
    writtenOffUsd: number
    writtenOffUsers: number
    /** Deuda de toda la historia, con el service fee dentro. Usar `lifetimeFinancedUsd`. */
    financedUsd: number
    /** Deuda castigada dentro de la ventana elegida. */
    windowUsd: number
    /** Deuda perdida ÷ deuda facturada. Usar `rateFinancedPct`. */
    ratePct: number
    /** Consumo dado por perdido, toda la historia. */
    writtenOffFinancedUsd: number
    /** Consumo de toda la historia: el denominador del impago. */
    lifetimeFinancedUsd: number
    /** Consumo dado por perdido dentro de la ventana. */
    windowFinancedUsd: number
    /** Impago: consumo perdido ÷ consumo. `null` sin consumo. */
    rateFinancedPct: number | null
    /**
     * La tasa de impago a la que el negocio deja de ganar dinero.
     *
     * Sale del fee y del neto que se le adelanta al comercio, calculada en la
     * base: el fee subió del 10% al 20% este mes y un umbral escrito a mano en
     * el panel habría quedado mintiendo el mismo día. Null si todavía no hay
     * ventas con las que calcularla.
     */
    breakEvenPct: number | null
  }
  users: {
    /** Registros: personas con la verificación de identidad aprobada. */
    total: number
    /** Registros que aún no terminaron el alta (sin PIN). */
    pendingKyc: number
    active: number
    frozen: number
    suspended: number
    expelled: number
    blacklisted: number
    /** Registros de la ventana, por el día en que se aprobó su verificación. */
    newInWindow: number
    /** Perfiles que pidieron el código por SMS y nunca lo metieron: no son registros. */
    unconfirmedPhone: number
  }
  kyc: {
    pendingReview: number
    processing: number
    approved: number
    rejected: number
    approvalRatePct: number | null
    oldestPendingHours: number
  }
  queues: {
    paymentsToReconcile: number
    /** Lo que se debe a los locales ya vencido: resto de `pending` y `partial`. */
    merchantPayoutsDue: number
    merchantPayoutsPending: number
  }
  merchants: {
    total: number
    active: number
    paused: number
    terminated: number
    sellingInWindow: number
  }
  /** Null si nunca se ha ingerido una tasa. */
  fx: {
    rate: number
    effectiveDate: string
    fetchedAt: string
    ageHours: number
    /** Más de 48 h sin actualizar en día hábil: el scraper se rompió
     *  (docs/05 §1). Cobrar a una tasa vieja es un problema de dinero. */
    stale: boolean
  } | null
  cash: CashPosition
}

export async function fetchOverview(days = 30): Promise<Overview> {
  const { data, error } = await supabase.rpc('admin_overview', { p_days: days })
  if (error) throw error

  const raw = comoFila(data)
  const volume = comoFila(raw.volume)
  const arrears = comoFila(raw.arrears)
  const badDebt = comoFila(raw.bad_debt)
  const users = comoFila(raw.users)
  const kyc = comoFila(raw.kyc)
  const queues = comoFila(raw.queues)
  const merchants = comoFila(raw.merchants)
  const fx = raw.fx ? comoFila(raw.fx) : null

  return {
    businessDate: String(raw.business_date),
    windowDays: Number(raw.window_days),
    volume: {
      financedUsd: Number(volume.financed_usd),
      previousUsd: Number(volume.previous_usd),
      chargeCount: Number(volume.charge_count),
      activeUsers: Number(volume.active_users),
      avgTicketUsd: Number(volume.avg_ticket_usd),
      financedVolumeUsd: Number(volume.financed_volume_usd ?? 0),
      previousFinancedVolumeUsd: Number(volume.previous_financed_volume_usd ?? 0),
      financedChangePct: numeroONulo(volume.financed_change_pct),
      avgTicketFinancedUsd: numeroONulo(volume.avg_ticket_financed_usd),
      activePeople: Number(volume.active_people ?? 0),
    },
    arrears: {
      openUsd: Number(arrears.open_usd),
      openFinancedUsd: Number(arrears.open_financed_usd ?? 0),
      openFeeUsd: Number(arrears.open_fee_usd ?? 0),
      overdueUsd: Number(arrears.overdue_usd),
      overdueFinancedUsd: Number(arrears.overdue_financed_usd ?? 0),
      overdueFeeUsd: Number(arrears.overdue_fee_usd ?? 0),
      overdueUsers: Number(arrears.overdue_users),
      dueTodayUsd: Number(arrears.due_today_usd),
      ratePct: Number(arrears.rate_pct),
      demotionDays: Number(arrears.demotion_days ?? 30),
      expulsionDays: Number(arrears.expulsion_days ?? 60),
      bucketFrozenUsd: Number(arrears.bucket_frozen_usd ?? 0),
      bucketDemotionUsd: Number(arrears.bucket_demotion_usd ?? 0),
      bucketExpulsionUsd: Number(arrears.bucket_expulsion_usd ?? 0),
    },
    badDebt: {
      writtenOffUsd: Number(badDebt.written_off_usd ?? 0),
      writtenOffUsers: Number(badDebt.written_off_users ?? 0),
      financedUsd: Number(badDebt.financed_usd ?? 0),
      windowUsd: Number(badDebt.window_usd ?? 0),
      ratePct: Number(badDebt.rate_pct ?? 0),
      writtenOffFinancedUsd: Number(badDebt.written_off_financed_usd ?? 0),
      lifetimeFinancedUsd: Number(badDebt.lifetime_financed_usd ?? 0),
      windowFinancedUsd: Number(badDebt.window_financed_usd ?? 0),
      rateFinancedPct: numeroONulo(badDebt.rate_financed_pct),
      breakEvenPct: numeroONulo(badDebt.break_even_pct),
    },
    users: {
      total: Number(users.total),
      pendingKyc: Number(users.pending_kyc),
      active: Number(users.active),
      frozen: Number(users.frozen),
      suspended: Number(users.suspended),
      expelled: Number(users.expelled),
      blacklisted: Number(users.blacklisted),
      newInWindow: Number(users.new_in_window),
      unconfirmedPhone: Number(users.unconfirmed_phone ?? 0),
    },
    kyc: {
      pendingReview: Number(kyc.pending_review),
      processing: Number(kyc.processing),
      approved: Number(kyc.approved),
      rejected: Number(kyc.rejected),
      approvalRatePct: numeroONulo(kyc.approval_rate_pct),
      oldestPendingHours: Number(kyc.oldest_pending_hours),
    },
    queues: {
      paymentsToReconcile: Number(queues.payments_to_reconcile),
      merchantPayoutsDue: Number(queues.merchant_payouts_due),
      merchantPayoutsPending: Number(queues.merchant_payouts_pending),
    },
    merchants: {
      total: Number(merchants.total),
      active: Number(merchants.active),
      paused: Number(merchants.paused),
      terminated: Number(merchants.terminated),
      sellingInWindow: Number(merchants.selling_in_window),
    },
    fx: fx
      ? {
          rate: Number(fx.rate),
          effectiveDate: String(fx.effective_date),
          fetchedAt: String(fx.fetched_at),
          ageHours: Number(fx.age_hours),
          stale: Boolean(fx.stale),
        }
      : null,
    cash: mapCash(comoFila(raw.cash)),
  }
}

// ── Serie diaria ───────────────────────────────────────────────────────────

/**
 * Un día operativo del negocio (`admin_daily_series`).
 *
 * Desde 20260925115000 `financedUsd` es consumo de verdad, sin el service fee
 * (antes sumaba `charges.amount_usd`, con el fee dentro). Hay una fila por
 * día, también los días sin nada: aquí un cero sí es un dato. El último día
 * es hoy y va a medias.
 */
export type DayPoint = {
  businessDate: string
  /** Consumo del día, sin el service fee. */
  financedUsd: number
  chargeCount: number
  /** Cuotas cobradas ese día, con el service fee dentro: es lo que se pagó. */
  collectedUsd: number
  settledUsd: number
  /** El service fee de los consumos del día, sin IVA. Nunca se suma al consumo. */
  serviceFeeUsd: number
  /** Cargos por atraso que cayeron ese día, sin los condonados. */
  lateFeeUsd: number
  /** Personas que consumieron ese día (por cuotas). */
  activeUsers: number
  merchantsWithSales: number
  /** Registros: teléfono confirmado. */
  newUsers: number
  /** Personas cuyo primer consumo fue ese día. */
  firstTimeBuyers: number
  /** Consumo dado por perdido ese día. */
  writtenOffFinancedUsd: number
}

export async function fetchDailySeries(days = 30): Promise<DayPoint[]> {
  const { data, error } = await supabase.rpc('admin_daily_series', { p_days: days })
  if (error) throw error

  return comoLista(data).map((fila) => {
    const row = comoFila(fila)
    return {
      businessDate: String(row.business_date),
      financedUsd: Number(row.financed_usd ?? 0),
      chargeCount: Number(row.charge_count ?? 0),
      collectedUsd: Number(row.collected_usd ?? 0),
      settledUsd: Number(row.settled_usd ?? 0),
      serviceFeeUsd: Number(row.service_fee_usd ?? 0),
      lateFeeUsd: Number(row.late_fee_usd ?? 0),
      activeUsers: Number(row.active_users ?? 0),
      merchantsWithSales: Number(row.merchants_with_sales ?? 0),
      newUsers: Number(row.new_users ?? 0),
      firstTimeBuyers: Number(row.first_time_buyers ?? 0),
      writtenOffFinancedUsd: Number(row.written_off_financed_usd ?? 0),
    }
  })
}

// ── Vencía vs. cobrado ─────────────────────────────────────────────────────

/**
 * De lo que tocaba cobrar cada día, cuánto entró.
 *
 * Reemplaza a financiado-vs-cobrado: con cuotas a 7 y 14 días, esas dos series
 * no hablan del mismo dinero y la distancia entre ellas es aritmética del
 * plazo, no un problema de cobro.
 */
export type DueVsCollected = {
  businessDate: string
  dueUsd: number
  dueCount: number
  collectedUsd: number
  collectedCount: number
}

export async function fetchDueVsCollected(days = 30): Promise<DueVsCollected[]> {
  const { data, error } = await supabase.rpc('admin_due_vs_collected', { p_days: days })
  if (error) throw error

  return comoLista(data).map((fila) => {
    const row = comoFila(fila)
    return {
      businessDate: String(row.business_date),
      dueUsd: Number(row.due_usd),
      dueCount: Number(row.due_count),
      collectedUsd: Number(row.collected_usd),
      collectedCount: Number(row.collected_count),
    }
  })
}
