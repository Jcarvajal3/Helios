import { supabase } from '@/lib/supabase'
import { leerDirectorio, visitante } from './directorio'
import type { MedicoDelDirectorio } from './directorio'

/** Los médicos publicados. Pública: la lee cualquiera, con o sin sesión. */
export async function consultarDirectorio(): Promise<MedicoDelDirectorio[]> {
  const { data, error } = await supabase.rpc('helios_directorio')
  if (error) throw error
  return leerDirectorio(data)
}

/**
 * Apunta el toque al botón de WhatsApp. No se espera ni se avisa de un
 * fallo: el chat se abre igual, que es lo que importa al paciente.
 */
export function apuntarContacto(merchantId: string): void {
  void supabase
    .rpc('helios_directorio_contacto', { p_merchant_id: merchantId, p_visitante: visitante() })
    .then(
      () => undefined,
      () => undefined,
    )
}
