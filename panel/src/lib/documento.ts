// ═══════════════════════════════════════════════════════════════════════════
// Cédulas, pasaportes y RIF en UN formato.
//
// El campo se parte en dos: la letra, de un selector (V, E, J, G, P), y el
// número, que solo admite dígitos (o letras y dígitos en un pasaporte). Así
// nadie escribe «12.345.678», otro «V-12345678» y otro «v 12345678»: el valor
// es siempre la letra pegada al número, `V12345678`, y la base lo guarda
// igual (`helios_documento`: la cédula `V12345678`, el RIF `J-123456789`).
//
// Módulo puro, probado en `documento.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export type LetraDocumento = 'V' | 'E' | 'J' | 'G' | 'P'

/** Una persona: cédula venezolana, de extranjero o pasaporte. */
export const LETRAS_CEDULA: ReadonlyArray<LetraDocumento> = ['V', 'E', 'P']
/** El RIF de una clínica o de un médico. */
export const LETRAS_RIF: ReadonlyArray<LetraDocumento> = ['J', 'G', 'V', 'E', 'P']
/** El titular de una cuenta: una persona o una empresa. */
export const LETRAS_TITULAR: ReadonlyArray<LetraDocumento> = ['V', 'E', 'J', 'G', 'P']

export const NOMBRE_LETRA: Record<LetraDocumento, string> = {
  V: 'Venezolano',
  E: 'Extranjero',
  J: 'Jurídico',
  G: 'Gobierno',
  P: 'Pasaporte',
}

/** Lo que admite el número de cada letra: dígitos, o letras y dígitos en un pasaporte. */
export function limpiarNumero(letra: LetraDocumento, texto: string): string {
  const v = texto.toUpperCase()
  return letra === 'P' ? v.replace(/[^A-Z0-9]/g, '').slice(0, 15) : v.replace(/\D/g, '').slice(0, 9)
}

/**
 * La letra y el número de un documento guardado o pegado: `V-12.345.678`,
 * `J-123456789`, `12345678` (sin letra: la primera de las permitidas) o un
 * pasaporte sin su P.
 */
export function partirDocumento(
  valor: string,
  letras: ReadonlyArray<LetraDocumento>,
): { letra: LetraDocumento; numero: string } {
  const limpio = valor.toUpperCase().replace(/[^A-Z0-9]/g, '')
  const primera = limpio.charAt(0) as LetraDocumento
  if (letras.includes(primera)) return { letra: primera, numero: limpiarNumero(primera, limpio.slice(1)) }
  if (/^\d*$/.test(limpio)) return { letra: letras[0], numero: limpiarNumero(letras[0], limpio) }
  if (letras.includes('P')) return { letra: 'P', numero: limpiarNumero('P', limpio) }
  return { letra: letras[0], numero: limpiarNumero(letras[0], limpio) }
}

/** La letra pegada al número: `V12345678`. Sin número, solo la letra (para no perderla). */
export function componerDocumento(letra: LetraDocumento, numero: string): string {
  return `${letra}${limpiarNumero(letra, numero)}`
}

/** Si el documento tiene número (un campo opcional con solo la letra está vacío). */
export function tieneNumero(valor: string, letras: ReadonlyArray<LetraDocumento>): boolean {
  return partirDocumento(valor, letras).numero !== ''
}

/** Si el documento vale: cédula 6-9 dígitos, RIF J/G 8-9, pasaporte 5-15. */
export function documentoValido(valor: string, letras: ReadonlyArray<LetraDocumento>): boolean {
  const { letra, numero } = partirDocumento(valor, letras)
  if (letra === 'P') return /^[A-Z0-9]{5,15}$/.test(numero)
  if (letra === 'J' || letra === 'G') return /^\d{8,9}$/.test(numero)
  return /^\d{6,9}$/.test(numero)
}

/** Si un RIF vale: cualquier letra con 8 o 9 dígitos. */
export function rifValido(valor: string): boolean {
  return /^\d{8,9}$/.test(partirDocumento(valor, LETRAS_RIF).numero)
}

/** Lo que se manda a la base: `V12345678`, o `''` si no hay número. */
export function documentoParaEnviar(valor: string, letras: ReadonlyArray<LetraDocumento>): string {
  const { letra, numero } = partirDocumento(valor, letras)
  return numero === '' ? '' : `${letra}${numero}`
}
