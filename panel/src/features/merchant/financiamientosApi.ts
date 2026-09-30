import { comoLista } from '@/lib/json'
import { supabase } from '@/lib/supabase'

import {
  LIMITE_DE_FILAS,
  leerDetalle,
  leerFilaDeFinanciamiento,
  leerPorPersona,
  leerResumen,
} from './financiamientos'
import type {
  DetalleDeFinanciamiento,
  FilaDeFinanciamiento,
  PorPersona,
  ResumenDeFinanciamientos,
} from './financiamientos'

// ═══════════════════════════════════════════════════════════════════════════
// Las llamadas de Financiamientos. Todas por RPC: el personal de la clínica
// no lee `charges`, `installments` ni `profiles` (la RLS no le deja), y la
// base decide qué ve cada rol. Una secretaria recibe solo lo que registró
// ella; el administrador, la clínica entera.
// ═══════════════════════════════════════════════════════════════════════════

export type PaginaDeFinanciamientos = {
  rows: FilaDeFinanciamiento[]
  /** El rango daba para más de `LIMITE_DE_FILAS`: la lista está recortada.
   *  Los totales NO: los da `fetchResumen` sobre el rango entero. */
  truncated: boolean
}

/** Los financiamientos entre dos días operativos, inclusive. */
export async function fetchFinanciamientos(rango: {
  from: string
  to: string
}): Promise<PaginaDeFinanciamientos> {
  const { data, error } = await supabase.rpc('merchant_transactions', {
    p_from: rango.from,
    p_to: rango.to,
    p_limit: LIMITE_DE_FILAS,
  })
  if (error) throw error

  const lista = comoLista(data)
  return {
    rows: lista.map(leerFilaDeFinanciamiento),
    truncated: lista.length === LIMITE_DE_FILAS,
  }
}

/** Las cifras del rango entero, calculadas en la base. */
export async function fetchResumen(rango: {
  from: string
  to: string
}): Promise<ResumenDeFinanciamientos> {
  const { data, error } = await supabase.rpc('merchant_transactions_summary', {
    p_from: rango.from,
    p_to: rango.to,
  })
  if (error) throw error
  return leerResumen(data)
}

/** Lo registrado por cada persona del personal en el rango. */
export async function fetchPorPersona(rango: { from: string; to: string }): Promise<PorPersona> {
  const { data, error } = await supabase.rpc('merchant_sales_by_staff', {
    p_from: rango.from,
    p_to: rango.to,
  })
  if (error) throw error
  return leerPorPersona(data)
}

/** La ficha de un financiamiento. */
export async function fetchDetalle(chargeId: string): Promise<DetalleDeFinanciamiento> {
  const { data, error } = await supabase.rpc('merchant_charge_detail', {
    p_charge_id: chargeId,
  })
  if (error) throw error
  return leerDetalle(data)
}
