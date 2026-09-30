import { comoId, comoTexto } from '@/lib/busqueda'

// ═══════════════════════════════════════════════════════════════════════════
// Lo último que se abrió desde la paleta: lo que sale al abrirla sin texto.
//
// Vive en `localStorage` porque es de esta persona en este navegador, como
// los grupos plegados del menú. Lo que se lee de ahí se valida entero: una versión
// vieja del panel, o alguien tocando a mano, no puede tumbar la paleta.
// ═══════════════════════════════════════════════════════════════════════════

/** Lo que se abre con una ficha propia. */
export type ClaseEntidad = 'persona' | 'local' | 'consumo' | 'pago'

/**
 * Una entrada de Recientes.
 *
 * Del catálogo se guarda solo el id y se busca al leer: si la pantalla cambia
 * de nombre, Recientes dice el nombre nuevo, y si desaparece, se cae de la
 * lista. De una ficha se guarda cómo se llamaba al abrirla, porque volver a
 * pedirla al servidor solo para pintar Recientes no compensa.
 */
export type Reciente =
  | { tipo: 'catalogo'; id: string }
  | { tipo: ClaseEntidad; id: string; titulo: string; detalle: string }

export const MAX_RECIENTES = 8

const CLAVE = 'helios-panel:paleta-recientes'

const CLASES: ReadonlyArray<ClaseEntidad> = ['persona', 'local', 'consumo', 'pago']

function esClase(v: unknown): v is ClaseEntidad {
  return CLASES.some((c) => c === v)
}

export function claveDeReciente(r: Reciente): string {
  return `${r.tipo}:${r.id}`
}

/** La lista con `nuevo` delante, sin repetirlo y sin pasar de `max`. */
export function anadirReciente(
  lista: ReadonlyArray<Reciente>,
  nuevo: Reciente,
  max = MAX_RECIENTES,
): Reciente[] {
  const clave = claveDeReciente(nuevo)
  return [nuevo, ...lista.filter((r) => claveDeReciente(r) !== clave)].slice(0, max)
}

/** Un valor cualquiera, leído como Reciente; `null` si no lo es. */
function comoReciente(v: unknown): Reciente | null {
  if (typeof v !== 'object' || v === null) return null
  const tipo = 'tipo' in v ? v.tipo : undefined
  const id = 'id' in v ? v.id : undefined

  if (tipo === 'catalogo') {
    const limpio = comoTexto(id, 80)
    return limpio ? { tipo, id: limpio } : null
  }
  if (!esClase(tipo)) return null

  const uuid = comoId(id)
  const titulo = comoTexto('titulo' in v ? v.titulo : undefined, 160)
  const detalle = comoTexto('detalle' in v ? v.detalle : undefined, 240) ?? ''
  if (!uuid || !titulo) return null
  return { tipo, id: uuid, titulo, detalle }
}

/** Lo guardado, limpio: solo entradas válidas, sin repetir y como mucho ocho. */
export function leerRecientes(valor: unknown): Reciente[] {
  if (!Array.isArray(valor)) return []
  const salida: Reciente[] = []
  for (const v of valor) {
    const r = comoReciente(v)
    if (!r || salida.some((o) => claveDeReciente(o) === claveDeReciente(r))) continue
    salida.push(r)
    if (salida.length === MAX_RECIENTES) break
  }
  return salida
}

export function cargarRecientes(): Reciente[] {
  try {
    const crudo = window.localStorage.getItem(CLAVE)
    return crudo === null ? [] : leerRecientes(JSON.parse(crudo))
  } catch {
    // Modo privado, almacenamiento bloqueado o un JSON roto: sin Recientes.
    return []
  }
}

export function guardarRecientes(lista: ReadonlyArray<Reciente>): void {
  try {
    window.localStorage.setItem(CLAVE, JSON.stringify(lista))
  } catch {
    // Se pierde al recargar y no pasa nada: la paleta sigue buscando.
  }
}
