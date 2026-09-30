import { supabase } from '@/lib/supabase'

/**
 * Cuándo cobra el comercio una de las dos cuotas de una orden.
 *
 * 🔁 **Antes era el estado de la cuota** —Pendiente / En mora / Pagado— y se
 * quitó el 2026-09-02: eso es la deuda del CLIENTE con Ronda, y en la pantalla
 * de un local un "En mora" en rojo sobre una venta propia se lee como "esto no
 * me lo van a pagar". Es al revés (docs/05 §3). Lo que el dueño viene a mirar
 * es cuándo entra el dinero, que desde el cierre semanal tiene fecha exacta.
 *
 * `paidToMerchantOn` es el lunes del cierre que paga esa cuota, y lo calcula
 * la base (`helios_settlement_run_for`): el calendario del cierre vive en un
 * solo sitio, no repartido entre las pantallas que lo pintan.
 *
 * Viene SIEMPRE. Hubo un intento de dejarlo en null para las ventas que se
 * liquidaron enteras el día del cobro (20260902131000) y en pantalla no se
 * entendía: una columna que a veces trae fecha y a veces una frase obliga a
 * aprenderse un caso de borde para leer la tabla.
 */
export type TransactionInstallment = {
  dueDate: string
  paidToMerchantOn: string
} | null

/**
 * Una venta del día.
 *
 * Desde 2026-09-19 incluye el NOMBRE de quien compró, y solo el nombre: era
 * la decisión de producto que docs/00-BASES §3.11 dejaba abierta («¿El local
 * puede ver quién es el cliente?»). Se resolvió como decía el plan: la RLS
 * del comercio sigue sin dejarle leer `profiles`, y el nombre lo devuelve la
 * RPC —`security definer`— sin teléfono, sin cédula y sin identificador.
 */
export type DayTransaction = {
  id: string
  orderNumber: number
  /** Día operativo al que pertenece la venta (`YYYY-MM-DD`). Es por lo que se
   *  agrupa y se filtra: una venta de las 2 AM cuenta para la noche anterior. */
  businessDate: string
  confirmedAt: string | null
  /**
   * LA VENTA DEL COMERCIO, que NO es el `amount_usd` del cobro.
   *
   * `amount_usd` es lo que debe el consumidor: el precio de los productos más
   * el fee del servicio y su IVA (docs/00-BASES §2.11). Enseñárselo al local
   * como "su venta" le infla los ingresos un 11,6 % — y hasta el 2026-08-30 era
   * un 27,6 %, porque además llevaba dentro el IVA de la venta.
   */
  merchantSaleUsd: number
  /**
   * Quien escaneó el QR y se quedó con la cuenta. En un cobro de grupo, quien
   * la abrió. Null si esa cuenta todavía no tiene nombre cargado.
   */
  customerName: string | null
  /**
   * QUIÉN DEL LOCAL SACÓ EL COBRO. No confundir con `customerName`: este es el
   * lado de la barra, y es de quien cuenta la venta para su comisión.
   *
   * Null cuando quien mira no puede saberlo — para un cajero, en las ventas de
   * sus compañeros. Lo decide la base (20260921160000), no esta pantalla: la
   * columna se apaga cuando no viene en NINGUNA fila.
   */
  staffName: string | null
  /** Cuota 1 y cuota 2, en ese orden. En un cobro de grupo cada una trae el
   *  PEOR estado de los integrantes: si uno está en mora, la cuota lo está. */
  installments: [TransactionInstallment, TransactionInstallment]
}

function mapInstallment(due: unknown, run: unknown): TransactionInstallment {
  // Sin vencimiento no hay cuota; y sin fecha de cobro tampoco hay nada que
  // enseñar, aunque desde 20260902160000 la base la manda siempre.
  if (due == null || run == null) return null
  return { dueDate: String(due), paidToMerchantOn: String(run) }
}

function mapTransaction(row: Record<string, unknown>): DayTransaction {
  return {
    id: String(row.charge_id),
    orderNumber: Number(row.order_number),
    businessDate: String(row.business_date),
    confirmedAt: row.confirmed_at ? String(row.confirmed_at) : null,
    merchantSaleUsd: Number(row.merchant_sale_usd),
    customerName: (row.customer_name as string | null) ?? null,
    staffName: (row.staff_name as string | null) ?? null,
    installments: [
      mapInstallment(row.cuota_1_due, row.cuota_1_run),
      mapInstallment(row.cuota_2_due, row.cuota_2_run),
    ],
  }
}

