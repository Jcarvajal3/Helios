import { formatUsd } from '@/components/ui'

/**
 * Las cifras del padrón (Directorio › Usuarios) que el panel compone a partir
 * de las filas de `admin_user_directory`.
 *
 * La deuda y lo vencido son PAYABLE (con el service fee + IVA dentro): por la
 * regla del fee nunca se enseñan sin sus dos sumandos, facturado (sin fee) y
 * service fee + IVA, que la base manda en `*_financed_usd` y `*_fee_usd`.
 */

export type PartesDeImporte = { financedUsd: number; feeUsd: number }

/** «€37,00 facturado + €8,20 service fee + IVA»: los sumandos de un importe con fee. */
export function sumandosDeDeuda(p: PartesDeImporte): string {
  return `${formatUsd(p.financedUsd)} financiado + ${formatUsd(p.feeUsd)} service fee + IVA`
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
