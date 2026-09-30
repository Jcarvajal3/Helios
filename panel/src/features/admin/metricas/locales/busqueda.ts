// ═══════════════════════════════════════════════════════════════════════════
// ESQUELETO de MARCO. Dueño: LOCALES (ola 1), que lo rellena.
//
// Las claves propias de la pestaña Locales en la URL de `/admin/metricas`.
// Nunca `vista`, `semana` ni `local`: son del marco. El marco solo llama a
// `validarLocales` cuando Locales es la pestaña activa, así que otra pestaña
// puede usar la misma palabra sin chocar.
//
// Cada clave pasa validada o no pasa (`@/lib/busqueda`): `undefined` es «como
// si no viniera» y la pestaña usa su valor por defecto.
// ═══════════════════════════════════════════════════════════════════════════

export type BusquedaLocales = Record<never, never>

export function validarLocales(_raw: Record<string, unknown>): BusquedaLocales {
  return {}
}