/** Tope de filas por consulta. Con el rango abierto, un gerente puede pedir
 *  un año entero desde la tablet; mejor devolver un tramo y decirlo que
 *  arrastrar miles de filas a una pantalla que no pagina. */
export const TRANSACTIONS_LIMIT = 500

export type TransactionPage = {
  rows: DayTransaction[]
  /** El rango daba para más de `TRANSACTIONS_LIMIT`: lo que se ve está
   *  recortado por arriba (las más recientes). Los totales NO: los da
   *  `fetchTransactionsSummary` sobre el rango entero. */
  truncated: boolean
}

/**
 * Transacciones del comercio entre dos días operativos, inclusive.
 *
 * El día operativo corre de 10 AM a 10 AM (docs/00-BASES §2.2), así que
 * `business_date` ya lo tiene resuelto el servidor: filtrar por
 * `created_at` mostraría la noche partida en dos.
 *
 * El rango va por `business_date` y no por `confirmed_at` justamente por eso,
 * y además hace que el panel del local y el de Ronda
 * (`/admin/transacciones`) cuenten lo mismo la misma madrugada.
 *
 * Va por RPC y no contra `charges` porque el estado de las cuotas vive en
 * `installments`, que el comercio no puede leer: su RLS es del dueño de la
 * deuda. La RPC devuelve el estado agregado y ningún `user_id`.
 */
export async function fetchTransactionsInRange(params: {
  from: string
  to: string
}): Promise<TransactionPage> {
  const { data, error } = await supabase.rpc('merchant_transactions', {
    p_from: params.from,
    p_to: params.to,
    p_limit: TRANSACTIONS_LIMIT,
  })

  if (error) throw error

  const rows = data as Array<Record<string, unknown>>

  return {
    rows: rows.map(mapTransaction),
    truncated: rows.length === TRANSACTIONS_LIMIT,
  }
}

/**
 * Los totales del rango, calculados en la base y sobre el rango ENTERO.
 *
 * Aparte de la lista a propósito, y esto es lo que arregla: sumar en el
 * navegador lo que cupo en la consulta hacía que un rango de más de 500
 * órdenes enseñara el total de solo las últimas 500. Y el ticket promedio
 * salía de una división hecha aquí con otro dividendo que el de Métricas
 * (`merchant_net_usd` en vez de la venta), así que las dos pantallas podían
 * decir dos cifras. Ahora las dos piden `helios_avg_ticket_usd`.
 */
export type TransactionsSummary = {
  /**
   * De quién son las cifras. Lo dice el servidor (20260922180000): con `self`
   * son las de quien mira, no las del local. Una base sin esa migración no lo
   * manda y cuenta el local entero, así que la ausencia se lee `gerente`.
   */
  scope: 'gerente' | 'self'
  /** Órdenes, no deudores: una cuenta repartida entre cinco es UNA orden. */
  orderCount: number
  /** La venta del comercio en el rango, con su IVA dentro. */
  saleUsd: number
  avgTicketUsd: number
  activeDays: number
}

export async function fetchTransactionsSummary(params: {
  from: string
  to: string
}): Promise<TransactionsSummary> {
  const { data, error } = await supabase.rpc('merchant_transactions_summary', {
    p_from: params.from,
    p_to: params.to,
  })

  if (error) throw error

  const raw = data as Record<string, unknown>
  return {
    scope: raw.scope === 'self' ? 'self' : 'gerente',
    orderCount: Number(raw.order_count),
    saleUsd: Number(raw.sale_usd),
    avgTicketUsd: Number(raw.avg_ticket_usd),
    activeDays: Number(raw.active_days),
  }
}

/**
 * Lo que vendió UNA persona del local en el rango.
 *
 * Existe por la comisión: en un bar, quien está en la barra cobra un
 * porcentaje de lo que vende, y si cobrar con Ronda no cuenta para esa
 * comisión, nadie lo ofrece. El dato estaba guardado desde el primer cobro
 * (`charges.requested_by`) y no se enseñaba en ninguna parte.
 *
 * **Ronda no calcula la comisión.** Dice cuánto vendió cada quien; cada local
 * tiene su propio trato —fijo, porcentaje, por tramos— y la nómina de un
 * tercero no es de este panel.
 */
