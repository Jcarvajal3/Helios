/**
 * Contraseña provisional para una cuenta de panel nueva.
 *
 * El super admin la crea directamente (docs/00-BASES §2.9); generarla evita
 * que termine siendo "12345678" solo porque hay que escribir algo rápido en
 * medio de una llamada. Se muestra en claro una sola vez para copiarla y
 * pasársela a la persona por otro canal — el servidor nunca la devuelve
 * después de creada.
 */
export function generatePassword(length = 12): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
  const bytes = new Uint32Array(length)
  crypto.getRandomValues(bytes)
  return Array.from(bytes, (n) => alphabet[n % alphabet.length]).join('')
}
