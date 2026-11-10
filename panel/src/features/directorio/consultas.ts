// ═══════════════════════════════════════════════════════════════════════════
// `/consultas` — la variante B de la prueba A/B del directorio (docs/06).
//
// Módulo puro: los textos de la página y de su tarjeta, con la inicial y el
// tope como constantes con nombre. La inicial es solo texto en esta página
// (Javier, 2026-11-09): el cobro no cambia. Por eso nada de lo de aquí dice
// «sin inicial», «0%» ni las fechas de las cuotas, y la página no enlaza a
// las guías que sí lo dicen.
// ═══════════════════════════════════════════════════════════════════════════

/** La inicial que anuncia `/consultas`, en dólares (`helios_consultas_inicial_usd()`). */
export const INICIAL_DE_CONSULTAS_USD = 15

/**
 * El precio máximo de consulta de los médicos de `/consultas`, en dólares
 * (`helios_consultas_tope_usd()`). Lo aplica la base
 * (`helios_directorio_consultas()`, con la tasa cruzada para los euros): la
 * página solo lo repite aquí para que el número tenga nombre.
 */
export const TOPE_DE_CONSULTAS_USD = 60

/**
 * El precio que enseña cada tarjeta de `/consultas`, el mismo para todos los
 * médicos (Javier, 2026-11-09): es texto de la prueba, no el precio de cada
 * uno. Los precios reales de la base no cambian y siguen decidiendo quién
 * entra (`TOPE_DE_CONSULTAS_USD`); `/directorio` enseña el de cada médico.
 */
export const PRECIO_DE_CONSULTAS_USD = 30

/** «$30»: la cifra de la tarjeta, detrás de «Consulta a partir de:». */
export const PRECIO_DE_CONSULTAS = `$${PRECIO_DE_CONSULTAS_USD}`

/**
 * Dónde atiende cada médico de `/consultas`, solo la zona (Javier,
 * 2026-11-09): sin edificio, piso ni consultorio. Sin zona en su dirección,
 * el edificio y «Caracas». Por el código de su tarjeta (`lead_code`), que no
 * cambia. Es solo la interfaz de B: la dirección entera sigue en la base y en
 * `/directorio`.
 */
export const ZONA_EN_CONSULTAS: Readonly<Record<string, string>> = {
  'DIR-5659': 'Los Dos Caminos', // Dra. Giorgina Scott
  'DIR-P6U6': 'San Bernardino', // Dra. Ana Lara
  'DIR-YGRY': 'Edificio Qvadra, Caracas', // Dr. Leonardo Veliz
  'DIR-ZQYW': 'Los Samanes', // Dra. Dilia Pereira
  'DIR-KDFW': 'San Bernardino', // Dr. Carlos Cuenca
  'DIR-WWV6': 'San Bernardino', // Dr. Jesús Vivas
  'DIR-DHC6': 'El Rosal', // Lcdo. Daniel Álvarez
  'DIR-Q3K5': 'Los Cortijos', // Dra. Ani Materan
  'DIR-WUB2': 'Sabana Grande', // Dra. Zuleidys Arellano (Av. Francisco Solano López)
  'DIR-UUVK': 'San Bernardino', // Dr. Jesus Stanley Velasquez
  'DIR-97H7': 'La Campiña', // Dra. Alejandra Vasquez
  'DIR-ENPB': 'Bello Monte', // Dr. Jesús Dale Páez
  'DIR-KKGM': 'Los Dos Caminos', // Dra. Cecil Palmero
  'DIR-QJY4': 'Sabana Grande', // Dra. Andreina Prieto
  'DIR-5D4K': 'San Bernardino', // Dra. Nadia Khabbaze
  'DIR-VE7A': 'Los Teques', // Dr. Ricardo Trinidad
  'DIR-PBHT': 'San Bernardino', // Dra. Andrea Betancourt
}

/**
 * La línea de dónde atiende en la tarjeta de `/consultas`: su zona
 * (`ZONA_EN_CONSULTAS`). Un médico que aún no está en la lista enseña solo
 * su ciudad, nunca la dirección entera; sin ciudad, nada.
 */
export function lugarEnConsultas(m: { codigo: string | null; ciudad: string | null }): string | null {
  const zona = m.codigo ? ZONA_EN_CONSULTAS[m.codigo.trim().toUpperCase()] : undefined
  return zona ?? (m.ciudad?.trim() || null)
}

/** «$15». */
const INICIAL = `$${INICIAL_DE_CONSULTAS_USD}`

/** La línea de cada tarjeta, debajo del precio. Sin cifra de las cuotas (docs/06). */
export const CONDICIONES_DE_CONSULTAS = `Inicial ${INICIAL} y el resto en 2 cuotas quincenales`

/** Los textos de `/consultas`. */
export const TEXTOS_DE_CONSULTAS = {
  titulo: `Consultas médicas por solo ${INICIAL} de inicial | Helios`,
  descripcion: `Elige a tu médico, escríbele por WhatsApp y paga tu consulta con ${INICIAL} de inicial y el resto en 2 cuotas quincenales.`,
  h1: { antes: '¡Consultas médicas por solo', enfasis: `${INICIAL} de inicial!` },
  entrada: 'Paga el resto en 2 cuotas quincenales. Escríbele a tu médico por WhatsApp y agenda tu consulta.',
  /** El sello de la tarjeta, junto al botón: «$15» «inicial» (en A, «0%» «inicial»). */
  sello: { cifra: INICIAL, texto: 'inicial' },
} as const

/**
 * Lo que no puede salir en `/consultas`: lo que contradice la inicial y el
 * vocabulario prohibido en lo público (CLAUDE.md, «Nombres»). Lo usan las
 * pruebas.
 */
export const PROHIBIDO_EN_CONSULTAS: readonly RegExp[] = [
  /sin inicial/i,
  /0\s*%/,
  /14 y 28/,
  /hoy no pagas/i,
  /pr[eé]stamo/i,
  /financ/i,
  /cr[eé]dito/i,
  /\bfee\b/i,
]
