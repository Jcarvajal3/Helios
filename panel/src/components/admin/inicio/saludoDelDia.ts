// ═══════════════════════════════════════════════════════════════════════════
// El saludo de Inicio, sin React: la hora de Caracas decide si es mañana,
// tarde o noche. Puro para poder probarlo.
// ═══════════════════════════════════════════════════════════════════════════

export type MomentoDelDia = 'manana' | 'tarde' | 'noche'

/** Desde qué hora de Caracas empieza cada momento. Antes de las 5, sigue siendo noche. */
const EMPIEZA = { manana: 5, tarde: 12, noche: 19 }

const SALUDO: Record<MomentoDelDia, string> = {
  manana: 'Buenos días',
  tarde: 'Buenas tardes',
  noche: 'Buenas noches',
}

/** El momento del día de una hora de Caracas, de 0 a 23. */
export function momentoDelDia(hora: number): MomentoDelDia {
  if (hora >= EMPIEZA.noche || hora < EMPIEZA.manana) return 'noche'
  if (hora >= EMPIEZA.tarde) return 'tarde'
  return 'manana'
}

/**
 * «Buenas tardes, Javier», o solo «Buenas tardes» si la cuenta no tiene nombre
 * de pila: un saludo con el correo dentro es peor que uno sin nombre.
 */
export function saludo(hora: number, nombreDePila: string | null): string {
  const frase = SALUDO[momentoDelDia(hora)]
  const nombre = nombreDePila?.trim() ?? ''
  return nombre === '' ? frase : `${frase}, ${nombre}`
}
