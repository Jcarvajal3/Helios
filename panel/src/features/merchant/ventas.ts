import { csvDinero, csvEntero, csvInstante } from '@/lib/csv'
import type { CsvColumn } from '@/lib/csv'
import { booleano, comoFila, numero, numeroONulo, texto, textoONulo } from '@/lib/json'

import { COMPROBANTE, leerEstadoDelComprobante } from './registro'
import type { EstadoDelComprobante } from './registro'

// ═══════════════════════════════════════════════════════════════════════════
// El libro de pagos en cuotas de la clínica, para contabilidad
// (`merchant_sales_export`, solo el administrador).
//
// Dos partes que en los libros no son la misma cosa:
//
//   1. LA CONSULTA — lo que cobra la clínica. Es su ingreso.
//   2. LO QUE HELIOS LE FACTURA A LA CLÍNICA — hoy 0 %, pero el campo existe
//      por si una clínica pacta otra cosa; es un gasto.
//
// ⚠️ SIN LA COMISIÓN HELIOS DEL PACIENTE, ni suelta ni sumada. La RPC heredada de Ronda
// todavía lo manda (`consumer_fee_*`, `charged_to_customer_*`) y aquí no se
// lee a propósito: lo que Helios le cobra al paciente no es de la clínica.
//
// La RPC puede llegar con los nombres de Ronda (`base_eur`, `sale_eur`…) o
// con los de Helios (`base_usd`, `sale_usd`…): el importe es en dólares en
// los dos casos, lo que cambió fue la moneda, no la columna. `usdOEur` lee
// cualquiera de las dos, y prefiere la de Helios.
// ═══════════════════════════════════════════════════════════════════════════

/** Una fila del libro. */
export type FilaDeVentas = {
  orderNumber: number
  chargeId: string
  businessDate: string
  confirmedAt: string | null
  branchName: string | null
  registeredBy: string | null
  status: string
  voidReason: string | null
  concept: string | null
  beneficiaryName: string | null

  baseUsd: number
  vatPct: number
  vatUsd: number
  saleUsd: number

  merchantFeePct: number
  merchantFeeUsd: number
  merchantFeeVatUsd: number
  netToMerchantUsd: number

  fxRate: number | null
  saleVes: number | null
  netToMerchantVes: number | null

  cuota1Due: string | null
  cuota1Run: string | null
  cuota2Due: string | null
  cuota2Run: string | null
  settledUsd: number
  paidUsd: number

  staffCommissionUsd: number | null
  receipt: EstadoDelComprobante | null
  isTest: boolean
}

/**
 * El valor de `<campo>_usd` o, si no viene, el de `<campo>_eur`: la misma
 * cifra con el nombre que le dejó Ronda.
 */
export function usdOEur(r: Record<string, unknown>, campo: string): number | null {
  return numeroONulo(r[`${campo}_usd`]) ?? numeroONulo(r[`${campo}_eur`])
}

export function leerFilaDeVentas(v: unknown): FilaDeVentas {
  const r = comoFila(v)
  const dinero = (campo: string) => usdOEur(r, campo) ?? 0

  return {
    orderNumber: numero(r.order_number),
    chargeId: texto(r.charge_id),
    businessDate: texto(r.business_date),
    confirmedAt: textoONulo(r.confirmed_at),
    branchName: textoONulo(r.branch_name),
    registeredBy: textoONulo(r.registered_by_name) ?? textoONulo(r.cashier),
    status: texto(r.status),
    voidReason: textoONulo(r.void_reason),
    concept: textoONulo(r.concept),
    beneficiaryName: textoONulo(r.beneficiary_name),

    baseUsd: dinero('base'),
    vatPct: numero(r.vat_pct),
    vatUsd: dinero('vat'),
    saleUsd: dinero('sale'),

    merchantFeePct: numero(r.merchant_fee_pct),
    merchantFeeUsd: dinero('merchant_fee'),
    merchantFeeVatUsd: dinero('merchant_fee_vat'),
    netToMerchantUsd: dinero('net_to_merchant'),

    fxRate: numeroONulo(r.fx_rate),
    saleVes: numeroONulo(r.sale_ves),
    netToMerchantVes: numeroONulo(r.net_to_merchant_ves),

    cuota1Due: textoONulo(r.cuota_1_due),
    cuota1Run: textoONulo(r.cuota_1_run),
    cuota2Due: textoONulo(r.cuota_2_due),
    cuota2Run: textoONulo(r.cuota_2_run),
    settledUsd: dinero('settled'),
    paidUsd: dinero('paid'),

    staffCommissionUsd: usdOEur(r, 'staff_commission'),
    receipt: leerEstadoDelComprobante(r.receipt_status),
    isTest: booleano(r.is_test),
  }
}

