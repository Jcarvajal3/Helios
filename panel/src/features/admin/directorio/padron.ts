import { formatUsd } from '@/components/ui'

/**
 * Las cifras del padrón (Directorio › Usuarios) que el panel compone a partir
 * de las filas de `admin_user_directory`.
 *
 * La deuda y lo vencido son PAYABLE (con la Comisión Helios + IVA dentro): por la
 * regla de la comisión nunca se enseñan sin sus dos sumandos, facturado (sin comisión) y
 * Comisión Helios + IVA, que la base manda en `*_financed_usd` y `*_fee_usd`.
 */

export type PartesDeImporte = { financedUsd: number; feeUsd: number }

/** «€37,00 facturado + €8,20 Comisión Helios + IVA»: los sumandos de un importe con comisión. */
export function sumandosDeDeuda(p: PartesDeImporte): string {
  return `${formatUsd(p.financedUsd)} financiado + ${formatUsd(p.feeUsd)} Comisión Helios + IVA`
}

type FilaDelPadron = {
  isTest: boolean
  overdueUsd: number
  overdueDesglose?: PartesDeImporte | null
}

export type VencidoDelPadron = {
  /** Usuarios con algo vencido, sin las cuentas de prueba. */
  usuarios: number
  /** Lo vencido de esos usuarios, con el fee dentro. */
  vencidoUsd: number
  /** Sus dos sumandos; null si alguna fila llegó sin ellos (una base vieja). */
  partes: PartesDeImporte | null
}

/**
 * Lo vencido de las filas que se ven. Las cuentas de prueba salen en la lista
 * con su etiqueta, pero no suman.
 */
export function vencidoDelPadron(filas: ReadonlyArray<FilaDelPadron>): VencidoDelPadron {
  const conAtraso = filas.filter((u) => !u.isTest && u.overdueUsd > 0)
  const vencidoUsd = conAtraso.reduce((s, u) => s + u.overdueUsd, 0)
  const partes = conAtraso.every((u) => u.overdueDesglose != null)
    ? {
        financedUsd: conAtraso.reduce((s, u) => s + (u.overdueDesglose?.financedUsd ?? 0), 0),
        feeUsd: conAtraso.reduce((s, u) => s + (u.overdueDesglose?.feeUsd ?? 0), 0),
      }
    : null
  return { usuarios: conAtraso.length, vencidoUsd, partes }
}
