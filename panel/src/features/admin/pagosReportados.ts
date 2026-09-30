import { supabase } from '@/lib/supabase'
import { aQueueItem } from '@/features/admin/api'
import type { PayoutMethod, QueueItem } from '@/features/admin/api'
import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Pagos reportados: un pago suelto y la salud de la conciliación.
//
// La cola entera sigue en `api.ts` (`fetchPaymentQueue`); aquí van las dos
// lecturas que nacieron con la remodelación de Caja (CONTRATOS-D1 §8 y §7).
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Un pago reportado, en cualquier estado.
 *
 * Antes la ficha pedía la cola ENTERA —los cinco estados, con su árbol de
 * compras y cuotas— para quedarse con un elemento. `admin_payment_report`
 * devuelve ese mismo elemento solo, y se lee con la misma función que la cola.
 *
 * `null` si no existe o es de una cuenta de prueba: la ficha dice «Este pago
 * no existe», igual que antes.
 */
export async function fetchPaymentReport(reportId: string): Promise<QueueItem | null> {
  const { data, error } = await supabase.rpc('admin_payment_report', {
    p_report_id: reportId,
  })
  if (error) throw error
  return data === null ? null : aQueueItem(data)
}

// ── Salud de la conciliación ──────────────────────────────────────────────

/** Minutos: cuántos pagos, la mediana y el percentil 90. */
export type TiempoDeResolucion = { count: number; median: number | null; p90: number | null }

/** Un tramo de edad de la cola: cuántos pagos y cuánto dicen haber pagado. */
export type TramoDeCola = { count: number; usd: number }

export type SaludConciliacion = {
  from: string
  to: string
  resolved: {
    total: number
    approved: number
    rejected: number
    duplicate: number
    /** Nacidos de asignar un abono: respaldados por construcción. */
    approvedFromDeposit: number
    /** Aprobados por pago móvil o transferencia, los únicos que salen en el extracto. */
    approvedInStatementMethods: number
    approvedMatched: number
    /** `null` si no hubo aprobados por pago móvil o transferencia: no es un 0 %. */
    matchPct: number | null
    /** Rechazados que sí tienen un movimiento que encaja: hay que revisarlos. */
    rejectedMatched: number
  }
  byMethod: Array<{ method: PayoutMethod; approved: number; approvedMatched: number; rejected: number }>
  resolutionMinutes: { all: TiempoDeResolucion; approved: TiempoDeResolucion; rejected: TiempoDeResolucion }
  queue: {
    count: number
    /** PAYABLE: lo que la gente dice haber pagado. */
    usd: number
    inReview: number
    oldestCreatedAt: string | null
    under24h: TramoDeCola
    from1To3Days: TramoDeCola
    over3Days: TramoDeCola
  }
  statement: { lastMovedOn: string | null; lastImportedAt: string | null }
}

const METODOS: readonly PayoutMethod[] = ['pago_movil', 'transferencia', 'zelle', 'usdt', 'efectivo']

function leerTiempo(v: unknown): TiempoDeResolucion {
  const t = comoFila(v)
  return { count: Number(t.count ?? 0), median: numeroONulo(t.median), p90: numeroONulo(t.p90) }
}

function leerTramo(v: unknown): TramoDeCola {
  const t = comoFila(v)
  return { count: Number(t.count ?? 0), usd: Number(t.usd ?? 0) }
}

/**
 * Cómo va la conciliación: cuánto de lo aprobado respalda el extracto, cuánto
 * se tarda en decidir y cuánto lleva esperando la cola.
 *
 * El rango (días operativos, por defecto los últimos 30) acota los pagos
 * resueltos; la cola es la de ahora. Excluye las cuentas de prueba.
 */
export async function fetchReconciliationHealth(
  desde?: string,
  hasta?: string,
): Promise<SaludConciliacion> {
  const { data, error } = await supabase.rpc('admin_reconciliation_health', {
    p_from: desde ?? null,
    p_to: hasta ?? null,
  })
  if (error) throw error

  const raw = comoFila(data)
  const r = comoFila(raw.resolved)
  const q = comoFila(raw.queue)
  const m = comoFila(raw.resolution_minutes)
  const s = comoFila(raw.statement)

  return {
    from: String(raw.from),
    to: String(raw.to),
    resolved: {
      total: Number(r.total ?? 0),
      approved: Number(r.approved ?? 0),
      rejected: Number(r.rejected ?? 0),
      duplicate: Number(r.duplicate ?? 0),
      approvedFromDeposit: Number(r.approved_from_deposit ?? 0),
      approvedInStatementMethods: Number(r.approved_in_statement_methods ?? 0),
      approvedMatched: Number(r.approved_matched ?? 0),
      matchPct: numeroONulo(r.match_pct),
      rejectedMatched: Number(r.rejected_matched ?? 0),
    },
    byMethod: comoLista(raw.by_method).flatMap((fila) => {
      const b = comoFila(fila)
      const method = METODOS.find((x) => x === b.method)
      if (!method) return []
      return [
        {
          method,
          approved: Number(b.approved ?? 0),
          approvedMatched: Number(b.approved_matched ?? 0),
          rejected: Number(b.rejected ?? 0),
        },
      ]
    }),
    resolutionMinutes: {
      all: leerTiempo(m.all),
      approved: leerTiempo(m.approved),
      rejected: leerTiempo(m.rejected),
    },
    queue: {
      count: Number(q.count ?? 0),
      usd: Number(q.usd ?? 0),
      inReview: Number(q.in_review ?? 0),
      oldestCreatedAt: textoONulo(q.oldest_created_at),
      under24h: leerTramo(q.under_24h),
      from1To3Days: leerTramo(q.from_1_to_3_days),
      over3Days: leerTramo(q.over_3_days),
    },
    statement: {
      lastMovedOn: textoONulo(s.last_moved_on),
      lastImportedAt: textoONulo(s.last_imported_at),
    },
  }
}
