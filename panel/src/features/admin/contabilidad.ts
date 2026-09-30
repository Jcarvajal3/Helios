import type { AccountingExport } from '@/features/admin/ajustes'

// ═══════════════════════════════════════════════════════════════════════════
// El libro de asientos, dicho en castellano. Módulo puro.
//
// Los nombres de las cuentas y de los tipos de asiento estaban copiados en el
// libro y en la exportación, cada copia con huecos distintos (una no conocía
// el IVA; ninguna, los cargos por atraso). Aquí hay una sola tabla.
// ═══════════════════════════════════════════════════════════════════════════

export const CUENTAS: Record<string, string> = {
  cash: 'Caja',
  user_receivable: 'Por cobrar a pacientes',
  merchant_payable: 'Por pagar a clínicas',
  platform_revenue: 'Ingresos de Helios',
  vat_payable: 'IVA por pagar',
  bad_debt_provision: 'Provisión de incobrables',
  fx_difference: 'Diferencia cambiaria',
  merchant_prepaid: 'Garantía en clínicas',
}

export const TIPOS_DE_ASIENTO: Record<string, string> = {
  charge: 'Financiamiento',
  merchant_advance: 'Adelanto a la clínica',
  installment_payment: 'Pago de paciente',
  merchant_settlement: 'Pago a clínica',
  vault_deposit: 'Garantía a una clínica',
  vault_settlement: 'Cubierto por la garantía',
  late_fee: 'Cargo por atraso',
  charge_off: 'Dado por perdido',
  fx_adjustment: 'Diferencia cambiaria',
  manual_adjustment: 'Ajuste',
}

/** Las opciones del filtro del libro, con «Todos» delante. */
export const FILTRO_DE_TIPOS: ReadonlyArray<{ value: string; label: string }> = [
  { value: '', label: 'Todos' },
  { value: 'charge', label: 'Financiamientos' },
  { value: 'installment_payment', label: 'Pagos de pacientes' },
  { value: 'merchant_settlement', label: 'Pagos a clínicas' },
  { value: 'vault_deposit', label: 'Garantías a clínicas' },
  { value: 'vault_settlement', label: 'Cubierto por la garantía' },
  { value: 'late_fee', label: 'Cargos por atraso' },
  { value: 'charge_off', label: 'Dado por perdido' },
  { value: 'fx_adjustment', label: 'Diferencia cambiaria' },
  { value: 'manual_adjustment', label: 'Ajustes' },
]

export const VALORES_TIPO_DE_ASIENTO = FILTRO_DE_TIPOS.map((t) => t.value).filter((v) => v !== '')

export function nombreDeCuenta(cuenta: string): string {
  return CUENTAS[cuenta] ?? cuenta
}

export function nombreDeAsiento(tipo: string): string {
  return TIPOS_DE_ASIENTO[tipo] ?? tipo
}

// ── Devengado y cobrado del mes ───────────────────────────────────────────

/**
 * El memo con el que `admin_waive_late_fee` escribe la condonación de un
 * cargo por atraso. Es un ajuste manual y no un asiento de cargo, así que el
 * memo es lo único que lo distingue de otro ajuste de ingresos.
 */
const MEMO_CARGO_CONDONADO = 'Cargo por atraso condonado'

export type DevengadoDelMes = {
  /** El service fee devengado, sin IVA ni cargos por atraso. */
  servicioUsd: number
  /** El IVA del service fee: no es de Ronda, se remite. */
  ivaUsd: number
  /** Los cargos por atraso que cayeron, menos los condonados. */
  cargosPorAtrasoUsd: number
  /** La deuda que pasó a pérdida en el mes (deuda: lleva el service fee dentro). */
  dadoPorPerdidoUsd: number
  /** Lo que entró a caja: pagos de usuarios. */
  cobradoUsd: number
  /** Lo que salió de caja: transferencias a locales. */
  pagadoALocalesUsd: number
}

/**
 * Lo devengado y lo cobrado del mes, cada cosa por su lado.
 *
 * Ninguna cifra suma a otra: el service fee es ingreso, el IVA es de Hacienda, lo
 * dado por perdido es deuda y lo cobrado es caja. Un total que las juntara
 * mezclaría consumo, fee y deuda en una sola cifra que no es nada.
 */
export function devengadoDelMes(d: AccountingExport): DevengadoDelMes {
  let servicioUsd = 0
  let cargosPorAtrasoUsd = 0
  let ivaUsd = 0

  for (const e of d.entries) {
    const neto = e.creditUsd - e.debitUsd
    if (e.account === 'vat_payable') ivaUsd += neto
    if (e.account !== 'platform_revenue') continue
    const esCargo = e.type === 'late_fee' || (e.memo ?? '').startsWith(MEMO_CARGO_CONDONADO)
    if (esCargo) cargosPorAtrasoUsd += neto
    else servicioUsd += neto
  }

  return {
    servicioUsd,
    ivaUsd,
    cargosPorAtrasoUsd,
    dadoPorPerdidoUsd: d.summary.writtenOffUsd,
    cobradoUsd: d.summary.collectedUsd,
    pagadoALocalesUsd: d.summary.paidOutUsd,
  }
}

/** El descuadre del balance de comprobación: la suma de los netos, que debe ser 0. */
export function descuadreDelLibro(d: AccountingExport): number {
  return d.byAccount.reduce((s, a) => s + a.netUsd, 0)
}

/** Por debajo de un céntimo, el libro cuadra. */
export const LIBRO_CUADRA = 0.01
