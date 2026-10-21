import { comoFila, comoLista, numero, numeroONulo, textoONulo } from '@/lib/json'

/**
 * La lectura de las métricas de la gente.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * El hermano de `metrics.ts`. Aquel cuenta dinero —caja, mora, cartera—; este
 * cuenta personas: cuántas entran, cuántas llegan a comprar, cuántas vuelven,
 * cuánto gasta cada una y si los grupos sirven de algo. Lo pinta Métricas ›
 * Gente; las llamadas viven en `metricas/gente/consultas.ts`.
 *
 * **Aquí no se hace aritmética de negocio.** Todo lo calcula la base (las
 * RPC de Crecimiento, sobre el esquema `metricas`) y esto solo traduce
 * nombres. Puro, sin Supabase: se prueba en `growth.test.ts`.
 *
 * ── Lo que hay que saber para leer estos tipos ─────────────────────────────
 *
 * **`financedUsd` es el consumo sin la comisión.** Lo que se lleva Ronda va en
 * `revenueUsd`, aparte y nunca sumado.
 *
 * **Todo lo que es «por persona» sale de las cuotas, no de los cargos.** En
 * un consumo de grupo cuenta cada persona que pagó su parte.
 *
 * **Un registro es una persona verificada.** Cuenta por el día en que se
 * aprobó su verificación de identidad. Quien pidió el código y no llegó a
 * verificarse solo «solicitó el código» (`requested`): es la boca del
 * embudo, no un registro. `verified` es la misma cifra que `registered`.
 *
 * **Con un local, lo que es del padrón llega `null`.** Los registros, quien
 * pidió el código, el embudo de alta, los estados de las cuentas y los grupos
 * creados no son de ningún local: la pantalla pinta «No se parte por local»,
 * nunca un cero. Por eso esos campos son `| null`.
 *
 * **El rango va y vuelve.** Las funciones de ventana devuelven los dos días
 * QUE USARON (la base recorta un «hasta» futuro a hoy y un «desde» anterior
 * al primer día de Ronda), y la pantalla pinta esos.
 */

/** El trozo de rango que devuelven las cuatro ventanas. */
type ConRango = {
  businessDate: string
  from: string
  to: string
  windowDays: number
  /** El local que se usó, o `null`: todos. */
  merchantId: string | null
}

function rangoDe(raw: Record<string, unknown>): ConRango {
  return {
    businessDate: String(raw.business_date),
    from: String(raw.from),
    to: String(raw.to),
    windowDays: numero(raw.window_days),
    merchantId: textoONulo(raw.merchant_id),
  }
}

// ── Tablero de crecimiento ─────────────────────────────────────────────────

/** Una cifra con su misma cifra en la ventana anterior, para poder decir «sube». */
export type Delta = {
  count: number
  previous: number
}

export type GrowthDay = {
  day: string
  /** Registros (personas verificadas) ese día. `null` con un local: los registros no son de ningún local. */
  registered: number | null
  /** La misma cifra que `registered`: todo registro está verificado. */
  verified: number | null
  /** Pidieron el código ese día, se verificaran o no. `null` con un local. */
  requested: number | null
  /** Primer consumo en Ronda o, con un local, primera cuota en ese local. */
  activated: number
  activeUsers: number
  orders: number
  financedUsd: number
}

export type GrowthOverview = ConRango & {
  /** La ventana contra la que se comparan los `previous`: a la misma altura de la semana. */
  previousFrom: string | null
  previousTo: string | null
  /** Registros: personas cuya verificación de identidad se aprobó en la ventana. */
  registered: Delta | null
  /** La misma cifra que `registered`. */
  verified: Delta | null
  /** Pidieron el código en la ventana, se verificaran o no. No son registros. */
  requested: Delta | null
  /** Primer consumo de su vida caído en la ventana; con un local, primera cuota en él. */
  activated: Delta
  activeUsers: Delta
  orders: Delta
  spend: {
    financedUsd: number
    previousUsd: number
    /** La Comisión Helios SIN IVA de ese consumo. Va aparte, nunca sumado. */
    revenueUsd: number
    perUserUsd: number
    perOrderUsd: number
    ordersPerUser: number
  }
  /** Todos los usuarios, desde el primer día. No sigue la ventana. */
  totals: {
    /** Todos los que pidieron el código, se verificaran o no. */
    requested: number | null
    /** Los que además metieron el código (o ya están verificados). */
    phoneConfirmed: number | null
    /** Los registros: personas verificadas. */
    registered: number | null
    onboarded: number | null
    /** Con un local, quien ha consumido alguna vez en él. */
    everBought: number
    buyersPct: number | null
  }
  series: GrowthDay[]
}

function delta(v: unknown): Delta {
  const raw = comoFila(v)
  return { count: numero(raw.count), previous: numero(raw.previous) }
}

