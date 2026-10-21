import { comoDia } from '@/lib/busqueda'
import { booleano, filaONula, numeroONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Las piezas que comparten las respuestas de las RPC de Métricas
// (CONTRATOS §6), leídas una vez y bien.
//
// La pantalla pinta lo que la base USÓ, no lo que pidió: la semana y el «hoy»
// vienen en la respuesta. Y todo importe que se paga (`payable_usd`) viene
// con su consumo y su Comisión Helios al lado, para que el desglose nunca falte.
//
// Puro: se prueba en `lectura.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** La semana que usó la base: `"semana": {"desde", "hasta", "en_curso"}`. */
export type SemanaUsada = { desde: string; hasta: string; enCurso: boolean }

/** `null` si la respuesta no la trae o la trae rota. */
export function leerSemanaUsada(v: unknown): SemanaUsada | null {
  const s = filaONula(v)
  if (!s) return null
  const desde = comoDia(s.desde)
  const hasta = comoDia(s.hasta)
  if (!desde || !hasta) return null
  return { desde, hasta, enCurso: booleano(s.en_curso) }
}

/** El «hoy» que usó la base (`helios_business_date`), o `null`. */
export function leerHoyUsado(v: unknown): string | null {
  return comoDia(v) ?? null
}

/**
 * Un importe que se paga en cuotas, siempre con sus dos partes. Nunca se
 * enseña `payableUsd` suelto: va con «Consumo $ + Comisión Helios $»
 * (`textoDeDesglose`).
 */
export type Desglose = {
  /** Lo que se paga: consumo + Comisión Helios (con su IVA). */
  payableUsd: number
  /** El consumo, sin la comisión. */
  financedUsd: number
  /** La Comisión Helios con su IVA: `payable − financed`. */
  feeUsd: number
}

/**
 * Un objeto `{ payable_usd, financed_usd, fee_usd }` de la base. Si falta
 * `fee_usd` se deduce (`payable − financed`), que es como lo define el
 * contrato; `null` si falta el `payable` o el `financed`, porque sin las dos
 * partes no hay desglose que enseñar.
 */
export function leerDesglose(v: unknown): Desglose | null {
  const f = filaONula(v)
  if (!f) return null
  const payableUsd = numeroONulo(f.payable_usd)
  const financedUsd = numeroONulo(f.financed_usd)
  if (payableUsd === null || financedUsd === null) return null
  const feeUsd = numeroONulo(f.fee_usd) ?? payableUsd - financedUsd
  return { payableUsd, financedUsd, feeUsd }
}
