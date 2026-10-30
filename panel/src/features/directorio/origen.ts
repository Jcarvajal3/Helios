// ═══════════════════════════════════════════════════════════════════════════
// De dónde llegó la visita — para saber qué buscador (o red) trae pacientes.
//
// La primera página que abre alguien en una pestaña es su «entrada»: se
// apunta con el dominio que la mandó (`document.referrer`) y las `utm_*` de
// la URL. Cuando toca el botón de WhatsApp de un médico, ese origen va con el
// clic (`helios_directorio_contacto`, migración 20261030120000) junto con la
// página donde lo tocó.
//
// Nada de la persona: ni IP, ni navegador, ni la URL completa de donde vino
// (solo el dominio). Sin almacenamiento (modo privado), el clic va sin
// origen y cuenta igual.
// ═══════════════════════════════════════════════════════════════════════════

const CLAVE = 'helios.llegada'

export type Llegada = {
  /** «google», «chatgpt», «instagram», «directo»… (`fuenteDeLaVisita`). */
  fuente: string
  /** El dominio que la mandó, sin «www.»; `null` si no hubo. */
  dominio: string | null
  /** La primera página de la visita, sin la búsqueda: «/directorio/odontologia». */
  entrada: string
  utm_source: string | null
  utm_medium: string | null
  utm_campaign: string | null
}

/**
 * Los dominios que se reconocen, del más concreto al más general: Gemini
 * antes que Google, Copilot antes que Bing. Lo que no está aquí es «otro».
 */
const DOMINIOS: Array<[RegExp, string]> = [
  [/(^|\.)chatgpt\.com$|(^|\.)openai\.com$/, 'chatgpt'],
  [/(^|\.)perplexity\.ai$/, 'perplexity'],
  [/(^|\.)gemini\.google\.com$/, 'gemini'],
  [/(^|\.)copilot\.microsoft\.com$/, 'copilot'],
  [/(^|\.)google\.[a-z.]+$/, 'google'],
  [/(^|\.)bing\.com$/, 'bing'],
  [/(^|\.)duckduckgo\.com$/, 'duckduckgo'],
  [/(^|\.)yahoo\.[a-z.]+$/, 'yahoo'],
  [/(^|\.)instagram\.com$/, 'instagram'],
  [/(^|\.)facebook\.com$|(^|\.)fb\.me$/, 'facebook'],
  [/(^|\.)whatsapp\.com$|^wa\.me$/, 'whatsapp'],
  [/(^|\.)tiktok\.com$/, 'tiktok'],
  [/(^|\.)x\.com$|(^|\.)twitter\.com$|^t\.co$/, 'x'],
  [/(^|\.)linkedin\.com$|^lnkd\.in$/, 'linkedin'],
  [/(^|\.)conhelios\.com$|^localhost$/, 'interno'],
]

/** Los asistentes con IA marcan sus enlaces con `utm_source` (ChatGPT: «chatgpt.com»). */
const UTM_CONOCIDAS: Array<[RegExp, string]> = [
  [/chatgpt|openai/, 'chatgpt'],
  [/perplexity/, 'perplexity'],
  [/copilot/, 'copilot'],
  [/gemini/, 'gemini'],
]

/**
 * La fuente de una visita. Manda la `utm_source` (la pone quien enlaza a
 * propósito: una campaña, ChatGPT); sin ella, el dominio que la mandó; sin
 * ninguno, «directo» (escrita a mano, un enlace desde una app, WhatsApp…).
 */
export function fuenteDeLaVisita(dominio: string | null, utmSource: string | null): string {
  const utm = utmSource?.trim().toLowerCase() ?? ''
  if (utm) {
    const conocida = UTM_CONOCIDAS.find(([re]) => re.test(utm))?.[1]
    if (conocida) return conocida
    const limpia = utm.replace(/[^a-z0-9.-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40)
    if (limpia) return limpia
  }
  if (!dominio) return 'directo'
  return DOMINIOS.find(([re]) => re.test(dominio))?.[1] ?? 'otro'
}

/** «https://www.google.com/search?q=…» → «google.com». `null` si no hay o no se lee. */
export function dominioDe(referrer: string): string | null {
  if (!referrer) return null
  try {
    const host = new URL(referrer).hostname.toLowerCase().replace(/^www\./, '')
    return /^[a-z0-9.-]{1,100}$/.test(host) ? host : null
  } catch {
    return null
  }
}

/** Arma la llegada a partir de la URL de entrada y el `referrer`. Pura: la usan las pruebas. */
export function leerLlegada(url: URL, referrer: string): Llegada {
  const param = (k: string) => url.searchParams.get(k)?.trim().slice(0, 100) || null
  const dominio = dominioDe(referrer)
  const utm_source = param('utm_source')
  return {
    fuente: fuenteDeLaVisita(dominio, utm_source),
    dominio,
    entrada: url.pathname.slice(0, 200),
    utm_source,
    utm_medium: param('utm_medium'),
    utm_campaign: param('utm_campaign'),
  }
}

/**
 * Apunta la llegada si es la primera página de la pestaña. Se llama al
 * cargar cualquier página pública; las siguientes no la pisan. Una visita
 * que llega desde otra página de Helios (`interno`) tampoco: es la misma.
 */
export function apuntarLlegada(): void {
  try {
    if (window.sessionStorage.getItem(CLAVE)) return
    const llegada = leerLlegada(new URL(window.location.href), document.referrer)
    if (llegada.fuente === 'interno') return
    window.sessionStorage.setItem(CLAVE, JSON.stringify(llegada))
  } catch {
    // Sin almacenamiento: el clic irá sin origen.
  }
}

/** El origen que acompaña al clic: la llegada y la página donde se tocó el botón. */
export function origenDelClic(): Record<string, string | null> | null {
  try {
    const guardada = window.sessionStorage.getItem(CLAVE)
    const llegada = guardada
      ? (JSON.parse(guardada) as Llegada)
      : leerLlegada(new URL(window.location.href), document.referrer)
    return { ...llegada, pagina: window.location.pathname.slice(0, 200) }
  } catch {
    return null
  }
}
