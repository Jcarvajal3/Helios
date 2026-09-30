import { supabase } from '@/lib/supabase'
import {
  construirCsv,
  csvDinero,
  csvEntero,
  csvInstante,
  descargarCsv,
} from '@/lib/csv'
import type { CsvColumn } from '@/lib/csv'

// ═══════════════════════════════════════════════════════════════════════════
// Las ventas del local, para contabilidad.
//
// Dos partes que en los libros no son la misma cosa:
//
//   1. LA VENTA DEL LOCAL — base imponible + IVA. Es su ingreso.
//   2. LA COMISIÓN DEL LOCAL — lo que Ronda le factura. Es un GASTO, y le
//      llega como factura aparte: tiene que poder cruzarla contra esto.
//
// ⚠️ SIN EL FEE DEL CONSUMIDOR, ni suelto ni sumado (decisión de Javier,
// 2026-09-22): el panel de comercio maneja solo montos sin el fee de Ronda. Lo
// que Ronda le cobra al cliente no es ingreso del local ni le compete, y el
// único sitio del panel donde aparece es el desglose de Cobrar y de la ficha
// de una orden, que es lo que el cliente tiene delante.
//
// Y las dos en euros y en bolívares a la tasa del DÍA DE LA VENTA. Los libros
// se llevan en bolívares y convertir con la tasa de hoy pondría una venta de
// marzo a precio de septiembre.
// ═══════════════════════════════════════════════════════════════════════════

/** Una orden, con su desglose entero. Una fila del libro de ventas. */
export type SaleRow = {
  orderNumber: number
  chargeId: string
  businessDate: string
  confirmedAt: string | null
  branchName: string | null
  cashier: string | null
  status: string
  voidReason: string | null

  itemCount: number

  baseEur: number
  vatPct: number
  vatEur: number
  saleEur: number

  merchantFeePct: number
  merchantFeeEur: number
  merchantFeeVatEur: number
  netToMerchantEur: number

  fxRate: number | null
  saleVes: number | null
  netToMerchantVes: number | null

  cuota1Due: string | null
  cuota1Run: string | null
  cuota2Due: string | null
  cuota2Run: string | null
  settledEur: number
  paidEur: number

  isTest: boolean
}

/** Una línea de producto dentro de una orden. */
const n = (v: unknown): number => Number(v ?? 0)
const nullable = (v: unknown): number | null => (v === null || v === undefined ? null : Number(v))
const text = (v: unknown): string | null => (v === null || v === undefined ? null : String(v))

export async function fetchSalesExport(params: {
  from: string
  to: string
}): Promise<SaleRow[]> {
  const { data, error } = await supabase.rpc('merchant_sales_export', {
    p_from: params.from,
    p_to: params.to,
  })
  if (error) throw error

  return (data as Array<Record<string, unknown>>).map((r) => ({
    orderNumber: n(r.order_number),
    chargeId: String(r.charge_id),
    businessDate: String(r.business_date),
    confirmedAt: text(r.confirmed_at),
    branchName: text(r.branch_name),
    cashier: text(r.cashier),
    status: String(r.status),
    voidReason: text(r.void_reason),

    itemCount: n(r.item_count),

    baseEur: n(r.base_eur),
    vatPct: n(r.vat_pct),
    vatEur: n(r.vat_eur),
    saleEur: n(r.sale_eur),

    merchantFeePct: n(r.merchant_fee_pct),
    merchantFeeEur: n(r.merchant_fee_eur),
    merchantFeeVatEur: n(r.merchant_fee_vat_eur),
    netToMerchantEur: n(r.net_to_merchant_eur),

    fxRate: nullable(r.fx_rate),
    saleVes: nullable(r.sale_ves),
    netToMerchantVes: nullable(r.net_to_merchant_ves),

    cuota1Due: text(r.cuota_1_due),
    cuota1Run: text(r.cuota_1_run),
    cuota2Due: text(r.cuota_2_due),
    cuota2Run: text(r.cuota_2_run),
    settledEur: n(r.settled_eur),
    paidEur: n(r.paid_eur),

    isTest: Boolean(r.is_test),
  }))
}

/**
 * Cómo se llama cada estado en el archivo.
 *
 * `reverted` va en el libro a propósito: una venta deshecha se anotó, movió
 * dinero y se anuló, y eso es justo lo que un auditor viene a mirar. Si
 * desapareciera, faltaría sin dejar rastro.
 */
