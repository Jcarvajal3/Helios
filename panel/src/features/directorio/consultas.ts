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
