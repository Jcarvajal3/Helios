/**
 * Lo que el asistente necesita de Supabase, y nada más.
 *
 * El cliente real se crea en `index.ts` con la clave anónima y el
 * `Authorization` de quien pregunta: cada RPC corre con SUS permisos y la
 * guarda `is_platform_admin()` de la base sigue mandando. Nunca `service_role`.
 * Las pruebas pasan uno de mentira con la misma forma.
 */

export type ErrorDeBase = { message: string; code?: string };

export type RespuestaDeBase = { data: unknown; error: ErrorDeBase | null };

export interface Base {
  /** El id de quien trae el token, o `null` si el token no vale. */
  usuario(): Promise<string | null>;
  rpc(nombre: string, args?: Record<string, unknown>): Promise<RespuestaDeBase>;
}
