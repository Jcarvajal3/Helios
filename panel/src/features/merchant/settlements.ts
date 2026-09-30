import { comoLista } from '@/lib/json'
import { supabase } from '@/lib/supabase'

import {
  leerLineaDeTransferencia,
  leerLiquidacion,
  leerPrevision,
  leerTransferencia,
} from './pagos'
import type { Liquidacion, Prevision, Transferencia } from './pagos'

/**
 * Lo que Helios le debe a la clínica y lo que ya le transfirió.
 *
 * Son dos cosas distintas y el modelo las separa a propósito: al vencer una
 * cuota (o al confirmar, para la comisión) **se devenga** una obligación, y
 * solo cuando el equipo de Helios transfiere de verdad **sale el dinero**.
 *
 * Todo lo de aquí lo lee solo el administrador (`gerente`): es la RLS de
 * `settlements` y `merchant_payouts`, no una decisión del panel.
 */

/**
 * La previsión: lo del próximo lunes y lo que falta en total. Por RPC y no
 * contra la vista `merchant_payables`, porque la cuota que aún no ha vencido
 * no existe en ninguna tabla que la clínica pueda leer.
 */
export async function fetchPrevision(): Promise<Prevision> {
  // Sin `merchantId`: la RPC lo saca de la sesión, así que no se puede pedir
  // la caja de otra clínica ni por error.
  const { data, error } = await supabase.rpc('merchant_settlement_outlook')
  if (error) throw error
  return leerPrevision(data)
}

/** Lo devengado y sin transferir todavía, línea a línea, con su motivo. */
export async function fetchPorTransferir(merchantId: string): Promise<Liquidacion[]> {
  const { data, error } = await supabase
    .from('settlements')
    .select('id, reason, amount_usd, due_date, business_date')
    .eq('merchant_id', merchantId)
    .eq('status', 'pending')
    .order('due_date', { ascending: true })

  if (error) throw error
  return comoLista(data).map(leerLiquidacion)
}

/**
 * Las transferencias recibidas, con sus líneas embebidas para poder partir
 * cada una en consultas y comisiones.
 *
 * `*` en las dos tablas a propósito: si la base ya trae `consultas_usd` y
 * `comisiones_usd` en la transferencia, o `reason` en la línea (contrato
 * §1.5), se leen; si no, el reparto sale de la liquidación de cada línea.
 * Pedir esas columnas por nombre haría fallar la pantalla entera contra una
 * base que todavía no las tiene.
 */
export async function fetchTransferencias(merchantId: string): Promise<Transferencia[]> {
  const { data, error } = await supabase
    .from('merchant_payouts')
    .select('*, merchant_payout_items(*, settlements(reason))')
    .eq('merchant_id', merchantId)
    .order('created_at', { ascending: false })

  if (error) throw error
  return comoLista(data).map(leerTransferencia)
}

/** Qué liquidaciones cubrió una transferencia, con sus fechas. */
export async function fetchLineasDeTransferencia(payoutId: string): Promise<Liquidacion[]> {
  const { data, error } = await supabase
    .from('merchant_payout_items')
    .select('*, settlements(id, reason, due_date, business_date)')
    .eq('payout_id', payoutId)

  if (error) throw error
  return comoLista(data)
    .map(leerLineaDeTransferencia)
    .filter((l): l is Liquidacion => l !== null)
    .sort((a, b) => a.dueDate.localeCompare(b.dueDate))
}
