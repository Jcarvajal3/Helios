import { comoFila } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// De dónde se abrió cada ficha, para que «volver» lleve allí.
//
// Una ficha (una persona, un local, un consumo, un pago) se abre desde muchas
// listas: Por cobrar › Morosos, Personas, una alerta, el buscador, otra ficha.
// Su «volver» llevaba siempre a la misma lista fija, y quien venía de Morosos
// acababa en Personas sin sus filtros: perdía el hilo. Ahora el panel apunta,
// al entrar en una ficha, la pantalla exacta de la que venía (su dirección
// con filtros y pestaña, su nombre y su sitio en el historial) y «volver» lleva
// ahí. Sin nada apuntado, la ficha usa su lista fija de siempre.
//
// Puro salvo el guardado, que va en `sessionStorage`: vale para esta pestaña
// del navegador y se olvida al cerrarla, como las colas del modo cola.
// ═══════════════════════════════════════════════════════════════════════════

export type Origen = {
  /** La dirección entera de la pantalla de origen: ruta, filtros y pestaña. */
  href: string
  /** Cómo se llama: «Por cobrar › Morosos», «Javier Carvajal › Consumos». */
  titulo: string
  /** Su posición en el historial del navegador, si se sabe. */
  indice: number | null
}

/** Las fichas del super admin, por su ruta. El grupo es la clase de ficha. */
const FICHA = /^\/admin\/(pacientes|clinicas|financiamientos|cobros|pagos-clinicas\/pago|pagos-clinicas)\/([^/]+)$/

/** Qué clase de ficha es una ruta y de qué id, o `null` si no es una ficha. */
export function fichaDe(pathname: string): { clase: string; id: string } | null {
  const m = FICHA.exec(pathname)
  if (!m?.[1] || !m[2]) return null
  return { clase: m[1], id: decodeURIComponent(m[2]) }
}

export type Paso = { pathname: string; href: string; indice: number | null }

/**
 * Qué origen le toca a la ficha a la que se va. `undefined` es «no cambiar
 * nada»: no se entra en una ficha, o se cambia de pestaña dentro de ella.
 *
 *   · De una ficha a otra de la misma clase que está en la misma cola (el
 *     siguiente caso con J): hereda el origen, porque se sigue en la misma
 *     lista. Si no están en la misma cola (una cuenta relacionada), su
 *     origen es la ficha de la que se viene.
 *   · De vuelta a la ficha de la que se vino por un enlace (el «volver» de
 *     un consumo abierto desde una persona): se deja el origen que tenía.
 *   · Cualquier otro caso: el origen es la pantalla de la que se viene.
 */
export function origenAlEntrar(
  desde: Paso | undefined,
  hacia: Paso,
  origenes: Readonly<Partial<Record<string, Origen>>>,
  titulo: string,
  enLaMismaCola: (a: string, b: string) => boolean,
): Origen | null | undefined {
  const fichaHacia = fichaDe(hacia.pathname)
  if (!fichaHacia || !desde || desde.pathname === hacia.pathname) return undefined

  const fichaDesde = fichaDe(desde.pathname)
  const origenDesde = origenes[desde.pathname]

  if (fichaDesde && fichaDesde.clase === fichaHacia.clase && enLaMismaCola(fichaDesde.id, fichaHacia.id)) {
    return origenDesde ?? null
  }
  if (fichaDesde && origenDesde && rutaDe(origenDesde.href) === hacia.pathname) return undefined

  return { href: desde.href, titulo, indice: desde.indice }
}

/** La ruta de una dirección, sin búsqueda ni ancla. */
export function rutaDe(href: string): string {
  return href.split(/[?#]/)[0] ?? href
}

/**
 * Cuántos pasos hay que dar hacia atrás en el historial para llegar al
 * origen, o `null` si no se puede ir por el historial y hay que navegar a su
 * dirección. Ir hacia atrás devuelve la lista tal como se dejó, con su scroll.
 */
export function pasosHaciaAtras(origen: Origen, indiceActual: number | null): number | null {
  if (origen.indice === null || indiceActual === null) return null
  const pasos = indiceActual - origen.indice
  return pasos > 0 ? pasos : null
}

/** El índice del historial de TanStack que va en el estado de cada entrada. */
export function indiceDe(state: unknown): number | null {
  const i = comoFila(state).__TSR_index
  return typeof i === 'number' && Number.isInteger(i) ? i : null
}

// ── Guardado ───────────────────────────────────────────────────────────────

const CLAVE = 'helios-panel:origen-de-ficha'
/** Las fichas que se recuerdan a la vez; la más vieja se olvida. */
const TOPE = 40
const EVENTO = 'helios-panel:origen-de-ficha'

export function leerOrigenes(): Partial<Record<string, Origen>> {
  try {
    const crudo = sessionStorage.getItem(CLAVE)
    if (!crudo) return {}
    const todo = comoFila(JSON.parse(crudo))
    const salida: Partial<Record<string, Origen>> = {}
    for (const [ruta, valor] of Object.entries(todo)) {
      const o = comoFila(valor)
      if (typeof o.href === 'string' && typeof o.titulo === 'string') {
        salida[ruta] = { href: o.href, titulo: o.titulo, indice: typeof o.indice === 'number' ? o.indice : null }
      }
    }
    return salida
  } catch {
    return {}
  }
}

/** Apunta (o quita, con `null`) el origen de una ficha. */
export function guardarOrigen(pathname: string, origen: Origen | null): void {
  try {
    const todos = leerOrigenes()
    delete todos[pathname]
    if (origen) todos[pathname] = origen
    const claves = Object.keys(todos)
    for (const vieja of claves.slice(0, Math.max(0, claves.length - TOPE))) delete todos[vieja]
    sessionStorage.setItem(CLAVE, JSON.stringify(todos))
    window.dispatchEvent(new Event(EVENTO))
  } catch {
    // Sin almacenamiento, cada ficha vuelve a su lista fija.
  }
}

export function suscribirOrigenes(aviso: () => void): () => void {
  window.addEventListener(EVENTO, aviso)
  return () => window.removeEventListener(EVENTO, aviso)
}

/** El origen apuntado para una ruta, crudo, para `useSyncExternalStore`. */
export function leerOrigenCrudo(pathname: string): string | null {
  const o = leerOrigenes()[pathname]
  return o ? JSON.stringify(o) : null
}
