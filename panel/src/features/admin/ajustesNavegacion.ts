import { TEMAS_BITACORA } from '@/features/admin/bitacoraAcciones'
import { comoDia, comoEntero, comoId, unoDe } from '@/lib/busqueda'

// ═══════════════════════════════════════════════════════════════════════════
// Las secciones de Ajustes y lo que cada una guarda en la URL.
//
// Puro, sin React ni Supabase: la ruta lo usa para validar la búsqueda y la
// bitácora para enlazar con la sección que cambió una acción, y las pruebas lo
// leen en Node.
// ═══════════════════════════════════════════════════════════════════════════

export type PestanaAjustes =
  | 'tasa'
  | 'parametros'
  | 'niveles'
  | 'feriados'
  | 'cobro'
  | 'terminos'
  | 'equipo'
  | 'seguridad'
  | 'bitacora'
  | 'mantenimiento'

export type GrupoAjustes = {
  titulo: string
  /** El rótulo del grupo de emergencia va en rojo y aparte: es el que no se
   *  toca nunca, hasta la noche en que hay que tocarlo, y esa noche tiene que
   *  saltar a la vista. Sus ítems se pintan como los demás. */
  tono?: 'error'
  secciones: ReadonlyArray<{ value: PestanaAjustes; label: string }>
}

/**
 * Las secciones en grupos, por la clase de cosa que son: las reglas que usa
 * el sistema, las condiciones del comprobante, quién entra al panel, lo que
 * queda escrito y el freno de emergencia.
 */
export const GRUPOS_AJUSTES: ReadonlyArray<GrupoAjustes> = [
  {
    titulo: 'Reglas',
    secciones: [
      { value: 'tasa', label: 'Tasa BCV' },
      { value: 'parametros', label: 'Parámetros' },
      // Fue pantalla propia de Riesgo y vuelve aquí: el cupo de cada nivel es
      // una regla del crédito que se toca pocas veces, como los parámetros.
      { value: 'niveles', label: 'Niveles y cupos' },
      { value: 'feriados', label: 'Feriados' },
      { value: 'cobro', label: 'Cuenta de cobro' },
    ],
  },
  {
    // «Términos» en Ronda; en Helios son las condiciones que viajan dentro
    // del comprobante que recibe el paciente por correo (plan H9).
    titulo: 'El comprobante',
    secciones: [{ value: 'terminos', label: 'Condiciones' }],
  },
  {
    titulo: 'Equipo',
    secciones: [
      { value: 'equipo', label: 'Equipo' },
      { value: 'seguridad', label: 'Seguridad' },
    ],
  },
  {
    titulo: 'Registro',
    secciones: [{ value: 'bitacora', label: 'Bitácora' }],
  },
  {
    titulo: 'Emergencia',
    tono: 'error',
    secciones: [{ value: 'mantenimiento', label: 'Mantenimiento' }],
  },
]

export const PESTANAS_AJUSTES: ReadonlyArray<PestanaAjustes> = GRUPOS_AJUSTES.flatMap((g) =>
  g.secciones.map((s) => s.value),
)

/**
 * La sección que se pinta. Si no viene ninguna se ve la tasa: es la única
 * que puede parar el día.
 */
export function pestanaActiva(tab: PestanaAjustes | undefined): PestanaAjustes {
  return PESTANAS_AJUSTES.find((p) => p === tab) ?? 'tasa'
}

/** El rótulo de una sección, como sale en el menú de Ajustes. */
export function rotuloDePestana(pestana: PestanaAjustes): string {
  for (const grupo of GRUPOS_AJUSTES) {
    const seccion = grupo.secciones.find((s) => s.value === pestana)
    if (seccion) return seccion.label
  }
  return pestana
}

/** Las tablas anchas; los formularios se leen mejor estrechos. */
export const PESTANAS_ANCHAS: ReadonlyArray<PestanaAjustes> = ['bitacora', 'parametros']

/**
 * Lo que Ajustes guarda en la URL.
 *
 * Cada clave es de UNA sección y los nombres no se repiten entre secciones:
 * al cambiar de sección la búsqueda se queda solo con `tab` y lo demás se
 * pierde, que es lo correcto.
 */
export type AjustesSearch = {
  tab?: PestanaAjustes
  // Bitácora
  tema?: string
  quien?: string
  desde?: string
  hasta?: string
  /** Desde 1. La primera página no se escribe. */
  pagina?: number
  // Feriados
  anio?: number
}

/** El `validateSearch` de Ajustes: cada valor, validado o fuera. */
export function leerBusquedaAjustes(s: Record<string, unknown>): AjustesSearch {
  return {
    tab: unoDe(PESTANAS_AJUSTES, s.tab),
    tema: unoDe(TEMAS_BITACORA, s.tema),
    quien: comoId(s.quien),
    desde: comoDia(s.desde),
    hasta: comoDia(s.hasta),
    // La página 1 es la que se ve sin nada: `?pagina=1` sería una URL
    // distinta para la misma vista.
    pagina: comoEntero(s.pagina, { min: 2, max: 100_000 }),
    anio: comoEntero(s.anio, { min: 2020, max: 2100 }),
  }
}
