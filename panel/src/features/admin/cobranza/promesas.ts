import { unoDe } from '@/lib/busqueda'
import { CANALES, RESULTADOS } from './gestion'
import type { Canal, Resultado } from './gestion'
import { comoFila, comoLista, numero, textoONulo, texto, booleano } from '@/lib/json'
import { VALORES_ESTADO_PROMESA } from '@/features/admin/estados'
import type { EstadoPromesa } from '@/features/admin/estados'

// ═══════════════════════════════════════════════════════════════════════════
// Las promesas de pago, leídas de `admin_collection_promises`.
//
// Una fila por gestión con fecha prometida. El estado lo calcula la base con
// `helios_promise_status`, el mismo que usa la cartera vencida: aquí no se
// vuelve a calcular.
// ═══════════════════════════════════════════════════════════════════════════

export type UltimoPago = {
  id: string
  creadoEl: string
  /** El estado del pago reportado: `reported`, `in_review`, `reconciled`… */
  estado: string
  /** PAYABLE: el monto de la cotización, lo que la persona transfirió. */
  montoUsd: number
}

export type Promesa = {
  gestionId: string
  userId: string
  nombre: string | null
  telefono: string | null
  estadoPersona: string
  contactadoEl: string
  canal: Canal
  resultado: Resultado | null
  nota: string | null
  quien: string
  /** El día operativo prometido, 'YYYY-MM-DD'. */
  fecha: string
  estado: EstadoPromesa
  /** La persona hizo otra promesa después: esta ya se renegoció. */
  renegociada: boolean
  /** PAYABLE (deuda): lo vencido de la persona hoy. */
  vencidoHoyUsd: number
  /** Las dos partes de `vencidoHoyUsd`: el consumo y la Comisión Helios (con su IVA). */
  vencidoHoyFinancedUsd: number
  vencidoHoyFeeUsd: number
  diasDeAtraso: number
  ultimoPago: UltimoPago | null
}

export type Promesas = {
  /** Día operativo de hoy, según la base. */
  hoy: string
  desde: string
  hasta: string | null
  recuento: Record<EstadoPromesa, number>
  filas: Promesa[]
}

function leerUltimoPago(raw: unknown): UltimoPago | null {
  if (raw === null || raw === undefined) return null
  const p = comoFila(raw)
  const id = textoONulo(p.report_id)
  if (!id) return null
  return {
    id,
    creadoEl: texto(p.created_at),
    estado: texto(p.status),
    montoUsd: numero(p.amount_usd),
  }
}

/**
 * Una fila con un estado que este panel no conoce se descarta: no hay ninguna
 * pestaña donde enseñarla, y la base solo devuelve los cuatro de la regla.
 */
function leerPromesa(raw: unknown): Promesa | null {
  const r = comoFila(raw)
  const estado = unoDe(VALORES_ESTADO_PROMESA, r.status)
  const fecha = textoONulo(r.promise_date)
  if (!estado || !fecha) return null
  return {
    gestionId: texto(r.contact_id),
    userId: texto(r.user_id),
    nombre: textoONulo(r.full_name),
    telefono: textoONulo(r.phone_e164),
    estadoPersona: texto(r.user_status),
    contactadoEl: texto(r.contacted_at),
    canal: unoDe(CANALES, r.channel) ?? 'otro',
    resultado: unoDe(RESULTADOS, r.outcome) ?? null,
    nota: textoONulo(r.note),
    quien: texto(r.actor_name, 'Alguien del equipo'),
    fecha,
    estado,
    renegociada: booleano(r.superseded),
    vencidoHoyUsd: numero(r.overdue_usd),
    vencidoHoyFinancedUsd: numero(r.overdue_financed_usd),
    vencidoHoyFeeUsd: numero(r.overdue_fee_usd),
    diasDeAtraso: numero(r.days_overdue),
    ultimoPago: leerUltimoPago(r.last_payment),
  }
}

export function leerPromesas(raw: unknown): Promesas {
  const d = comoFila(raw)
  const s = comoFila(d.summary)
  return {
    hoy: texto(d.business_date),
    desde: texto(d.from),
    hasta: textoONulo(d.to),
    recuento: {
      vence_hoy: numero(s.vence_hoy),
      pendiente: numero(s.pendiente),
      cumplida: numero(s.cumplida),
      rota: numero(s.rota),
    },
    filas: comoLista(d.rows).flatMap((f) => {
      const p = leerPromesa(f)
      return p ? [p] : []
    }),
  }
}

/**
 * Las promesas de un estado, en el orden en que se trabajan: las pendientes,
 * la más cercana primero; las demás, la más reciente primero (la promesa rota
 * de ayer pide llamada antes que la de hace un mes).
 */
export function promesasDelEstado(filas: ReadonlyArray<Promesa>, estado: EstadoPromesa): Promesa[] {
  const del = filas.filter((p) => p.estado === estado)
  const asc = estado === 'pendiente'
  return del.sort((a, b) => {
    const porFecha = asc ? a.fecha.localeCompare(b.fecha) : b.fecha.localeCompare(a.fecha)
    return porFecha !== 0 ? porFecha : b.contactadoEl.localeCompare(a.contactadoEl)
  })
}

/**
 * Cuántas de las promesas ya resueltas se cumplieron.
 *
 * Solo cuentan las resueltas (cumplidas y rotas): una promesa para el viernes
 * no ha fallado todavía. Sin ninguna resuelta, `pct` es `null`, no un 0 %.
 */
export function tasaDeCumplimiento(r: Record<EstadoPromesa, number>): {
  pct: number | null
  cumplidas: number
  resueltas: number
} {
  const resueltas = r.cumplida + r.rota
  return {
    pct: resueltas > 0 ? (r.cumplida / resueltas) * 100 : null,
    cumplidas: r.cumplida,
    resueltas,
  }
}
