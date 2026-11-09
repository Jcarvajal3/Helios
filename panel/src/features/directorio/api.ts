import { SUPABASE_ANON_KEY, SUPABASE_URL, supabase } from '@/lib/supabase'
import { INTERESADOS_POR_HELIOS, leerDirectorio, visitante } from './directorio'
import { origenDelClic } from './origen'
import type { MedicoDelDirectorio, VarianteDelDirectorio } from './directorio'

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

/**
 * Lo que necesita `/consultas` (la variante B, docs/06): los médicos que
 * entran en B (`helios_directorio_consultas()`: las columnas de
 * `helios_directorio()` y en su mismo orden sorteado; la que sobra,
 * `consultation_price_usd`, la página no la usa) y el número de Helios, que
 * aquí se pide siempre: el botón de B pasa por el WhatsApp de Helios aunque
 * `INTERESADOS_POR_HELIOS` esté apagado. Si la lista falla, la página lo
 * dice y deja reintentar.
 */
export async function cargarConsultas(): Promise<{
  medicos: MedicoDelDirectorio[]
  fallo: boolean
  whatsappHelios: string | null
}> {
  const whatsappHelios = consultarWhatsappDeHelios()
  try {
    const { data, error } = await supabase.rpc('helios_directorio_consultas')
    if (error) throw error
    return { medicos: leerDirectorio(data), fallo: false, whatsappHelios: await whatsappHelios }
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
 * Llama a una RPC pública sin esperar la respuesta ni avisar de un fallo:
 * lo que apunta (un clic, una visita) nunca estorba al paciente.
 *
 * Va con `fetch` y `keepalive` y no con `supabase.rpc`: en el teléfono, el
 * toque abre la app de WhatsApp y el navegador suspende la página, y una
 * petición normal se quedaba a medias. Con `keepalive` el navegador la
 * termina aunque la página ya no esté delante. Lleva la sesión si la hay,
 * para que la base siga sabiendo que es del equipo o de una clínica y no
 * lo cuente.
 */
function apuntarSinEsperar(rpc: string, argumentos: Record<string, unknown>): void {
  const cuerpo = JSON.stringify(argumentos)
  void supabase.auth
    .getSession()
    // Sin sesión legible, va igual, como de un paciente.
    .then(
      ({ data }) => data.session?.access_token,
      () => undefined,
    )
    .then((token) =>
      fetch(`${SUPABASE_URL}/rest/v1/rpc/${rpc}`, {
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

/**
 * Apunta el toque al botón de WhatsApp (`helios_directorio_contacto`), con
 * el origen de la visita (`origen.ts`: qué buscador o red trajo el clic) y
 * la variante de la página. No se espera ni se avisa de un fallo: el chat se
 * abre igual, que es lo que importa al paciente.
 *
 * `p_variante` solo va con `'b'`: la base la toma como `'a'` si no llega,
 * así que los clics de A no dependen de que la firma nueva ya esté aplicada.
 */
export function apuntarContacto(merchantId: string, variante: VarianteDelDirectorio = 'a'): void {
  apuntarSinEsperar('helios_directorio_contacto', {
    p_merchant_id: merchantId,
    p_visitante: visitante() ?? null,
    p_origen: origenDelClic(),
    ...(variante === 'b' ? { p_variante: 'b' } : {}),
  })
}

/** Los agentes de buscadores, redes y pruebas automáticas que ejecutan JavaScript. */
export const AGENTE_DE_ROBOT =
  /bot|crawl|spider|slurp|mediapartners|google-inspectiontool|lighthouse|headless|phantomjs|facebookexternalhit/i

/** ¿Lee la página un robot y no una persona? Sin `navigator` (servidor), sí: no se apunta nada. */
export function esUnRobot(): boolean {
  try {
    if (typeof navigator === 'undefined') return true
    return navigator.webdriver === true || AGENTE_DE_ROBOT.test(navigator.userAgent)
  } catch {
    return false
  }
}

/**
 * Apunta una visita a una página del directorio (`helios_directorio_visita`):
 * con ella se cuentan los visitantes de cada variante de la prueba A/B. Se
 * llama una vez por página montada (`useVisitaDelDirectorio`); la base
 * descarta la misma página del mismo visitante en 30 minutos. Ni se espera
 * ni se avisa de un fallo.
 */
export function apuntarVisita(variante: VarianteDelDirectorio): void {
  // Los buscadores ejecutan la página y cada lectura trae un visitante nuevo
  // que nunca toca un botón: inflarían los visitantes de A (indexada) y no
  // los de B (`noindex`), y la prueba se inclinaría hacia B.
  if (esUnRobot()) return
  apuntarSinEsperar('helios_directorio_visita', {
    p_variante: variante,
    p_visitante: visitante() ?? null,
    p_origen: origenDelClic(),
  })
}
