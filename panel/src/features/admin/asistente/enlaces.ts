import { CATALOGO } from '@/features/admin/catalogo'
import type { Enlace } from './protocolo'

// ═══════════════════════════════════════════════════════════════════════════
// Qué enlaces del asistente se pintan.
//
// El modelo propone la ruta, y una ruta que no existe sería un botón que lleva
// a «página no encontrada». Solo pasan las rutas del catálogo del panel (las
// mismas que lleva `mapa.json`) y las fichas de personas, locales, consumos y
// pagos reportados con un id bien formado. El `search` lo vuelve a validar la
// ruta de destino al navegar.
// ═══════════════════════════════════════════════════════════════════════════

/** Las rutas de las pantallas del catálogo: las fijas del super admin. */
const RUTAS_DEL_CATALOGO: ReadonlySet<string> = new Set(CATALOGO.map((e) => e.destino.to))

/** Las fichas: una ruta con el id (un uuid) de lo que enseñan. */
export const FICHAS = [
  { id: 'ficha-persona', titulo: 'Ficha de un paciente', ruta: '/admin/pacientes/$id' },
  { id: 'ficha-local', titulo: 'Ficha de una clínica', ruta: '/admin/clinicas/$id' },
  { id: 'ficha-consumo', titulo: 'Ficha de un financiamiento', ruta: '/admin/financiamientos/$id' },
  { id: 'ficha-pago', titulo: 'Ficha de un pago reportado', ruta: '/admin/cobros/$id' },
] as const

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
/** Cada ficha como patrón: su ruta con un uuid donde va `$id`. */
const PATRONES_DE_FICHA = FICHAS.map((f) => new RegExp(`^${f.ruta.replace('$id', UUID)}$`, 'i'))

/** Sin la barra final: `/admin/cobranza/` es `/admin/cobranza`. */
function sinBarraFinal(ruta: string): string {
  return ruta.length > 1 ? ruta.replace(/\/+$/, '') : ruta
}

/** Si la ruta existe en el panel. */
export function rutaConocida(ruta: string): boolean {
  const r = sinBarraFinal(ruta)
  return RUTAS_DEL_CATALOGO.has(r) || PATRONES_DE_FICHA.some((p) => p.test(r))
}

/**
 * El enlace listo para pintar, o `null` si su ruta no existe. Una ruta con
 * `?…` pegado se parte: el modelo a veces escribe la dirección entera en vez de
 * separar `search`.
 */
export function enlaceValido(e: Enlace): Enlace | null {
  const [crudo, consulta] = e.ruta.split('?', 2)
  const ruta = sinBarraFinal(crudo.trim())
  if (!rutaConocida(ruta)) return null

  const search = { ...e.search }
  if (consulta) {
    for (const [clave, valor] of new URLSearchParams(consulta)) {
      if (!(clave in search) && /^[A-Za-z][A-Za-z0-9_]{0,39}$/.test(clave)) search[clave] = valor
    }
  }
  return Object.keys(search).length > 0 ? { ...e, ruta, search } : { titulo: e.titulo, ruta }
}