export type StaffSales = {
  userId: string
  /** Su nombre, o el correo si la cuenta se dio de alta sin nombre. Nunca
   *  viene vacío: una fila de cierre sin nombre no sirve para pagarle a
   *  nadie. */
  name: string
  /** El rol de HOY. Null si ya no es personal del comercio. */
  role: 'gerente' | 'cajero' | null
  /** Si sigue trabajando aquí. Una baja no borra sus ventas —se le paga lo que
   *  vendió antes de irse— pero el cierre tiene que poder decirlo. */
  isActive: boolean
  /** Si es quien está mirando. */
  isSelf: boolean
  orderCount: number
  /** SU VENTA: la del comercio, con IVA dentro y sin el fee del servicio. Es
   *  la cifra sobre la que se calcula una comisión. */
  saleUsd: number
  avgTicketUsd: number
  /** Noches distintas en las que cobró dentro del rango. */
  activeDays: number
  lastSaleAt: string | null
}

export type SalesByStaff = {
  /**
   * Qué se está mirando. Lo dice el SERVIDOR y no se deduce del número de
   * filas: con `self`, lo que viene es una sola fila y es la propia, no un
   * local con una sola cajera. La pantalla necesita distinguirlo para no
   * presentar «tu venta» como si fuera el cierre del local.
   */
  scope: 'gerente' | 'self'
  rows: StaffSales[]
}

/**
 * El cierre por persona del rango.
 *
 * Las filas suman exactamente el total de `fetchTransactionsSummary` sobre el
 * mismo rango **cuando el scope es `gerente`**: mismo filtro y misma función
 * de venta en la base. Con `self` no suman el total del local, y no deben:
 * ahí solo está la fila propia.
 */
export async function fetchSalesByStaff(params: {
  from: string
  to: string
}): Promise<SalesByStaff> {
  const { data, error } = await supabase.rpc('merchant_sales_by_staff', {
    p_from: params.from,
    p_to: params.to,
  })

  if (error) throw error

  const raw = data as { scope?: string; rows?: Array<Record<string, unknown>> }

  return {
    scope: raw.scope === 'gerente' ? 'gerente' : 'self',
    rows: (raw.rows ?? []).map((row) => ({
      userId: String(row.user_id),
      name: String(row.name ?? 'Sin nombre'),
      role: (row.role as StaffSales['role']) ?? null,
      isActive: Boolean(row.is_active),
      isSelf: Boolean(row.is_self),
      orderCount: Number(row.order_count),
      saleUsd: Number(row.sale_usd),
      avgTicketUsd: Number(row.avg_ticket_usd),
      activeDays: Number(row.active_days),
      lastSaleAt: row.last_sale_at ? String(row.last_sale_at) : null,
    })),
  }
}

/**
 * LA FICHA DE UNA ORDEN, para el local.
 *
 * Lo que el comercio viene a mirar cuando alguien pregunta por la orden 1043:
 * qué se vendió, cuánto fue suyo, cuánto pagó el cliente y cuándo entra el
 * dinero. **Las cuotas del cliente no están y no van a estar**: cómo va esa
 * deuda es asunto entre el cliente y Ronda (docs/05 §3), y aquí se leería como
 * una amenaza sobre un cobro que está garantizado. Tampoco viene quién es el
 * cliente ni cuánto puso cada integrante de una cuenta repartida.
 */
export type OrderLine = {
  name: string
  quantity: number
  unitPriceUsd: number
  lineTotalUsd: number
}

/**
 * Una de las dos mitades en que Ronda le paga la orden al local — o el
 * adelanto al vender, si lo tiene pactado.
 *
 * `runDate` es el lunes de cierre que paga esa mitad y lo calcula la base
 * (`helios_settlement_run_for`): el calendario del cierre vive en un solo sitio.
 *
 * `amountUsd` es null hasta que la cuota vence y nace la liquidación. No se
 * estima a propósito — el reparto por tramos y el residuo del último los
 * decide `run_scheduled_settlements`, y una segunda copia de esa aritmética
 * sería una tercera cifra para la misma pregunta. Y es null SIEMPRE para un
 * cajero: los importes de liquidación son del gerente, igual que en la RLS de
 * `settlements`.
 */
