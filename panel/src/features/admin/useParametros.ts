import { useQuery } from '@tanstack/react-query'

import { comoFila, comoLista } from '@/lib/json'
import { leerParametro } from '@/features/admin/parametros'
import type { Parametros } from '@/features/admin/parametros'
import { supabase } from '@/lib/supabase'

// La lectura de los parámetros desde la base. Va aparte de `parametros.ts`
// para que la lógica pura (tramos, umbrales) se pueda probar en Node sin
// arrastrar el cliente de Supabase.

/** Todos los parámetros, también los que existen sin valor. */
export async function fetchParametros(): Promise<Parametros> {
  const { data, error } = await supabase.rpc('admin_business_parameters', {
    p_incluir_sin_valor: true,
  })
  if (error) throw error

  const raw = comoFila(data)
  return {
    businessDate: String(raw.business_date),
    filas: comoLista(raw.rows).map(leerParametro),
  }
}

/** La clave de caché: la comparten todas las pantallas que leen parámetros. */
export const CLAVE_PARAMETROS = ['parametros', 'todos'] as const

/**
 * Los parámetros vigentes. Cambian muy de vez en cuando, así que se dan por
 * buenos cinco minutos; quien los edita invalida `CLAVE_PARAMETROS`.
 */
export function useParametros() {
  return useQuery({
    queryKey: CLAVE_PARAMETROS,
    queryFn: fetchParametros,
    staleTime: 5 * 60_000,
  })
}