/**
 * Cómo se llama cada estado en el archivo. `reverted` va en el libro a
 * propósito: se anotó, movió dinero y se deshizo, y eso es lo que un auditor
 * viene a mirar.
 */
const ESTADO: Record<string, string | undefined> = {
  confirmed: 'Confirmado',
  reverted: 'Revertido',
}

/** Las columnas del libro, en el orden en que se leen. */
export const COLUMNAS_VENTAS: Array<CsvColumn<FilaDeVentas>> = [
  // ── Identificación ──────────────────────────────────────────────────────
  { header: 'Dia operativo', value: (r) => r.businessDate },
  { header: 'Fecha y hora (Caracas)', value: (r) => csvInstante(r.confirmedAt) },
  { header: 'Nro. de orden', value: (r) => csvEntero(r.orderNumber) },
  // El uuid identifica la fila contra cualquier otro extracto de la base.
  { header: 'ID de la orden', value: (r) => r.chargeId },
  { header: 'Sede', value: (r) => r.branchName },
  { header: 'Registrado por', value: (r) => r.registeredBy },
  { header: 'Estado', value: (r) => ESTADO[r.status] ?? r.status },
  { header: 'Motivo de la anulacion', value: (r) => r.voidReason },
  { header: 'Concepto', value: (r) => r.concept },
  { header: 'Paciente atendido', value: (r) => r.beneficiaryName },

  // ── La consulta ─────────────────────────────────────────────────────────
  { header: 'Base imponible USD', value: (r) => csvDinero(r.baseUsd) },
  { header: 'IVA %', value: (r) => csvDinero(r.vatPct) },
  { header: 'IVA USD', value: (r) => csvDinero(r.vatUsd) },
  { header: 'CONSULTA USD', value: (r) => csvDinero(r.saleUsd) },

  // ── Lo que Helios le factura a la clínica ───────────────────────────────
  // «Cargo», no «comisión»: la Comisión Helios es la del paciente y aquí no va.
  { header: 'Cargo de Helios a la clinica %', value: (r) => csvDinero(r.merchantFeePct) },
  { header: 'Cargo de Helios a la clinica USD', value: (r) => csvDinero(r.merchantFeeUsd) },
  { header: 'IVA del cargo USD', value: (r) => csvDinero(r.merchantFeeVatUsd) },
  { header: 'NETO PARA LA CLINICA USD', value: (r) => csvDinero(r.netToMerchantUsd) },

  // ── En bolívares, a la tasa del día de la orden ─────────────────────────
  // Seis decimales: es como la guarda la base, y con dos no cuadra.
  { header: 'Tasa BCV del dia', value: (r) => csvDinero(r.fxRate, 6) },
  { header: 'Consulta Bs', value: (r) => csvDinero(r.saleVes) },
  { header: 'Neto para la clinica Bs', value: (r) => csvDinero(r.netToMerchantVes) },

  // ── Cuándo cobra la clínica ─────────────────────────────────────────────
  { header: 'Cuota 1 vence', value: (r) => r.cuota1Due },
  { header: 'Cuota 1 te la pagamos el', value: (r) => r.cuota1Run },
  { header: 'Cuota 2 vence', value: (r) => r.cuota2Due },
  { header: 'Cuota 2 te la pagamos el', value: (r) => r.cuota2Run },
  { header: 'Liquidado programado USD', value: (r) => csvDinero(r.settledUsd) },
  { header: 'Ya transferido USD', value: (r) => csvDinero(r.paidUsd) },

  // ── Personal y comprobante ──────────────────────────────────────────────
  { header: 'Comision del personal USD', value: (r) => csvDinero(r.staffCommissionUsd) },
  {
    header: 'Comprobante al paciente',
    value: (r) => (r.receipt ? COMPROBANTE[r.receipt].texto : null),
  },

  { header: 'Cuenta de prueba', value: (r) => (r.isTest ? 'SI' : 'No') },
]

/** Lo que lleva el archivo, en una línea para quien lo descarga. */
export const QUE_LLEVA =
  'El libro de pagos en cuotas: la consulta, lo que Helios te factura (hoy nada), el neto, cuándo te lo pagamos y la comisión de quien lo registró. En dólares (las consultas en euros, pasadas a dólares) y en bolívares. Sin la Comisión Helios que paga el paciente.'
