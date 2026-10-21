// ═══════════════════════════════════════════════════════════════════════════
// Lo que se debe en cuotas, partido en sus dos sumandos.
//
// Una cuota es PAYABLE: consumo + Comisión Helios (con su IVA). La regla de la comisión
// dice que un total así nunca va solo: va con «consumo €X · comisión €Y» al lado.
// Las fichas tienen el total del servidor (la deuda de hoy, lo vencido) y las
// cuotas una a una; esto saca el desglose de las cuotas y SOLO lo da si su
// suma cuadra con el total que se enseña, porque un desglose que no suma lo
// de arriba es peor que ninguno.
//
// Puro: se prueba en `desgloseDeCuotas.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Lo que hace falta de una cuota: lo que se paga y el consumo que lleva dentro. */
export type CuotaConDesglose = { amountUsd: number; financedUsd: number }

export type DesgloseDeCuotas = { payableUsd: number; financedUsd: number; feeUsd: number }

/** A céntimos: sumar en coma flotante deja colas (0,1 + 0,2). */
function centimos(n: number): number {
  return Math.round(n * 100) / 100
}

/** Las cuotas sumadas en sus dos partes. La comisión es lo que se paga menos el consumo. */
export function desgloseDeCuotas(cuotas: ReadonlyArray<CuotaConDesglose>): DesgloseDeCuotas {
  const payableUsd = centimos(cuotas.reduce((s, c) => s + (Number(c.amountUsd) || 0), 0))
  const financedUsd = centimos(cuotas.reduce((s, c) => s + (Number(c.financedUsd) || 0), 0))
  return { payableUsd, financedUsd, feeUsd: centimos(payableUsd - financedUsd) }
}

/**
 * El desglose de `cuotas`, solo si su suma es `total` (a un céntimo). Si no
 * cuadra —un cargo por atraso dentro, una cuota que la ficha no trae—, `null`:
 * la pantalla enseña entonces el total con su explicación, no unos sumandos
 * que no suman.
 */
export function desgloseQueCuadra(
  cuotas: ReadonlyArray<CuotaConDesglose>,
  total: number,
): DesgloseDeCuotas | null {
  if (!Number.isFinite(total) || total <= 0) return null
  const d = desgloseDeCuotas(cuotas)
  // En céntimos enteros: 12,63 − 12,62 en coma flotante es 0,0100000000001.
  return Math.abs(Math.round(d.payableUsd * 100) - Math.round(total * 100)) <= 1 ? d : null
}
