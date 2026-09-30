import { comoFila, filaONula, filas, numero, numeroONulo, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que Helios le paga a la clínica, partido en sus dos conceptos
// (contrato §1.5, plan §6):
//
//   Consultas                la mitad de cada financiamiento al vencer cada
//                            cuota del paciente (`scheduled_installment`)
//   Comisiones del personal  la comisión de quien registró cada uno
//                            (`staff_commission`), en el lunes siguiente
//
// Las dos viajan en la MISMA transferencia de los lunes; la clínica le
// entrega las comisiones a su personal. Por eso cada transferencia y cada
// una de sus líneas se enseñan partidas: si no, la secretaria que pregunta
// por sus comisiones no las encuentra en ninguna parte.
//
// Puro, para probarlo con `npx tsx`. Las llamadas, en `settlements.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Por qué nació una liquidación. `advance` y `on_collection` vienen del
 * esquema de Ronda y en Helios no se usan (0 % por adelantado, pago por
 * fecha); se leen igual para no perder una fila si algún día aparecen.
 */
export type MotivoDeLiquidacion =
  | 'scheduled_installment'
  | 'staff_commission'
  | 'advance'
  | 'on_collection'

const MOTIVOS: readonly MotivoDeLiquidacion[] = [
  'scheduled_installment',
  'staff_commission',
  'advance',
  'on_collection',
]

export function leerMotivo(v: unknown): MotivoDeLiquidacion | null {
  return MOTIVOS.find((m) => m === v) ?? null
}

/** Consultas o comisiones: los dos montones en que se parte todo lo pagado. */
export type Concepto = 'consultas' | 'comisiones'

/** Todo lo que no es una comisión del personal es dinero de las consultas. */
export function conceptoDe(motivo: MotivoDeLiquidacion | null): Concepto {
  return motivo === 'staff_commission' ? 'comisiones' : 'consultas'
}

export const CONCEPTO: Record<Concepto, string> = {
  consultas: 'Consultas',
  comisiones: 'Comisiones del personal',
}

export type Reparto = { consultasUsd: number; comisionesUsd: number }

function centimos(n: number): number {
  return Math.round(n * 100) / 100
}

/** Suma unas líneas en sus dos montones. */
export function repartir(
  lineas: ReadonlyArray<{ motivo: MotivoDeLiquidacion | null; amountUsd: number }>,
): Reparto {
  let consultas = 0
  let comisiones = 0
  for (const l of lineas) {
    if (conceptoDe(l.motivo) === 'comisiones') comisiones += l.amountUsd
    else consultas += l.amountUsd
  }
  return { consultasUsd: centimos(consultas), comisionesUsd: centimos(comisiones) }
}

// ── Lo que viene ──────────────────────────────────────────────────────────

/**
 * Lo que se le debe a la clínica, en lo que ya nació y lo que nacerá
 * (`merchant_settlement_outlook`). El reparto del próximo cierre llega solo
 * si la base lo manda; no se calcula aquí, porque qué entra en un cierre lo
 * decide el calendario de la base, no esta pantalla.
 */
export type Prevision = {
  todayDate: string
  nextRunDate: string
  nextRunUsd: number
  /** El reparto del próximo cierre, si la base lo manda. */
  nextRun: Reparto | null
  accruedUsd: number
  accruedCount: number
  overdueUsd: number
  oldestDueDate: string | null
  upcomingUsd: number
  totalPendingUsd: number
}

export function leerPrevision(v: unknown): Prevision {
  const r = comoFila(v)
  const consultas =
    numeroONulo(r.next_run_consultas_usd) ?? numeroONulo(r.consultas_usd)
  const comisiones =
    numeroONulo(r.next_run_comisiones_usd) ?? numeroONulo(r.comisiones_usd)

  return {
    todayDate: texto(r.today_date),
    nextRunDate: texto(r.next_run_date),
    nextRunUsd: numero(r.next_run_usd),
    nextRun:
      consultas !== null || comisiones !== null
        ? { consultasUsd: consultas ?? 0, comisionesUsd: comisiones ?? 0 }
        : null,
    accruedUsd: numero(r.accrued_usd),
    accruedCount: numero(r.accrued_count),
    overdueUsd: numero(r.overdue_usd),
    oldestDueDate: textoONulo(r.oldest_due_date),
    upcomingUsd: numero(r.upcoming_usd),
    totalPendingUsd: numero(r.total_pending_usd),
  }
}

/** Una liquidación: una mitad de un financiamiento, o una comisión. */
export type Liquidacion = {
  id: string
  motivo: MotivoDeLiquidacion | null
  amountUsd: number
  dueDate: string
  businessDate: string
}

export function leerLiquidacion(v: unknown): Liquidacion {
  const r = comoFila(v)
  return {
    id: texto(r.id),
    motivo: leerMotivo(r.reason),
    amountUsd: numero(r.amount_usd),
    dueDate: texto(r.due_date),
    businessDate: texto(r.business_date),
  }
}

// ── Lo que llegó ──────────────────────────────────────────────────────────

export type Transferencia = {
  id: string
  amountUsd: number
  amountVes: number | null
  method: string
  reference: string | null
  note: string | null
  businessDate: string
  createdAt: string
  itemCount: number
  /** Partida en consultas y comisiones. Null si no se pudo saber. */
  reparto: Reparto | null
}

/**
 * Una fila de `merchant_payouts` con sus líneas embebidas
 * (`merchant_payout_items(*, settlements(reason))`).
 *
 * El reparto sale de `consultas_usd` y `comisiones_usd` si la transferencia
 * los trae (contrato §1.5); si no, de sumar sus líneas por su `reason`, que
 * viene en la línea o en su liquidación.
 */
export function leerTransferencia(v: unknown): Transferencia {
  const r = comoFila(v)
  const lineas = filas(r.merchant_payout_items)

  const consultas = numeroONulo(r.consultas_usd)
  const comisiones = numeroONulo(r.comisiones_usd)

  // Solo se reparte sumando si TODAS las líneas dicen su motivo: con una sin
  // motivo, el reparto sería una cifra a medias que parece entera.
  const conMotivo = lineas.map((l) => ({
    motivo: leerMotivo(l.reason) ?? leerMotivo(filaONula(l.settlements)?.reason),
    amountUsd: numero(l.amount_usd),
  }))
  const sumable = lineas.length > 0 && conMotivo.every((l) => l.motivo !== null)

  const cuenta = numeroONulo(lineas[0]?.count)

  return {
    id: texto(r.id),
    amountUsd: numero(r.amount_usd),
    amountVes: numeroONulo(r.amount_ves),
    method: texto(r.method),
    reference: textoONulo(r.reference),
    note: textoONulo(r.note),
    businessDate: texto(r.business_date),
    createdAt: texto(r.created_at),
    itemCount: cuenta ?? lineas.length,
    reparto:
      consultas !== null || comisiones !== null
        ? { consultasUsd: consultas ?? 0, comisionesUsd: comisiones ?? 0 }
        : sumable
          ? repartir(conMotivo)
          : null,
  }
}

/** Una línea de una transferencia, con la fecha de lo que pagó. */
export function leerLineaDeTransferencia(v: unknown): Liquidacion | null {
  const r = comoFila(v)
  const liquidacion = filaONula(r.settlements)
  if (!liquidacion) return null
  return {
    id: texto(liquidacion.id),
    motivo: leerMotivo(r.reason) ?? leerMotivo(liquidacion.reason),
    amountUsd: numero(r.amount_usd),
    dueDate: texto(liquidacion.due_date),
    businessDate: texto(liquidacion.business_date),
  }
}

export type GrupoDeLineas = {
  concepto: Concepto
  /** El día del financiamiento de las consultas; null en las comisiones. */
  businessDate: string | null
  count: number
  amountUsd: number
}

/**
 * Lo que cubrió una transferencia, para leerlo: las consultas por el día
 * del financiamiento que las originó, y las comisiones juntas en una línea
 * (van a repartirse por persona, y eso está en Comisiones).
 */
export function agruparLineas(lineas: ReadonlyArray<Liquidacion>): GrupoDeLineas[] {
  const consultas = new Map<string, GrupoDeLineas>()
  let comisiones: GrupoDeLineas | null = null

  for (const l of lineas) {
    if (conceptoDe(l.motivo) === 'comisiones') {
      comisiones ??= { concepto: 'comisiones', businessDate: null, count: 0, amountUsd: 0 }
      comisiones.count += 1
      comisiones.amountUsd = centimos(comisiones.amountUsd + l.amountUsd)
      continue
    }
    const g = consultas.get(l.businessDate) ?? {
      concepto: 'consultas' as const,
      businessDate: l.businessDate,
      count: 0,
      amountUsd: 0,
    }
    g.count += 1
    g.amountUsd = centimos(g.amountUsd + l.amountUsd)
    consultas.set(l.businessDate, g)
  }

  const ordenadas = [...consultas.values()].sort((a, b) =>
    (a.businessDate ?? '').localeCompare(b.businessDate ?? ''),
  )
  return comisiones ? [...ordenadas, comisiones] : ordenadas
}

export const MEDIO_DE_PAGO: Record<string, string> = {
  pago_movil: 'Pago Móvil',
  transferencia: 'Transferencia',
  zelle: 'Zelle',
  usdt: 'USDT',
  efectivo: 'Efectivo',
}
