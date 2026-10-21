import {
  comoFila,
  filaONula,
  filas,
  numero,
  numeroONulo,
  texto,
  textoONulo,
} from '@/lib/json'
import { supabase } from '@/lib/supabase'
import { leerMoneda } from '@/components/ui'
import type { Moneda } from '@/components/ui'

/**
 * LA FACTURA DE UN CONSUMO, tal y como la lee el cliente en su teléfono.
 *
 * Las mismas piezas y el mismo orden que el recibo de la app: el consumo en
 * el local, la Comisión Helios, las líneas, el reparto por persona y las cuotas de
 * cada quien. Cuando el equipo y el cliente miran el mismo consumo
 * tienen que leer las mismas cifras — si no, una llamada de soporte empieza
 * discutiendo cuál de las dos pantallas miente.
 *
 * ---------------------------------------------------------------------------
 * Las dos clases de cifra, que NUNCA se suman entre sí
 * ---------------------------------------------------------------------------
 *   `financedUsd`  lo que ocupó cupo: el consumo en el local, sin comisión.
 *   `amountUsd`    lo que se debe, con la Comisión Helios y su IVA ya dentro.
 *
 * `amountUsd` no se enseña suelto como total: un total con la comisión sumado
 * al lado del consumo en el local se lee como que el bar cobró de más. El
 * comisión va en su línea del desglose y repartido en las cuotas.
 */

/** Una línea del local: lo que el cajero tecleó. */
export type ChargeItemLine = {
  name: string
  quantity: number
  unitPriceUsd: number
  lineTotalUsd: number
}

export type ChargeInstallment = {
  id: string
  /** De quién es. En un consumo de grupo hay dos cuotas por persona. */
  userId: string | null
  fullName: string | null
  sequence: number
  /** Lo que se paga, comisión dentro. */
  amountUsd: number
  /** La parte de esa cuota que era consumo. */
  financedUsd: number
  /** La cuota en la moneda de su orden (en una de dólares, igual a `amountUsd`). */
  amountCur: number
  dueDate: string
  status: 'pending' | 'paid'
  paidAt: string | null
  writtenOffAt: string | null
  daysOverdue: number
}

export type ChargeDetail = {
  chargeId: string
  /** El número con el que se habla de esta orden. Ver `ChargeRow.orderNumber`. */
  orderNumber: number | null
  status: string
  businessDate: string | null
  createdAt: string
  confirmedAt: string | null
  voidReason: string | null
  /** Con la Comisión Helios y su IVA dentro. No se enseña como total suelto. */
  amountUsd: number
  /** El consumo en el local: lo que ocupó cupo. */
  financedUsd: number
  consumerFeeUsd: number | null
  consumerFeeVatUsd: number | null
  merchantFeeUsd: number | null
  /** El IVA de la comisión del local: `merchantNetUsd` = consumo − comisión − este IVA. */
  merchantFeeVatUsd: number | null
  merchantNetUsd: number | null
  /**
   * La moneda en que el médico cobró la orden (2026-10-07). Todas las cifras
   * `Usd` de arriba siguen en dólares: una orden en euros se pasó a dólares
   * con la tasa cruzada del BCV del día en que se registró.
   */
  currency: Moneda
  /** Dólares por unidad de la moneda el día del registro (1 en las de dólares). */
  fxUsdPerUnit: number | null
  /** El desglose en la moneda de la orden: lo que vieron el paciente y la clínica. */
  amountCur: number | null
  baseCur: number | null
  consumerFeeCur: number | null
  consumerFeeVatCur: number | null
  isTest: boolean
  merchant: { id: string; name: string; legalName: string | null; taxId: string | null }
  branch: { id: string; name: string | null; address: string | null } | null
  user: { id: string; fullName: string | null; phone: string | null } | null
  items: ChargeItemLine[]
  installments: ChargeInstallment[]
}

