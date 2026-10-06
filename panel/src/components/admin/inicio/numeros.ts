import { diasDelRango } from '@/components/ui'
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
// El «cierre» es el día del próximo pago a las clínicas (`next_run_date`).
// Desde el 2026-10-06 se les paga a diario —cada liquidación, el día
// siguiente a su vencimiento— y el próximo pago es siempre hoy: `dias` sale 0
// y el semáforo compara la caja de hoy con lo que sale hoy. Las cuentas siguen
// valiendo para cualquier fecha que mande el servidor.

/** Días operativos de `hoy` al pago. Negativo si ya pasó; `null` sin fecha. */
export function diasAlCierre(hoy: string, fechaCierre: string | null): number | null {
  if (!fechaCierre) return null
  return diasDelRango({ from: hoy, to: fechaCierre }) - 1
}

/**
 * Cuántos días de cuotas pueden entrar todavía antes del pago: hasta la
 * víspera, porque lo que vence el mismo día llega tarde para la
 * transferencia, y como mucho 30. `null` si el pago es hoy (lo normal), ya
 * pasó o no tiene fecha: entonces cuenta la cartera de la semana.
 */
export function horizonteDelCierre(dias: number | null): number | null {
  return dias !== null && dias >= 1 ? Math.min(dias - 1, 30) : null
}

/** Suma una columna de la cartera: lo que vence antes del pago o lo ya vencido. */
export function sumarCartera(
  filas: ReadonlyArray<{ upcomingUsd: number; overdueUsd: number }> | undefined,
  campo: 'upcomingUsd' | 'overdueUsd',
): number {
  return (filas ?? []).reduce((s, f) => s + f[campo], 0)
}

/**
 * Si la caja alcanza para el pago a las clínicas. Tres estados y solo uno es
 * malo:
 *
 *   cubre      la caja de hoy ya alcanza.
 *   en_camino  no alcanza todavía, pero lo que vence antes del pago sí, nadie
 *              está en mora y quedan al menos dos días: no hay nada que
 *              hacer. Con el pago diario (el pago es hoy) ya no sale.
 *   urgente    falta dinero y ya no basta con esperar: hay cuotas vencidas sin
 *              cobrar, lo que vence no tapa el hueco o el pago es hoy o mañana.
 *
 * Es la regla del semáforo que vivía en Inicio, sin cambiarla.
 */
export type VeredictoDelCierre = 'cubre' | 'en_camino' | 'urgente'

export function veredictoDelCierre({
  salen,
  caja,
  dias,
  porVencer,
  vencido,
}: {
  /** Lo que sale en el pago, atrasados incluidos. */
  salen: number
  caja: number
  /** Días operativos hasta el pago; `null` sin fecha. */
  dias: number | null
  /** Cuotas pendientes que vencen de hoy a la víspera del pago. */
  porVencer: number
  /** Cuotas ya vencidas y sin cobrar. */
  vencido: number
}): VeredictoDelCierre {
  const falta = salen - caja
  if (falta <= 0) return 'cubre'
  return dias !== null && dias >= 2 && vencido <= 0 && porVencer >= falta ? 'en_camino' : 'urgente'
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
