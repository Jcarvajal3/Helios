import { filas, numero, numeroONulo, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Los consumos de una persona, con la cifra que se puede enseñar.
//
// Salen de `admin_user_detail.consumos` (migración 20260925133000). Antes el
// panel los armaba leyendo `charges` e `installments` a mano; ahora la base
// aplica las dos reglas que mandan aquí:
//
//   · La persona está en un consumo si tiene cuotas en él, no solo si lo puso.
//     Un consumo de grupo es UN cargo con una cuota por integrante, y leerlo
//     por `charges.user_id` deja fuera a todos menos a quien abrió el consumo.
//   · El importe que se enseña es el consumo, sin el service fee. El
//     fee solo se ve repartido en las cuotas.
//
// Módulo puro: se prueba en Node (`consumosDePersona.test.ts`).
// ═══════════════════════════════════════════════════════════════════════════

export type ConsumoDePersona = {
  chargeId: string
  orderNumber: number | null
  status: string
  businessDate: string | null
  createdAt: string
  voidReason: string | null
  merchantId: string
  /** Null si el local no tiene nombre: la celda dice «Local sin nombre». */
  merchantName: string | null
  /** FINANCED: el consumo entero en el local, sin fee. */
  cuentaUsd: number
  /**
   * FINANCED: lo que le tocó a esta persona, la suma de lo financiado en sus
   * cuotas. Null si no tiene cuotas en este cargo (pendiente, anulado,
   * revertido, o un grupo en el que no le tocó nada).
   */
  parteUsd: number | null
}

/** La lista `consumos` de `admin_user_detail`, en el orden de la base. */
export function leerConsumosDePersona(raw: unknown): ConsumoDePersona[] {
  return filas(raw).map((c) => ({
    chargeId: texto(c.charge_id),
    orderNumber: numeroONulo(c.order_number),
    status: texto(c.status),
    businessDate: textoONulo(c.business_date),
    createdAt: texto(c.created_at),
    voidReason: textoONulo(c.void_reason),
    merchantId: texto(c.merchant_id),
    merchantName: textoONulo(c.merchant_name),
    cuentaUsd: numero(c.financed_usd),
    parteUsd: numeroONulo(c.share_financed_usd),
  }))
}
