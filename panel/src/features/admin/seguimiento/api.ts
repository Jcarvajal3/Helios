import { queryOptions } from '@tanstack/react-query'
import type { QueryClient } from '@tanstack/react-query'

import { supabase } from '@/lib/supabase'
import { aParametros, leerHistoria, leerTablero } from './seguimiento'
import type { BorradorDeSeguimiento } from './seguimiento'

// ═══════════════════════════════════════════════════════════════════════════
// Las lecturas y la escritura del Seguimiento, con sus claves de caché.
//
// Todo cuelga de ['admin-seguimiento', …]: anotar un contacto invalida el
// tablero y la historia de esa clínica de una vez.
// ═══════════════════════════════════════════════════════════════════════════

const CLAVE_SEGUIMIENTO = ['admin-seguimiento'] as const

/** Cada clínica con su médico, su personal, sus órdenes y su último contacto. */
export function consultaTablero() {
  return queryOptions({
    queryKey: [...CLAVE_SEGUIMIENTO, 'tablero'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('admin_followups_board')
      if (error) throw error
      return leerTablero(data)
    },
  })
}

/** Los contactos anotados con una clínica, el último primero. */
export function consultaHistoria(merchantId: string) {
  return queryOptions({
    queryKey: [...CLAVE_SEGUIMIENTO, 'historia', merchantId],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('admin_merchant_followups', {
        p_merchant_id: merchantId,
        p_limit: 50,
      })
      if (error) throw error
      return leerHistoria(data)
    },
  })
}

/**
 * Anota un contacto. La base rechaza, con un mensaje que se puede enseñar tal
 * cual, una nota vacía, una persona de otra clínica y una fecha pasada.
 */
export async function anotarSeguimiento(merchantId: string, borrador: BorradorDeSeguimiento): Promise<void> {
  const { error } = await supabase.rpc('admin_log_merchant_followup', aParametros(merchantId, borrador))
  if (error) throw error
}

export function refrescarSeguimiento(client: QueryClient): void {
  void client.invalidateQueries({ queryKey: CLAVE_SEGUIMIENTO })
}
