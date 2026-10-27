import { SUPABASE_ANON_KEY, SUPABASE_URL, supabase } from '@/lib/supabase'
import { leerDirectorio, visitante } from './directorio'
import type { MedicoDelDirectorio } from './directorio'

/** Los médicos publicados. Pública: la lee cualquiera, con o sin sesión. */
export async function consultarDirectorio(): Promise<MedicoDelDirectorio[]> {
  const { data, error } = await supabase.rpc('helios_directorio')
  if (error) throw error
  return leerDirectorio(data)
}

/**
 * El número de WhatsApp de Helios (E.164, '+58422…'), al que lleva el botón
 * de cada tarjeta con su código. Pública. Sin número o si falla, `null`: el
 * botón vuelve al chat directo con el médico y la página no se rompe.
 */
export async function consultarWhatsappDeHelios(): Promise<string | null> {
  try {
    const { data, error } = await supabase.rpc('helios_directorio_whatsapp')
    if (error) return null
    return typeof data === 'string' && data.trim() !== '' ? data.trim() : null
  } catch {
    return null
  }
}

/**
 * Apunta el toque al botón de WhatsApp. No se espera ni se avisa de un
 * fallo: el chat se abre igual, que es lo que importa al paciente.
 *
 * Va con `fetch` y `keepalive` y no con `supabase.rpc`: en el teléfono, el
 * toque abre la app de WhatsApp y el navegador suspende la página, y una
 * petición normal se quedaba a medias. Con `keepalive` el navegador la
 * termina aunque la página ya no esté delante. Lleva la sesión si la hay,
 * para que la base siga sabiendo que el clic es del equipo o de una clínica
 * y no lo cuente.
 */
export function apuntarContacto(merchantId: string): void {
  const cuerpo = JSON.stringify({ p_merchant_id: merchantId, p_visitante: visitante() ?? null })
  void supabase.auth
    .getSession()
    // Sin sesión legible, el clic va igual, como de un paciente.
    .then(
      ({ data }) => data.session?.access_token,
      () => undefined,
    )
    .then((token) =>
      fetch(`${SUPABASE_URL}/rest/v1/rpc/helios_directorio_contacto`, {
        method: 'POST',
        keepalive: true,
        headers: {
          'Content-Type': 'application/json',
          apikey: SUPABASE_ANON_KEY,
          Authorization: `Bearer ${token ?? SUPABASE_ANON_KEY}`,
        },
        body: cuerpo,
      }),
    )
    .then(
      () => undefined,
      () => undefined,
    )
}