export type OrderPayout = {
  kind: 'advance' | 'installment'
  /** 1 o 2 en las mitades; null en el adelanto. */
  sequence: number | null
  dueDate: string
  runDate: string
  amountUsd: number | null
  paidUsd: number | null
  status: 'pending' | 'paid' | 'partial' | 'cancelled' | null
}

export type OrderDetail = {
  id: string
  orderNumber: number
  status: 'pending' | 'confirmed' | 'voided' | 'reverted'
  businessDate: string | null
  createdAt: string
  confirmedAt: string | null
  voidReason: string | null
  isTest: boolean
  /** TU VENTA: la del comercio con su IVA dentro. No es `amountUsd`. */
  merchantSaleUsd: number
  baseUsd: number | null
  vatUsd: number | null
  /** LO QUE PAGA EL CLIENTE: la venta más el fee del servicio y su IVA. */
  amountUsd: number
  consumerFeeUsd: number | null
  consumerFeeVatUsd: number | null
  /** Del gerente: null para un cajero. */
  merchantFeeUsd: number | null
  merchantNetUsd: number | null
  /** Si quien mira puede ver el dinero del local. Lo decide la base. */
  isGerente: boolean
  branch: { id: string; name: string | null; address: string | null } | null
  /** Quien compró. Solo el nombre; null mientras nadie haya escaneado el QR. */
  customerName: string | null
  /** Quién del local sacó el cobro. Null si quien mira no puede saberlo: un
   *  cajero solo lo ve en las suyas. */
  staffName: string | null
  items: OrderLine[]
  payouts: OrderPayout[]
}

/**
 * Va por RPC y no contra `charges` porque hacen falta tres cosas que el
 * personal del comercio no puede leer con su RLS: el número de personas entre
 * las que se repartió (`installments`), el vencimiento de cada mitad y las
 * liquidaciones de un cajero. La RPC decide qué sale según el rol.
 */
export async function fetchOrderDetail(chargeId: string): Promise<OrderDetail> {
  const { data, error } = await supabase.rpc('merchant_charge_detail', {
    p_charge_id: chargeId,
  })

  if (error) throw error

  const raw = data as Record<string, any>
  const opcional = (value: unknown): number | null =>
    value == null ? null : Number(value)

  return {
    id: String(raw.charge_id),
    orderNumber: Number(raw.order_number),
    status: raw.status as OrderDetail['status'],
    businessDate: raw.business_date ?? null,
    createdAt: String(raw.created_at),
    confirmedAt: raw.confirmed_at ?? null,
    voidReason: raw.void_reason ?? null,
    isTest: Boolean(raw.is_test),
    customerName: raw.customer_name ?? null,
    staffName: raw.staff_name ?? null,
    merchantSaleUsd: Number(raw.merchant_sale_usd),
    baseUsd: opcional(raw.base_usd),
    vatUsd: opcional(raw.vat_usd),
    amountUsd: Number(raw.amount_usd),
    consumerFeeUsd: opcional(raw.consumer_fee_usd),
    consumerFeeVatUsd: opcional(raw.consumer_fee_vat_usd),
    merchantFeeUsd: opcional(raw.merchant_fee_usd),
    merchantNetUsd: opcional(raw.merchant_net_usd),
    isGerente: Boolean(raw.is_gerente),
    branch: raw.branch
      ? {
          id: String(raw.branch.id),
          name: raw.branch.name ?? null,
          address: raw.branch.address ?? null,
        }
      : null,
    items: (raw.items ?? []).map((item: Record<string, any>) => ({
      name: String(item.name),
      quantity: Number(item.quantity),
      unitPriceUsd: Number(item.unit_price_usd),
      lineTotalUsd: Number(item.line_total_usd),
    })),
    payouts: (raw.payouts ?? []).map((row: Record<string, any>) => ({
      kind: row.kind as OrderPayout['kind'],
      sequence: opcional(row.sequence),
      dueDate: String(row.due_date),
      runDate: String(row.run_date),
      amountUsd: opcional(row.amount_usd),
      paidUsd: opcional(row.paid_usd),
      status: (row.status as OrderPayout['status']) ?? null,
    })),
  }
}

/** Día operativo actual, calculado igual que `helios_business_date()` en la
 *  base: el día empieza a medianoche en Caracas. */
export async function fetchBusinessDate(): Promise<string> {
  const { data, error } = await supabase.rpc('helios_business_date', {
    p_ts: new Date().toISOString(),
  })

  if (error) throw error
  return data as string
}

