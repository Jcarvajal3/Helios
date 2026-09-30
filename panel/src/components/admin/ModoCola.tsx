import { useEffect, useMemo, useRef, useSyncExternalStore } from 'react'
import { ArrowLeft, ChevronLeft, ChevronRight } from 'lucide-react'

import { Button, Tecla } from '@/components/ui'
import { hayModalAbierto } from '@/components/overlays'

// ═══════════════════════════════════════════════════════════════════════════
// Recorrer una lista ficha a ficha, sin volver a la lista entre una y otra.
//
// Revisar doce pagos era: abrir el primero, aprobar, volver, buscar el
// segundo, abrirlo… Con esto la lista deja apuntado su orden al abrir una
// fila, y la ficha sabe cuál va antes y cuál después.
//
// Es genérico: no sabe de pagos ni de verificaciones. Lo único que guarda es
// una lista de ids con un nombre.
//
// ── En la LISTA ────────────────────────────────────────────────────────────
//
//   <DataTable
//     rows={filas}
//     onRowClick={(fila, filasVisibles) => {
//       // Los ids EN EL ORDEN QUE SE VEN: con el filtro y el orden de ahora.
//       abrirEnCola('pagos', filasVisibles.map((f) => f.reportId))
//       void navigate({ to: '/admin/cobros/$id', params: { id: fila.reportId } })
//     }}
//     …
//   />
//
// ── En la FICHA ────────────────────────────────────────────────────────────
//
//   const cola = useCola('pagos', id)
//   const ir = (otro: string) => void navigate({ to: '/admin/cobros/$id', params: { id: otro } })
//   const volver = () => void navigate({ to: '/admin/cobros' })
//
//   <BarraDeCola cola={cola} onIr={ir} onVolver={volver} rotulo="Pagos reportados" />
//
//   // Tras aprobar: al siguiente, o a la lista con un aviso si era el último.
//   onSuccess: () => {
//     if (cola.siguiente) ir(cola.siguiente)
//     else { avisar('Era el último de la lista'); volver() }
//   }
//
// Si la ficha se abrió por otro camino —un enlace, el buscador— su id no está
// en la cola, `total` es 0 y la barra no se pinta.
// ═══════════════════════════════════════════════════════════════════════════

const PREFIJO = 'helios-panel:cola:'

/** Avisa a las fichas abiertas de que una cola cambió (en esta pestaña). */
const EVENTO = 'helios-panel:cola'

/** Dónde está la ficha actual dentro de su cola. */
export type Cola = {
  /** De 1 a `total`. 0 si la ficha no está en la cola. */
  posicion: number
  /** Cuántas hay en la cola. 0 si la ficha no está en ella. */
  total: number
  anterior?: string
  siguiente?: string
}

/**
 * Apunta el orden de una lista para recorrerla desde las fichas.
 *
 * En `sessionStorage`: vale para esta pestaña y se olvida al cerrarla, que es
 * lo que dura una sesión de revisión. Si el navegador no deja guardar (modo
 * privado, almacenamiento lleno), simplemente no hay cola.
 */
export function abrirEnCola(nombre: string, ids: string[]): void {
  try {
    sessionStorage.setItem(PREFIJO + nombre, JSON.stringify(ids))
    window.dispatchEvent(new Event(EVENTO))
  } catch {
    // Sin almacenamiento no hay cola: la ficha se ve igual, sin la barra.
  }
}

function leerCrudo(nombre: string): string | null {
  try {
    return sessionStorage.getItem(PREFIJO + nombre)
  } catch {
    return null
  }
}

function suscribir(aviso: () => void): () => void {
  window.addEventListener(EVENTO, aviso)
  return () => window.removeEventListener(EVENTO, aviso)
}

/** Lo guardado, a una lista de ids. Cualquier cosa rara es una cola vacía. */
function parsear(crudo: string | null): string[] {
  if (!crudo) return []
  try {
    const valor: unknown = JSON.parse(crudo)
    return Array.isArray(valor) ? valor.filter((x): x is string => typeof x === 'string') : []
  } catch {
    return []
  }
}

/**
 * Si dos fichas están en una misma cola abierta: es lo que distingue «el
 * siguiente caso» (se sigue en la misma lista) de saltar a otra ficha de la
 * misma clase por un enlace (una cuenta relacionada).
 */
export function enLaMismaCola(a: string, b: string): boolean {
  try {
    for (let i = 0; i < sessionStorage.length; i++) {
      const clave = sessionStorage.key(i)
      if (!clave?.startsWith(PREFIJO)) continue
      const ids = parsear(sessionStorage.getItem(clave))
      if (ids.includes(a) && ids.includes(b)) return true
    }
  } catch {
    // Sin almacenamiento no hay colas.
  }
  return false
}

/** Dónde cae `idActual` en `ids`. Pura, para poder probarla. */
export function posicionEnCola(ids: ReadonlyArray<string>, idActual: string): Cola {
  const i = ids.indexOf(idActual)
  if (i < 0) return { posicion: 0, total: 0 }
  return {
    posicion: i + 1,
    total: ids.length,
    anterior: i > 0 ? ids[i - 1] : undefined,
    siguiente: i < ids.length - 1 ? ids[i + 1] : undefined,
  }
}

/**
 * La posición de esta ficha en la cola `nombre`.
 *
 * Se lee con `useSyncExternalStore` y no en un `useState`: en el servidor no
 * hay `sessionStorage` y la primera pintura tiene que coincidir; y si la
 * lista reescribe la cola con la ficha abierta, la barra se entera.
 */