const ESTADO: Record<string, string | undefined> = {
  confirmed: 'Confirmada',
  reverted: 'Revertida',
}

/** Las columnas del libro de ventas, en el orden en que se leen. */
const COLUMNAS_VENTAS: Array<CsvColumn<SaleRow>> = [
  // ── Identificación ──────────────────────────────────────────────────────
  { header: 'Dia operativo', value: (r) => r.businessDate },
  { header: 'Fecha y hora (Caracas)', value: (r) => csvInstante(r.confirmedAt) },
  { header: 'Nro. de orden', value: (r) => csvEntero(r.orderNumber) },
  // El uuid no es decorativo: el número de orden es único y estable, pero el
  // id es lo que identifica la fila contra cualquier otro extracto de la base.
  { header: 'ID del financiamiento', value: (r) => r.chargeId },
  { header: 'Sede', value: (r) => r.branchName },
  { header: 'Registrado por', value: (r) => r.cashier },
  { header: 'Estado', value: (r) => ESTADO[r.status] ?? r.status },
  { header: 'Motivo de la anulacion', value: (r) => r.voidReason },

  // ── Qué se vendió ───────────────────────────────────────────────────────
  { header: 'Lineas', value: (r) => csvEntero(r.itemCount) },

  // ── La venta del local ──────────────────────────────────────────────────
  { header: 'Base imponible USD', value: (r) => csvDinero(r.baseEur) },
  { header: 'IVA %', value: (r) => csvDinero(r.vatPct) },
  { header: 'IVA del financiamiento USD', value: (r) => csvDinero(r.vatEur) },
  { header: 'TU VENTA USD', value: (r) => csvDinero(r.saleEur) },

  // ── Lo que Ronda le factura al local ────────────────────────────────────
  { header: 'Comision de Helios %', value: (r) => csvDinero(r.merchantFeePct) },
  { header: 'Comision de Helios USD', value: (r) => csvDinero(r.merchantFeeEur) },
  { header: 'IVA de la comision USD', value: (r) => csvDinero(r.merchantFeeVatEur) },
  { header: 'NETO PARA TI USD', value: (r) => csvDinero(r.netToMerchantEur) },

  // ── En bolívares, a la tasa del día de la venta ─────────────────────────
  // Seis decimales en la tasa: es como la guarda la base y es la que hay que
  // usar para rehacer la conversión. Recortada a dos, las cuentas no cuadran.
  { header: 'Tasa BCV del dia', value: (r) => csvDinero(r.fxRate, 6) },
  { header: 'Tu financiamiento Bs', value: (r) => csvDinero(r.saleVes) },
  { header: 'Neto para ti Bs', value: (r) => csvDinero(r.netToMerchantVes) },

  // ── Cuándo cobra el local ───────────────────────────────────────────────
  { header: 'Cuota 1 vence', value: (r) => r.cuota1Due },
  { header: 'Cuota 1 te la pagamos el', value: (r) => r.cuota1Run },
  { header: 'Cuota 2 vence', value: (r) => r.cuota2Due },
  { header: 'Cuota 2 te la pagamos el', value: (r) => r.cuota2Run },
  { header: 'Liquidado programado USD', value: (r) => csvDinero(r.settledEur) },
  { header: 'Ya transferido USD', value: (r) => csvDinero(r.paidEur) },

  { header: 'Cuenta de prueba', value: (r) => (r.isTest ? 'SI' : 'No') },
]

/** Lo que lleva cada fila del archivo, dicho en una línea para quien lo descarga. */
export const QUE_LLEVA =
  'El libro de financiamientos: base imponible, IVA, la comisión que Helios te factura, el neto y cuándo te lo pagamos. En dólares y en bolívares.'

/**
 * Arma el archivo y lo descarga.
 *
 * El nombre lleva el rango dentro: en la carpeta del contador van a acabar
 * doce de estos, y «ventas.csv (3)» no le dice a nadie de qué mes es.
 */
export async function descargarVentas(params: {
  from: string
  to: string
  merchantName: string
}): Promise<number> {
  const rango = params.from === params.to ? params.from : `${params.from}_a_${params.to}`
  const local = params.merchantName
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-zA-Z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .toLowerCase()

  const filas = await fetchSalesExport(params)
  descargarCsv(`helios_${local}_ventas_${rango}`, construirCsv(COLUMNAS_VENTAS, filas))
  return filas.length
}
