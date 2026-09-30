import { useQuery } from '@tanstack/react-query'

import { leerPorCobrar } from '@/features/admin/porCobrar'
import type { PorCobrar, VerPorCobrar } from '@/features/admin/porCobrar'
import { domingoDe } from '@/features/admin/semana'
import { supabase } from '@/lib/supabase'

/** Lo que vence de `desde` a `hasta`, por día y por local. */
export async function fetchPorCobrar(
  desde: string,
  hasta: string,
  ver: VerPorCobrar,
): Promise<PorCobrar> {
  const { data, error } = await supabase.rpc('admin_receivables_by_day', {
    p_desde: desde,
    p_hasta: hasta,
    p_incluir_pagadas: ver === 'todo',
  })
  if (error) throw error
  return leerPorCobrar(data)
}

/**
 * La semana que empieza en `lunes`. Sin datos de la semana anterior mientras
 * llega la nueva: el selector ya dice la semana nueva, y unas cifras de la
 * vieja debajo se leerían como suyas.
 */
export function usePorCobrar(lunes: string, ver: VerPorCobrar) {
  return useQuery({
    queryKey: ['admin-por-cobrar', lunes, ver],
    queryFn: () => fetchPorCobrar(lunes, domingoDe(lunes), ver),
  })
}