export async function fetchChargeDetail(chargeId: string): Promise<ChargeDetail> {
  const { data, error } = await supabase.rpc('admin_charge_detail', {
    p_charge_id: chargeId,
  })
  if (error) throw error

  const raw = comoFila(data)
  const merchant = comoFila(raw.merchant)
  const branch = filaONula(raw.branch)
  const user = filaONula(raw.user)
  const amountUsd = numero(raw.amount_usd)

  return {
    chargeId: texto(raw.charge_id),
    orderNumber: numeroONulo(raw.order_number),
    status: texto(raw.status),
    businessDate: textoONulo(raw.business_date),
    createdAt: texto(raw.created_at),
    confirmedAt: textoONulo(raw.confirmed_at),
    voidReason: textoONulo(raw.void_reason),
    amountUsd,
    /**
     * Sin `financed_usd` el consumo ES el total: o el cobro es anterior al
     * desglose de la comisión, o la base todavía no tiene aplicada la migración
     * 20260917130000. En los dos casos la pantalla enseña una sola cifra en
     * vez de inventarse un desglose que no cuadraría.
     */
    financedUsd: numeroONulo(raw.financed_usd) ?? amountUsd,
    consumerFeeUsd: numeroONulo(raw.consumer_fee_usd),
    consumerFeeVatUsd: numeroONulo(raw.consumer_fee_vat_usd),
    merchantFeeUsd: numeroONulo(raw.merchant_fee_usd),
    merchantFeeVatUsd: numeroONulo(raw.merchant_fee_vat_usd),
    merchantNetUsd: numeroONulo(raw.merchant_net_usd),
    currency: leerMoneda(raw.currency),
    fxUsdPerUnit: numeroONulo(raw.fx_usd_per_unit),
    amountCur: numeroONulo(raw.amount_cur),
    baseCur: numeroONulo(raw.base_cur),
    consumerFeeCur: numeroONulo(raw.consumer_fee_cur),
    consumerFeeVatCur: numeroONulo(raw.consumer_fee_vat_cur),
    isTest: raw.is_test === true,
    merchant: {
      id: texto(merchant.id),
      name: texto(merchant.name),
      legalName: textoONulo(merchant.legal_name),
      taxId: textoONulo(merchant.tax_id),
    },
    branch: branch
      ? { id: texto(branch.id), name: textoONulo(branch.name), address: textoONulo(branch.address) }
      : null,
    user: user
      ? { id: texto(user.id), fullName: textoONulo(user.full_name), phone: textoONulo(user.phone_e164) }
      : null,
    items: filas(raw.items).map((i) => ({
      name: texto(i.name),
      quantity: numero(i.quantity),
      unitPriceUsd: numero(i.unit_price_usd),
      lineTotalUsd: numero(i.line_total_usd),
    })),
    installments: filas(raw.installments).map((i) => ({
      id: texto(i.id),
      userId: textoONulo(i.user_id),
      fullName: textoONulo(i.full_name),
      sequence: numero(i.sequence),
      amountUsd: numero(i.amount_usd),
      financedUsd: numero(i.financed_usd),
      amountCur: numeroONulo(i.amount_cur) ?? numero(i.amount_usd),
      dueDate: texto(i.due_date),
      status: i.status === 'paid' ? 'paid' : 'pending',
      paidAt: textoONulo(i.paid_at),
      writtenOffAt: textoONulo(i.written_off_at),
      daysOverdue: numero(i.days_overdue),
    })),
  }
}

/**
 * Si un consumo confirmado se puede revertir, y si no, por qué.
 *
 * Se pregunta **antes** de enseñar el botón: un botón que explica al pulsarlo
 * por qué no se puede pulsar es un callejón.
 */
export async function canReverseCharge(
  chargeId: string,
): Promise<{ canReverse: boolean; reason: string | null }> {
  const { data, error } = await supabase.rpc('admin_can_reverse_charge', {
    p_charge_id: chargeId,
  })
  if (error) throw error

  const raw = comoFila(data)
  return {
    canReverse: raw.can_reverse === true,
    reason: textoONulo(raw.reason),
  }
}

/**
 * Deshace un consumo confirmado.
 *
 * El servidor escribe el asiento contrario —el original se queda—, borra las
 * cuotas, cancela las liquidaciones que no se hayan pagado y devuelve el cupo.
 * Solo si ninguna cuota tiene pagos ni pagos reportados, al local no se le
 * transfirió nada de él y nadie tiene un pago abierto sin reportar. Las
 * cotizaciones caducadas las borra el servidor.
 */
export async function reverseCharge(chargeId: string, reason: string): Promise<void> {
  const { error } = await supabase.rpc('admin_reverse_charge', {
    p_charge_id: chargeId,
    p_reason: reason,
  })
  if (error) throw error
}
