import { primeroDelMes, sumarDias } from '@/components/kit/rango'
import type { Rango } from '@/components/kit/rango'
import { comoFila, comoLista, numero, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Las comisiones del personal (plan §6, contrato §1.6).
//
// Por cada pago en cuotas confirmado, quien lo registró gana una comisión
// ($0,50 por defecto). Se devenga al confirmar y Helios la paga a la clínica
// el día siguiente a la confirmación, dentro de la misma transferencia que
// las consultas de ese día; la clínica se la entrega a su personal. No hay
// cierre semanal: el pago a la clínica es diario.
//
//   merchant_commissions(p_from, p_to)                 → una fila por persona
//   merchant_commission_items(p_from, p_to, p_staff)   → una por pago en cuotas
//
// El administrador ve las de todo el personal; la secretaria, solo las suyas.
// Ese corte lo hace la base: aquí no hay ninguna rama por rol.
//
// Puro: sin red, para probarlo con `npx tsx`. Las llamadas, en
// `comisionesApi.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Lo de una persona en un rango. */
export type ComisionDePersona = {
  staffUserId: string
  staffName: string
  /** Pagos en cuotas confirmados en el rango. */
  chargeCount: number
  /** Devengado: lo ganado en el rango. */
  amountUsd: number
  /** Ya incluido en una transferencia a la clínica. */
  paidUsd: number
  /** Devengado y todavía sin transferir (se paga el día siguiente a confirmar). */
  pendingUsd: number
}

export function leerComisiones(v: unknown): ComisionDePersona[] {
  return comoLista(v)
    .map(comoFila)
    .map((r) => ({
      staffUserId: texto(r.staff_user_id),
      staffName: textoONulo(r.staff_name) ?? 'Sin nombre',
      chargeCount: numero(r.charge_count),
      amountUsd: numero(r.amount_usd),
      paidUsd: numero(r.paid_usd),
      pendingUsd: numero(r.pending_usd),
    }))
    .sort((a, b) => b.amountUsd - a.amountUsd || a.staffName.localeCompare(b.staffName))
}

export type EstadoDeComision = 'devengada' | 'pagada' | 'revertida'

/** Una comisión: la de un pago en cuotas. */
export type ItemDeComision = {
  chargeId: string
  orderNumber: number
  createdAt: string
  /** Cuándo dijo Sí el paciente, si la base lo manda. Si no, vale `createdAt`. */
  confirmedAt: string | null
  amountUsd: number
  status: EstadoDeComision | null
  payoutId: string | null
  /** El día en que se transfirió a la clínica. */
  paidOn: string | null
}

const ESTADOS: readonly EstadoDeComision[] = ['devengada', 'pagada', 'revertida']

export function leerItemsDeComision(v: unknown): ItemDeComision[] {
  return comoLista(v)
    .map(comoFila)
    .map((r) => ({
      chargeId: texto(r.charge_id),
      orderNumber: numero(r.order_number),
      createdAt: texto(r.created_at),
      confirmedAt: textoONulo(r.confirmed_at),
      amountUsd: numero(r.amount_usd),
      status: ESTADOS.find((e) => e === r.status) ?? null,
      payoutId: textoONulo(r.payout_id),
      paidOn: textoONulo(r.paid_on),
    }))
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
}

/** Cómo se ve cada estado. «Devengada» es la palabra del contable; aquí, «Por pagar». */
export const ESTADO_DE_COMISION: Record<
  EstadoDeComision,
  { texto: string; tone: 'success' | 'warning' | 'neutral' }
> = {
  devengada: { texto: 'Por pagar', tone: 'warning' },
  pagada: { texto: 'Pagada', tone: 'success' },
  revertida: { texto: 'Revertida', tone: 'neutral' },
}

/** Dos decimales, sin la cola de coma flotante de una suma. */
function centimos(n: number): number {
  return Math.round(n * 100) / 100
}

export type Totales = { chargeCount: number; amountUsd: number; paidUsd: number; pendingUsd: number }

/**
 * La suma de las filas. Aquí sí se suma en el navegador: la RPC devuelve
 * TODAS las personas del rango (no hay tope de filas), así que la suma es la
 * del rango entero y no la de una página.
 */
export function totales(rows: ReadonlyArray<ComisionDePersona>): Totales {
  return rows.reduce<Totales>(
    (t, r) => ({
      chargeCount: t.chargeCount + r.chargeCount,
      amountUsd: centimos(t.amountUsd + r.amountUsd),
      paidUsd: centimos(t.paidUsd + r.paidUsd),
      pendingUsd: centimos(t.pendingUsd + r.pendingUsd),
    }),
    { chargeCount: 0, amountUsd: 0, paidUsd: 0, pendingUsd: 0 },
  )
}

// ── Día de pago ───────────────────────────────────────────────────────────
//
// La comisión se paga el día siguiente a que el paciente confirma: el
// settlement nace con `due_date` = el día operativo de la confirmación y la
// base lo paga en `helios_settlement_run_for(due_date)` = `due_date + 1`.

/**
 * El día en que Helios le paga a la clínica una comisión: el siguiente al de
 * la confirmación, en Caracas. Sin `confirmedAt`, el del alta: el paciente
 * tiene dos horas para responder, así que casi siempre es el mismo día.
 */
export function diaDePagoDeComision(item: Pick<ItemDeComision, 'createdAt' | 'confirmedAt'>): string {
  return sumarDias(diaEnCaracas(item.confirmedAt ?? item.createdAt), 1)
}

// ── Semanas ───────────────────────────────────────────────────────────────
//
// Las comisiones se leen por semanas de lunes a domingo, como en el
// calendario. Es solo una forma de agruparlas: cada una se paga el día
// siguiente a su confirmación, no al acabar la semana.

/** El lunes de la semana de `dia` ('YYYY-MM-DD'). */
export function lunesDe(dia: string): string {
  const [y = 1970, m = 1, d = 1] = dia.slice(0, 10).split('-').map(Number)
  const semana = new Date(Date.UTC(y, m - 1, d)).getUTCDay() // 0 = domingo
  return sumarDias(dia, -((semana + 6) % 7))
}

/**
 * Las semanas (de lunes a domingo) que toca el rango, recortadas a él y de
 * la más reciente a la más antigua.
 */
export function semanasDelRango(r: Rango): Rango[] {
  if (r.from > r.to) return []
  const semanas: Rango[] = []
  let lunes = lunesDe(r.from)
  while (lunes <= r.to) {
    const domingo = sumarDias(lunes, 6)
    semanas.push({ from: lunes < r.from ? r.from : lunes, to: domingo > r.to ? r.to : domingo })
    lunes = sumarDias(lunes, 7)
  }
  return semanas.reverse()
}

/** Cuántas semanas se piden a la vez en la vista por semana, como mucho. */
export const MAXIMO_DE_SEMANAS = 12

/** El día de Caracas de un instante. Pura: `Intl` con la zona fija. */
export function diaEnCaracas(instante: string): string {
  const fecha = new Date(instante)
  if (Number.isNaN(fecha.getTime())) return instante.slice(0, 10)
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Caracas' }).format(fecha)
}

export type SemanaDeItems = {
  semana: Rango
  items: ItemDeComision[]
  amountUsd: number
  pendingUsd: number
}

/**
 * Las comisiones de una persona agrupadas por su semana, con el subtotal de
 * cada una. Las revertidas se listan pero no suman: no se van a pagar.
 */
export function agruparPorSemana(items: ReadonlyArray<ItemDeComision>): SemanaDeItems[] {
  const porLunes = new Map<string, ItemDeComision[]>()
  for (const item of items) {
    const lunes = lunesDe(diaEnCaracas(item.createdAt))
    const lista = porLunes.get(lunes)
    if (lista) lista.push(item)
    else porLunes.set(lunes, [item])
  }

  return [...porLunes.entries()]
    .sort((a, b) => b[0].localeCompare(a[0]))
    .map(([lunes, lista]) => {
      const vivas = lista.filter((i) => i.status !== 'revertida')
      return {
        semana: { from: lunes, to: sumarDias(lunes, 6) },
        items: lista,
        amountUsd: centimos(vivas.reduce((s, i) => s + i.amountUsd, 0)),
        pendingUsd: centimos(
          vivas.filter((i) => i.status === 'devengada').reduce((s, i) => s + i.amountUsd, 0),
        ),
      }
    })
}

/** Los atajos del periodo, en semanas y meses de calendario. */
export function atajosDeComisiones(hoy: string): Array<{ label: string; rango: Rango }> {
  const lunes = lunesDe(hoy)
  const mesPasado = sumarDias(primeroDelMes(hoy), -1)
  return [
    { label: 'Esta semana', rango: { from: lunes, to: hoy } },
    { label: 'Semana pasada', rango: { from: sumarDias(lunes, -7), to: sumarDias(lunes, -1) } },
    { label: 'Últimas 4 semanas', rango: { from: sumarDias(lunes, -21), to: hoy } },
    { label: 'Este mes', rango: { from: primeroDelMes(hoy), to: hoy } },
    { label: 'Mes pasado', rango: { from: primeroDelMes(mesPasado), to: mesPasado } },
  ]
}

/** El rango por defecto: esta semana y las tres anteriores. */
export function rangoPorDefecto(hoy: string): Rango {
  return { from: sumarDias(lunesDe(hoy), -21), to: hoy }
}

