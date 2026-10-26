import { queryOptions } from '@tanstack/react-query'
import type { QueryClient } from '@tanstack/react-query'

import { supabase } from '@/lib/supabase'
import { leerTablero } from './directorioDeMedicos'

// ═══════════════════════════════════════════════════════════════════════════
// La lectura y la escritura del Directorio de médicos del superadmin.
// ═══════════════════════════════════════════════════════════════════════════

const CLAVE = ['admin-directorio-medicos'] as const

/** Cada clínica con su tarjeta, su ficha y sus clics, y el total por día. */
export function consultaDirectorio() {
  return queryOptions({
    queryKey: [...CLAVE, 'tablero'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('admin_directorio')
      if (error) throw error
      return leerTablero(data)
    },
  })
}

/**
 * Publica u oculta una clínica, o corrige su tarjeta. La base rechaza, con
 * un mensaje que se puede enseñar tal cual, publicar una clínica que no se
 * puede publicar y un dato fuera de medida.
 */
export async function guardarTarjeta(merchantId: string, cambios: Record<string, string | boolean>): Promise<void> {
  const { error } = await supabase.rpc('admin_directorio_guardar', {
    p_merchant_id: merchantId,
    p_cambios: cambios,
  })
  if (error) throw error
}

export function refrescarDirectorio(client: QueryClient): void {
  void client.invalidateQueries({ queryKey: CLAVE })
}
