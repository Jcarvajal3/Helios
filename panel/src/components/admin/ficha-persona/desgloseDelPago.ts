import { formatUsd } from '@/components/ui'
import { textoDeDesgloseCorto } from '@/features/admin/metricas/formato'
import type { UserDetail } from '@/features/admin/users'

// ═══════════════════════════════════════════════════════════════════════════
// Los sumandos de un pago reportado.
//
// El monto que transfirió es sus cuotas (payable: consumo + service fee) más
// los cargos por atraso que llevaba. La regla del fee no deja enseñarlo sin
// sus partes: «consumo €28,25 · fee €6,55 + cargos por atraso €8,00».
//
// Puro: se prueba en `desgloseDelPago.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export type PartesDelPago = NonNullable<UserDetail['payments'][number]['partes']>

export function desgloseDelPago(p: PartesDelPago): string {
  const cuotas = textoDeDesgloseCorto({ financedUsd: p.cuotasFinancedUsd, feeUsd: p.cuotasFeeUsd })
  return p.lateFeesUsd > 0 ? `${cuotas} + cargos por atraso ${formatUsd(p.lateFeesUsd)}` : cuotas
}
