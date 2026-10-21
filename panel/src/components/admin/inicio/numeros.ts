import type { FilaPrimeraCuota } from '@/features/admin/riesgo/credito'

// ═══════════════════════════════════════════════════════════════════════════
// Las cuentas pequeñas de «Hoy en cifras», sin React ni Supabase.
//
// Ninguna cifra de negocio nace aquí: se elige cuál enseñar (el último mes
// maduro, el horizonte del pago) y se combinan funciones que ya usan otras
// pantallas, para que la misma cifra diga lo mismo en todas.
// ═══════════════════════════════════════════════════════════════════════════

// ── El pago a las clínicas ─────────────────────────────────────────────────
//
// A las clínicas se les paga a diario: cada liquidación, el día siguiente a
// su vencimiento. El pago que viene es siempre hoy, así que la pregunta es
// una sola: ¿la caja de hoy cubre lo que sale hoy? (Ronda pagaba los lunes y
// aquí se contaban los días al cierre y lo que vencía antes; ya no aplica.)

/**
 * Si la caja alcanza para el pago de hoy a las clínicas: cubre, o no cubre
 * (en rojo: hay que hacer algo hoy).
 */
export type VeredictoDelCierre = 'cubre' | 'urgente'

export function veredictoDelCierre({
  salen,
  caja,
}: {
  /** Lo que sale en el pago de hoy, atrasados incluidos. */
  salen: number
  caja: number
}): VeredictoDelCierre {
  return salen - caja <= 0 ? 'cubre' : 'urgente'
}

// ── Riesgo ─────────────────────────────────────────────────────────────────

/**
 * El mes más reciente cuyas cuotas 1 ya pasaron todas la gracia.
 *
 * Un mes con cuotas todavía en la gracia da un porcentaje a medias, que baja
 * o sube cuando maduran las demás. Las filas llegan del más reciente al más
 * viejo, que es como las ordena `admin_first_payment_default` por mes.
 */
export function ultimoMesMaduro<T extends Pick<FilaPrimeraCuota, 'maduras' | 'enGracia'>>(
  filas: ReadonlyArray<T>,
): T | null {
  return filas.find((f) => f.maduras > 0 && f.enGracia === 0) ?? null
}
