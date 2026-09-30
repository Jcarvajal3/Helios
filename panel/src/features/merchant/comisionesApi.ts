import { supabase } from '@/lib/supabase'

import { leerComisiones, leerItemsDeComision } from './comisiones'
import type { ComisionDePersona, ItemDeComision } from './comisiones'

/**
 * Las comisiones por persona del rango (contrato §1.6). El administrador
 * recibe todas; la secretaria, solo su fila.
 */
export async function fetchComisiones(rango: {
  from: string
  to: string
}): Promise<ComisionDePersona[]> {
  const { data, error } = await supabase.rpc('merchant_commissions', {
    p_from: rango.from,
    p_to: rango.to,
  })
  if (error) throw error
  return leerComisiones(data)
}

/**
 * Las comisiones de una persona, financiamiento a financiamiento. Sin
 * `staffUserId`, las de quien mira (la base lo resuelve con la sesión).
 */
export async function fetchItemsDeComision(params: {
  from: string
  to: string
  staffUserId: string | null
}): Promise<ItemDeComision[]> {
  const { data, error } = await supabase.rpc('merchant_commission_items', {
    p_from: params.from,
    p_to: params.to,
    p_staff_user_id: params.staffUserId,
  })
  if (error) throw error
  return leerItemsDeComision(data)
}
