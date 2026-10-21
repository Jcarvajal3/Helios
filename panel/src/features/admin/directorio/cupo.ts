import { unoDe } from '@/lib/busqueda'

/**
 * Por qué una persona no puede gastar hoy aunque le quede cupo, tal como lo
 * manda `admin_user_detail.credit.available_blocked_reason`: una cuota
 * vencida, una cuenta que no está activa, o un bloqueo que apaga el saldo
 * (manual, lista de espera o mantenimiento).
 */
export type MotivoSinDisponible = 'cuota_vencida' | 'estado' | 'bloqueo'

const MOTIVOS_SIN_DISPONIBLE: readonly MotivoSinDisponible[] = ['cuota_vencida', 'estado', 'bloqueo']

/** La línea que explica un disponible en cero. */
export const POR_QUE_NO_PUEDE_GASTAR: Record<MotivoSinDisponible, string> = {
  cuota_vencida: 'Congelado: con una cuota vencida no puede financiarse',
  estado: 'La cuenta no está activa',
  bloqueo: 'Bloqueo manual, lista de espera o mantenimiento',
}

/** El motivo que manda la base, o `null` si puede gastar o el valor no se conoce. */
export function comoMotivoSinDisponible(v: unknown): MotivoSinDisponible | null {
  return unoDe(MOTIVOS_SIN_DISPONIBLE, v) ?? null
}

/**
 * Cuánto cupo tiene ocupado una persona, en euros y en proporción.
 *
 * Sale del límite de su nivel y del disponible NOMINAL del servidor (límite
 * menos lo que ocupan sus consumos), no de la deuda: la deuda lleva el
 * Comisión Helios dentro y el cupo no, así que restarlas mezclaría dos
 * clases de cifra. Tampoco del disponible de hoy, que es cero con una cuota
 * vencida aunque el cupo esté casi libre.
 *
 * Null si no tiene cupo (sin nivel, o un nivel con límite cero): ahí no hay
 * proporción que dar, y un «0 %» diría que tiene cupo y no lo usa.
 */
export function usoDelCupo(
  limiteUsd: number,
  disponibleUsd: number,
): { ocupadoUsd: number; proporcion: number } | null {
  if (!Number.isFinite(limiteUsd) || limiteUsd <= 0) return null

  const disponible = Math.min(Math.max(disponibleUsd, 0), limiteUsd)
  const ocupadoUsd = Math.round((limiteUsd - disponible) * 100) / 100

  return { ocupadoUsd, proporcion: ocupadoUsd / limiteUsd }
}