function deltaONulo(v: unknown): Delta | null {
  return v === null || v === undefined ? null : delta(v)
}

export function leerGrowthOverview(data: unknown): GrowthOverview {
  const raw = comoFila(data)
  const spend = comoFila(raw.spend)
  const totals = comoFila(raw.totals)

  return {
    ...rangoDe(raw),
    previousFrom: textoONulo(raw.previous_from),
    previousTo: textoONulo(raw.previous_to),
    registered: deltaONulo(raw.registered),
    verified: deltaONulo(raw.verified),
    requested: deltaONulo(raw.requested),
    activated: delta(raw.activated),
    activeUsers: delta(raw.active_users),
    orders: delta(raw.orders),
    spend: {
      financedUsd: numero(spend.financed_usd),
      previousUsd: numero(spend.previous_usd),
      revenueUsd: numero(spend.revenue_usd),
      perUserUsd: numero(spend.per_user_usd),
      perOrderUsd: numero(spend.per_order_usd),
      ordersPerUser: numero(spend.orders_per_user),
    },
    totals: {
      requested: numeroONulo(totals.requested),
      phoneConfirmed: numeroONulo(totals.phone_confirmed),
      registered: numeroONulo(totals.registered),
      onboarded: numeroONulo(totals.onboarded),
      everBought: numero(totals.ever_bought),
      buyersPct: numeroONulo(totals.buyers_pct),
    },
    series: comoLista(raw.series).map((fila) => {
      const row = comoFila(fila)
      return {
        day: String(row.day),
        registered: numeroONulo(row.registered),
        verified: numeroONulo(row.verified),
        requested: numeroONulo(row.requested),
        activated: numero(row.activated),
        activeUsers: numero(row.active_users),
        orders: numero(row.orders),
        financedUsd: numero(row.financed_usd),
      }
    }),
  }
}

// ── Reparto del gasto ──────────────────────────────────────────────────────

export type Bucket = {
  key: number
  label: string
  users: number
}

export type ConcentrationBlock = {
  key: string
  label: string
  users: number
  financedUsd: number
}

export type LevelRow = {
  level: number
  /** Cuánta gente hay en el nivel. `null` con un local: es del padrón. */
  users: number | null
  activeUsers: number
  financedUsd: number
}

export type StatusRow = {
  status: string
  users: number
}

export type UserBehavior = ConRango & {
  activeUsers: number
  perUser: {
    avgFinancedUsd: number
    /**
     * La mediana, que es la que describe a la persona normal. Si la media
     * dobla a la mediana, el gasto lo sostiene una minoría.
     */
    p50FinancedUsd: number
    p90FinancedUsd: number
    avgOrders: number
    p50Orders: number
    /** Noches distintas con consumo. Dos consumos la misma noche son una noche. */
    avgNights: number
  }
  spendBuckets: Bucket[]
  orderBuckets: Bucket[]
  concentration: ConcentrationBlock[]
  levels: LevelRow[]
  /** Los registros (personas verificadas) por estado. `null` con un local. */
  statuses: StatusRow[] | null
}

function tramos(v: unknown): Bucket[] {
  return comoLista(v).map((tramo) => {
    const b = comoFila(tramo)
    return { key: numero(b.key), label: String(b.label), users: numero(b.users) }
  })
}

export function leerUserBehavior(data: unknown): UserBehavior {
  const raw = comoFila(data)
  const perUser = comoFila(raw.per_user)

  return {
    ...rangoDe(raw),
    activeUsers: numero(raw.active_users),
    perUser: {
      avgFinancedUsd: numero(perUser.avg_financed_usd),
      p50FinancedUsd: numero(perUser.p50_financed_usd),
      p90FinancedUsd: numero(perUser.p90_financed_usd),
      avgOrders: numero(perUser.avg_orders),
      p50Orders: numero(perUser.p50_orders),
      avgNights: numero(perUser.avg_nights),
    },
    spendBuckets: tramos(raw.spend_buckets),
    orderBuckets: tramos(raw.order_buckets),
    concentration: comoLista(raw.concentration).map((bloque) => {
      const c = comoFila(bloque)
      return {
        key: String(c.key),
        label: String(c.label),
        users: numero(c.users),
        financedUsd: numero(c.financed_usd),
      }
    }),
    levels: comoLista(raw.levels).map((nivel) => {
      const l = comoFila(nivel)
      return {
        level: numero(l.level),
        users: numeroONulo(l.users),
        activeUsers: numero(l.active_users),
        financedUsd: numero(l.financed_usd),
      }
    }),
    statuses: Array.isArray(raw.statuses)
      ? comoLista(raw.statuses).map((estado) => {
          const s = comoFila(estado)
          return { status: String(s.status), users: numero(s.users) }
        })
      : null,
  }
}

