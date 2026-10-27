import { queryOptions } from '@tanstack/react-query'
import type { QueryClient } from '@tanstack/react-query'

import { supabase } from '@/lib/supabase'
import { leerInteresados, leerTablero } from './directorioDeMedicos'

// ═══════════════════════════════════════════════════════════════════════════
// La lectura y la escritura del Directorio de médicos del superadmin.
// ═══════════════════════════════════════════════════════════════════════════

const CLAVE = ['admin-directorio-medicos'] as const

/** Cuánto tarda en verse un clic nuevo con la pantalla abierta. */
export const RELECTURA_MS = 30_000

/** Cuántos interesados trae la lista, los más recientes: la pantalla avisa si llega al tope. */
export const TOPE_DE_INTERESADOS = 200

/**
 * Cada clínica con su tarjeta, su ficha y sus clics, y el total por día.
 *
 * Se relee sola cada 30 s con la pestaña delante, y en el acto al volver a
 * ella: los clics llegan mientras se mira. Con la pestaña oculta no pregunta
 * (el panel apaga por defecto el refresco al volver, ver `__root.tsx`).
 */
export function consultaDirectorio() {
  return queryOptions({
    queryKey: [...CLAVE, 'tablero'],
    refetchInterval: RELECTURA_MS,
    refetchOnWindowFocus: true,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('admin_directorio')
      if (error) throw error
      return leerTablero(data)
    },
  })
}

/**
 * Quien escribió al WhatsApp de Helios desde una tarjeta, el más reciente
 * primero, con su estado (si ya es paciente de ese médico). Sin médico, los
 * de todos; con él, solo los suyos (la ficha). Se relee como el tablero: un
 * interesado llega mientras se mira.
 */
export function consultaInteresados(merchantId?: string) {
  return queryOptions({
    queryKey: [...CLAVE, 'interesados', merchantId ?? 'todos'],
    refetchInterval: RELECTURA_MS,
    refetchOnWindowFocus: true,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('admin_directorio_interesados', {
        p_merchant_id: merchantId ?? null,
        p_limit: TOPE_DE_INTERESADOS,
      })
      if (error) throw error
      return leerInteresados(data)
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
