/**
 * A qué base apunta este panel.
 *
 *   desarrollo  el proyecto de Supabase de dev: el menú lleva la pastilla DEV
 *   produccion  la base de verdad: no se pinta nada
 *   local       un Supabase en la propia máquina (`npx supabase start`)
 *
 * El mismo panel se compila contra las dos bases y nada las distinguía: una
 * prueba hecha creyendo estar en dev podía tocar a un cliente real. Lo dice
 * `VITE_ENTORNO` (ver `.env.example`), que se fija al compilar.
 */
export type Entorno = 'desarrollo' | 'produccion' | 'local'

const ENTORNOS: ReadonlyArray<Entorno> = ['desarrollo', 'produccion', 'local']

/**
 * Lee el valor de la variable. Sin ella, o con un valor que no se entiende, es
 * producción: es lo que pasa en Vercel, y ahí no se pinta ninguna pastilla.
 * Equivocarse hacia «producción» solo quita un aviso; hacia «desarrollo»
 * pondría DEV sobre la base de verdad.
 */
export function leerEntorno(valor: unknown): Entorno {
  if (typeof valor !== 'string') return 'produccion'
  const limpio = valor.trim().toLowerCase()
  return ENTORNOS.find((e) => e === limpio) ?? 'produccion'
}

/** El entorno de esta compilación. */
export function entorno(): Entorno {
  return leerEntorno(import.meta.env.VITE_ENTORNO)
}