export function useCola(nombre: string, idActual: string): Cola {
  const crudo = useSyncExternalStore(
    suscribir,
    () => leerCrudo(nombre),
    () => null,
  )
  return useMemo(() => posicionEnCola(parsear(crudo), idActual), [crudo, idActual])
}

// ── Atajos de una tecla ────────────────────────────────────────────────────

/** Mientras se escribe, una J es una J. */
function seEstaEscribiendo(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  return (
    target.isContentEditable ||
    target.tagName === 'INPUT' ||
    target.tagName === 'TEXTAREA' ||
    target.tagName === 'SELECT'
  )
}

/** Controles donde las flechas ya significan algo: moverse dentro de ellos. */
const USAN_FLECHAS = '[role="tablist"], [role="radiogroup"], [role="slider"], [role="listbox"], [role="menu"], [role="grid"]'

/** Lo que Enter y Espacio ya pulsan por su cuenta. */
const PULSABLES = 'a, button, summary, [role="button"], [role="link"], [tabindex]'

/**
 * Atajos de una tecla para la pantalla que los monta.
 *
 * useAtajos({ j: siguiente, ArrowRight: siguiente, k: anterior, ArrowLeft: anterior })
 *
 * Las letras van en minúscula y valen también con mayúscula; lo demás, con
 * el nombre de `KeyboardEvent.key` ('ArrowRight', 'Escape'). Se ignoran:
 *
 *   · mientras se escribe (input, textarea, select, contenteditable);
 *   · con una ventana (`Modal`) abierta encima;
 *   · con Ctrl, Cmd o Alt, que son del navegador o del buscador global;
 *   · si algo ya usó la tecla (`defaultPrevented`), como un gráfico que se
 *     recorre con las flechas, y las flechas dentro de pestañas o listas;
 *   · Enter y Espacio sobre un botón o enlace, que ya hacen lo suyo;
 *   · la tecla mantenida: una J apretada no recorre la cola entera.
 *
 * `activo` en `false` los apaga sin desmontar nada.
 */
export function useAtajos(mapa: Record<string, () => void>, activo = true): void {
  const mapaRef = useRef(mapa)

  useEffect(() => {
    mapaRef.current = mapa
  }, [mapa])

  useEffect(() => {
    if (!activo) return

    function alTeclear(event: KeyboardEvent) {
      if (event.defaultPrevented || event.repeat || event.isComposing) return
      if (event.ctrlKey || event.metaKey || event.altKey) return
      if (hayModalAbierto() || seEstaEscribiendo(event.target)) return

      const tecla = event.key.length === 1 ? event.key.toLowerCase() : event.key
      if (!Object.hasOwn(mapaRef.current, tecla)) return
      const accion = mapaRef.current[tecla]

      const donde = event.target instanceof Element ? event.target : null
      if (tecla.startsWith('Arrow') && donde?.closest(USAN_FLECHAS)) return
      if ((tecla === 'Enter' || tecla === ' ') && donde?.closest(PULSABLES)) return

      event.preventDefault()
      accion()
    }

    document.addEventListener('keydown', alTeclear)
    return () => document.removeEventListener('keydown', alTeclear)
  }, [activo])
}

// ── La barra ───────────────────────────────────────────────────────────────

/**
 * «3 de 12», con anterior y siguiente, para lo alto de una ficha.
 *
 * Teclas: J o → para la siguiente, K o ← para la anterior (ver `useAtajos`).
 * Si la ficha no está en la cola no pinta nada.
 */
export function BarraDeCola({
  cola,
  onIr,
  onVolver,
  rotulo,
}: {
  cola: Cola
  onIr: (id: string) => void
  onVolver: () => void
  /** El nombre de la lista a la que se vuelve: «Pagos reportados». */
  rotulo: string
}) {
  const { anterior, siguiente } = cola

  function irAnterior() {
    if (anterior) onIr(anterior)
  }
  function irSiguiente() {
    if (siguiente) onIr(siguiente)
  }

  useAtajos(
    { j: irSiguiente, ArrowRight: irSiguiente, k: irAnterior, ArrowLeft: irAnterior },
    cola.total > 0,
  )

  if (cola.total === 0) return null

  return (
    <nav
      aria-label={`Recorrer ${rotulo}`}
      className="mb-4 flex flex-wrap items-center justify-between gap-x-4 gap-y-2"
    >
      <button
        type="button"
        onClick={onVolver}
        className="inline-flex items-center gap-1 type-panel-control text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:text-on-surface"
      >
        <ArrowLeft size={14} aria-hidden /> {rotulo}
      </button>

      <div className="flex items-center gap-2">
        <p aria-live="polite" className="type-panel-body tabular-nums text-on-surface-variant">
          <span className="text-on-surface">{cola.posicion}</span> de {cola.total}
        </p>
        <Button size="sm" variant="tonal" disabled={!anterior} onClick={irAnterior}>
          <ChevronLeft size={15} aria-hidden />
          Anterior
          <Tecla enBoton>K</Tecla>
        </Button>
        <Button size="sm" variant="tonal" disabled={!siguiente} onClick={irSiguiente}>
          Siguiente
          <Tecla enBoton>J</Tecla>
          <ChevronRight size={15} aria-hidden />
        </Button>
      </div>
    </nav>
  )
}
