import { primeroDelMes, sumarDias } from '@/components/kit/rango'
import type { Rango } from '@/components/kit/rango'
import { comoFila, comoLista, numero, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Las comisiones del personal (plan §6, contrato §1.6).
//
// Por cada financiamiento confirmado, quien lo registró gana una comisión
// ($0,50 por defecto). Se devenga al confirmar y Helios la paga a la clínica
// en el cierre del lunes siguiente, dentro de la misma transferencia que las
// consultas; la clínica se la entrega a su personal.
//
//   merchant_commissions(p_from, p_to)                 → una fila por persona
//   merchant_commission_items(p_from, p_to, p_staff)   → una por financiamiento
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
  /** Financiamientos confirmados en el rango. */
  chargeCount: number
  /** Devengado: lo ganado en el rango. */
  amountUsd: number
  /** Ya incluido en una transferencia a la clínica. */
  paidUsd: number
  /** Por pagar en el próximo lunes. */
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

/** Una comisión: la de un financiamiento. */
export type ItemDeComision = {
  chargeId: string
  orderNumber: number
  createdAt: string
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

// ── Semanas ───────────────────────────────────────────────────────────────
//
// La semana de las comisiones va de lunes a domingo: lo que se registra en
// ella entra en el cierre del lunes siguiente (el settlement nace con
// `due_date = business_date`, plan §6).

/** El lunes de la semana de `dia` ('YYYY-MM-DD'). */
export function lunesDe(dia: string): string {
  const [y = 1970, m = 1, d = 1] = dia.slice(0, 10).split('-').map(Number)
  const semana = new Date(Date.UTC(y, m - 1, d)).getUTCDay() // 0 = domingo
  return sumarDias(dia, -((semana + 6) % 7))
}

/** El lunes en que Helios paga lo registrado en la semana que empieza en `lunes`. */
export function lunesDePago(lunes: string): string {
  return sumarDias(lunesDe(lunes), 7)
}

/**
 * Las semanas (de lunes a domingo) que toca el rango, recortadas a él y de
 * la más reciente a la más antigua: la de arriba es la que se va a cobrar.
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

/** Los atajos del periodo, pensados en semanas de cobro. */
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

