import { TIME_ZONE, formatDayShort } from '@/components/ui'
import { diaDeLaSemana } from '@/features/admin/semana'

// ═══════════════════════════════════════════════════════════════════════════
// Cómo se nombra una semana en una columna estrecha: «3–9 ago», «31 ago–6
// sep». El mes una vez si no cambia; los dos si la semana cruza de mes.
//
// Los días van como texto 'YYYY-MM-DD' y nunca pasan por `new Date(dia)`.
//
// Puro: se prueba en `etiquetas.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** «3–9 ago» o «31 ago–6 sep», del lunes al domingo. */
export function etiquetaDeSemana(lunes: string, domingo: string): string {
  const [diaLunes = '', mesLunes = ''] = formatDayShort(lunes).split(' ')
  const [diaDomingo = '', mesDomingo = ''] = formatDayShort(domingo).split(' ')
  return mesLunes === mesDomingo
    ? `${diaLunes}–${diaDomingo} ${mesDomingo}`
    : `${diaLunes} ${mesLunes}–${diaDomingo} ${mesDomingo}`
}

/** «del 14 sep al 17 sep»: los días con los que se compara una semana en curso. */
export function tramoDeDias(desde: string, hasta: string): string {
  return desde === hasta ? `el ${formatDayShort(desde)}` : `del ${formatDayShort(desde)} al ${formatDayShort(hasta)}`
}

/**
 * «sábado 19 sep a las 15:00»: un instante (`timestamptz`) con su día del
 * calendario y su hora en Caracas. Es el corte de la semana anterior cuando
 * la elegida está en curso: lo que había pasado hace exactamente siete días.
 * `null` si no se lee.
 */
export function momentoDeCaracas(instante: string): string | null {
  const t = Date.parse(instante)
  if (!Number.isFinite(t)) return null
  const fecha = new Date(t)
  // 'en-CA' escribe la fecha como 'YYYY-MM-DD'; la hora, en 24 h.
  const dia = new Intl.DateTimeFormat('en-CA', { timeZone: TIME_ZONE }).format(fecha)
  const hora = new Intl.DateTimeFormat('en-GB', {
    timeZone: TIME_ZONE,
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).format(fecha)
  return `${diaDeLaSemana(dia)} ${formatDayShort(dia)} a las ${hora}`
}

/**
 * Con qué se compara una semana en curso, en palabras: «del 14 sep al
 * sábado 19 sep a las 15:00» (hasta el mismo momento de la anterior). Sin
 * corte (una respuesta vieja de la base), los mismos días enteros.
 */
export function tramoHastaElCorte(desde: string, hasta: string, corte: string | null): string {
  const momento = corte ? momentoDeCaracas(corte) : null
  if (!momento) return tramoDeDias(desde, hasta)
  return `del ${formatDayShort(desde)} al ${momento}`
}
