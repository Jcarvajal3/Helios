/**
 * Si el asistente de IA del super admin está encendido en esta compilación.
 *
 * En Helios el asistente llega en la fase 5 (plan §11): hasta que exista su
 * Edge Function `admin-asistente`, el código se queda pero no se enseña —ni
 * el cajón, ni Ctrl J, ni la charla de Inicio, ni «Preguntar» en la paleta—.
 * Se enciende con `VITE_ASISTENTE=1` al compilar (ver `.env.example`).
 */
export function asistenteActivo(): boolean {
  return leerAsistente(import.meta.env.VITE_ASISTENTE)
}

/** Solo un `1` explícito lo enciende: cualquier otra cosa lo deja apagado. */
export function leerAsistente(valor: unknown): boolean {
  return typeof valor === 'string' && valor.trim() === '1'
}
