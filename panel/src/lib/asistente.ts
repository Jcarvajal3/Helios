/**
 * Si el asistente de IA del super admin está encendido en esta compilación.
 *
 * Su Edge Function `admin-asistente` existe desde el 2026-10-23 (fase 5 del
 * plan): contesta con Claude. Sin `VITE_ASISTENTE=1` al compilar (ver
 * `.env.example`; en Vercel está puesta) no se enseña —ni el cajón, ni Ctrl J,
 * ni la charla de Inicio, ni «Preguntar» en la paleta—.
 */
export function asistenteActivo(): boolean {
  return leerAsistente(import.meta.env.VITE_ASISTENTE)
}

/** Solo un `1` explícito lo enciende: cualquier otra cosa lo deja apagado. */
export function leerAsistente(valor: unknown): boolean {
  return typeof valor === 'string' && valor.trim() === '1'
}
