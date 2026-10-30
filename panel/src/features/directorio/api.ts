import { SUPABASE_ANON_KEY, SUPABASE_URL, supabase } from '@/lib/supabase'
import { INTERESADOS_POR_HELIOS, leerDirectorio, visitante } from './directorio'
import { origenDelClic } from './origen'
import type { MedicoDelDirectorio } from './directorio'

/** Los médicos publicados. Pública: la lee cualquiera, con o sin sesión. */
export async function consultarDirectorio(): Promise<MedicoDelDirectorio[]> {
  const { data, error } = await supabase.rpc('helios_directorio')
  if (error) throw error
  return leerDirectorio(data)
}

/**
 * Lo que necesitan `/directorio`, sus especialidades y las fichas: los
 * médicos y el número de Helios, a la vez. El número nunca falla (sin él,
 * cada botón va directo al médico); con `INTERESADOS_POR_HELIOS` apagado ni
 * se pide. Si la lista falla, la página lo dice y deja reintentar.
 */
export async function cargarDirectorio(): Promise<{
  medicos: MedicoDelDirectorio[]
  fallo: boolean
  whatsappHelios: string | null
}> {
  const whatsappHelios = INTERESADOS_POR_HELIOS ? consultarWhatsappDeHelios() : Promise.resolve(null)
  try {
    return { medicos: await consultarDirectorio(), fallo: false, whatsappHelios: await whatsappHelios }
  } catch {
    return { medicos: [], fallo: true, whatsappHelios: await whatsappHelios }
  }
}

/** Un médico publicado por el enlace de su ficha; `null` si no existe o ya no sale. */
export async function consultarMedico(slug: string): Promise<MedicoDelDirectorio | null> {
  const { data, error } = await supabase.rpc('helios_directorio_medico', { p_slug: slug })
  if (error) throw error
  return leerDirectorio(data)[0] ?? null
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
  // Con el origen de la visita (`origen.ts`): qué buscador o red trajo el clic.
  const cuerpo = JSON.stringify({
    p_merchant_id: merchantId,
    p_visitante: visitante() ?? null,
    p_origen: origenDelClic(),
  })
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
