import { useEffect, useId, useRef, useState } from 'react'
import type { ReactNode, RefObject } from 'react'
import { X } from 'lucide-react'

import { Button, Card, ErrorBox, Input } from '@/components/ui'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que se abre encima de lo demás:
//
//   Modal          una ventana centrada. Es lo que reemplaza a los formularios
//                  colgados al final de una lista.
//   ConfirmDialog  el resumen de lo que va a pasar antes de que pase. Según el
//                  riesgo, pide además el motivo, o el motivo y una palabra.
//
// Viven aquí y no en ui.tsx porque ui.tsx es el kit de átomos —botones,
// tarjetas, tablas— y esto son composiciones que se montan encima. `ui.tsx`
// las reexporta, así que todo el panel las importa del mismo sitio.
//
// Lo que flota junto a un disparador —el tooltip, el menú «⋯», el periodo—
// no es una ventana: vive en `kit/`, sobre `kit/flotante.tsx`. Se cierra con
// Escape antes que la ventana que lo contiene, y Tab dentro de ello es suyo.
// ═══════════════════════════════════════════════════════════════════════════

// ── La pila de ventanas ───────────────────────────────────────────────────

/**
 * Las ventanas abiertas, de abajo arriba.
 *
 * Cada `Modal` escuchaba Escape por su cuenta, así que con un diálogo de
 * confirmación abierto encima de un formulario, Escape cerraba los dos y se
 * perdía lo escrito. Ahora hay UN oyente para todos y solo actúa sobre la de
 * arriba.
 */
type Ventana = {
  caja: RefObject<HTMLDivElement | null>
  cerrar: RefObject<() => void>
}

const pila: Array<Ventana> = []

/**
 * Si hay alguna ventana abierta. Lo usan los atajos de teclado de una
 * pantalla (`useAtajos`): con una ventana encima, una J no es «siguiente».
 */
export function hayModalAbierto(): boolean {
  return pila.length > 0
}

/**
 * Mete una ventana en la pila, por debajo de las que lleva dentro.
 *
 * Normalmente la nueva va arriba. Pero si una ventana y un diálogo que vive
 * dentro de ella se montan a la vez, React corre primero el efecto del hijo,
 * y la de fuera acabaría encima de la de dentro. Las ventanas no usan portal,
 * así que la de dentro está dentro también en el DOM.
 */
function apilar(ventana: Ventana) {
  const nueva = ventana.caja.current
  const i = nueva
    ? pila.findIndex((otra) => otra.caja.current !== null && nueva.contains(otra.caja.current))
    : -1
  if (i < 0) pila.push(ventana)
  else pila.splice(i, 0, ventana)
}

const ENFOCABLES = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  'summary',
  '[tabindex]:not([tabindex="-1"])',
  '[contenteditable="true"]',
].join(',')

/** Lo que recibe el foco con Tab, en orden y sin lo que no se ve. */
function enfocables(dentro: HTMLElement): Array<HTMLElement> {
  return Array.from(dentro.querySelectorAll<HTMLElement>(ENFOCABLES)).filter(
    (el) => el.getClientRects().length > 0,
  )
}

function alTeclear(event: KeyboardEvent) {
  const arriba = pila.at(-1)
  const caja = arriba?.caja.current
  if (!arriba || !caja) return

  if (event.key === 'Escape') {
    // Si algo de dentro ya lo usó —un desplegable que se cierra—, no es para
    // la ventana.
    if (event.defaultPrevented) return
    event.preventDefault()
    arriba.cerrar.current()
    return
  }

  if (event.key !== 'Tab') return

  // Lo que flota (un menú, el periodo) va en un portal fuera de la ventana,
  // pero es parte de ella: dentro de eso, Tab es suyo.
  const enfocado = document.activeElement
  if (enfocado instanceof Element && enfocado.closest('[data-flotante]')) return

  // El foco no sale de la ventana: del último vuelve al primero y al revés.
  const lista = enfocables(caja)
  const activo = document.activeElement
  const primero = lista.at(0)
  const ultimo = lista.at(-1)

  if (!primero || !ultimo) {
    event.preventDefault()
    caja.focus()
    return
  }

  const fuera = !(activo instanceof Node) || !caja.contains(activo) || activo === caja
  if (fuera) {
    event.preventDefault()
    const destino = event.shiftKey ? ultimo : primero
    destino.focus()
  } else if (event.shiftKey && activo === primero) {
    event.preventDefault()
    ultimo.focus()
  } else if (!event.shiftKey && activo === ultimo) {
    event.preventDefault()
    primero.focus()
  }
}

let overflowPrevio = ''

/**
 * Sin desplazar la página de detrás mientras haya una ventana. Se bloquea en
 * `html` y no en `body` porque es `html` el que reserva el hueco de la barra
 * (`scrollbar-gutter: stable` en styles.css): así el contenido no salta de
 * lado al abrir.
 */
function alAbrirLaPrimera() {
  overflowPrevio = document.documentElement.style.overflow
  document.documentElement.style.overflow = 'hidden'
  document.addEventListener('keydown', alTeclear)
}

function alCerrarLaUltima() {
  document.documentElement.style.overflow = overflowPrevio
  document.removeEventListener('keydown', alTeclear)
}

/**
 * El foco al abrir: lo que diga `data-autofocus` si algo lo lleva; si no, el
 * primer control del contenido; si no hay, la equis; y si no, la ventana.
 *
 * El contenido va antes que la equis a propósito: en un formulario lo que se
 * quiere es escribir, no cerrar. Si un campo ya se enfocó solo (`autoFocus`),
 * se respeta.
 */
function enfocarAlAbrir(caja: HTMLDivElement, cuerpo: HTMLDivElement | null) {
  const activo = document.activeElement
  if (activo instanceof Node && caja.contains(activo)) return

  const destino =
    caja.querySelector<HTMLElement>('[data-autofocus]') ??
    (cuerpo ? enfocables(cuerpo).at(0) : undefined) ??
    enfocables(caja).at(0) ??
    caja
  destino.focus()
}

// ── Modal ─────────────────────────────────────────────────────────────────

/**
 * Ventana centrada.
 *
 * El alta de un comercio vivía al final de la lista: con veinte locales había
 * que bajar toda la página para encontrarla. Un formulario que se abre no
 * depende de cuánto haya crecido la lista de al lado.
 *
 * Se apilan: Escape cierra solo la de arriba, Tab no sale de ella, la página
 * de detrás no se desplaza, y al cerrar el foco vuelve a donde estaba —el
 * botón que la abrió—. Para elegir qué control recibe el foco al abrir, se le
 * pone `data-autofocus`.
 */
export function Modal({
  title,
  onClose,
  children,
  width = 'md',
  sinEncabezado = false,
}: {
  /** El título visible y, siempre, el nombre de la ventana para el lector de pantalla. */
  title: string
  onClose: () => void
  children: ReactNode
  width?: 'sm' | 'md' | 'lg'
  /**
   * Sin el título ni la equis, para una ventana cuyo contenido ya dice qué es
   * (la paleta empieza por su buscador). El `title` sigue nombrando la ventana
   * para el lector de pantalla, y se cierra con Escape o pulsando fuera.
   */
  sinEncabezado?: boolean
}) {
  const cajaRef = useRef<HTMLDivElement>(null)
  const cuerpoRef = useRef<HTMLDivElement>(null)
  const cerrarRef = useRef(onClose)

  // Dónde estaba el foco antes de abrir, leído al pintar y no en el efecto:
  // si un diálogo de dentro se monta a la vez, su efecto corre antes y ya se
  // habría llevado el foco.
  const [previo] = useState(() =>
    typeof document !== 'undefined' && document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null,
  )

  // El último `onClose`, sin tener que volver a apilar la ventana cada vez
  // que la pantalla lo recrea.
  useEffect(() => {
    cerrarRef.current = onClose
  }, [onClose])

  useEffect(() => {
    const ventana: Ventana = { caja: cajaRef, cerrar: cerrarRef }

    apilar(ventana)
    if (pila.length === 1) alAbrirLaPrimera()
    if (cajaRef.current) enfocarAlAbrir(cajaRef.current, cuerpoRef.current)

    return () => {
      const i = pila.indexOf(ventana)
      if (i >= 0) pila.splice(i, 1)
      if (pila.length === 0) alCerrarLaUltima()
      // Solo si sigue en la página: si lo que abrió la ventana era una fila
      // que ya no está, devolverle el foco lo mandaría al <body>.
      if (previo?.isConnected) previo.focus({ preventScroll: true })
    }
  }, [previo])

  const widths = { sm: 'max-w-md', md: 'max-w-xl', lg: 'max-w-3xl' }

  return (
    // En el teléfono la ventana es una hoja que sube desde abajo, de lado a
    // lado y con los botones al alcance del pulgar. `mt-auto` y no
    // `items-end`: con una hoja más alta que la pantalla, `items-end` la
    // cortaría por arriba, y el margen automático la deja desplazarse entera.
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto sm:p-6">
      {/* El velo se pulsa para cerrar, pero no entra en el recorrido de Tab:
          ya está la equis, y un botón que ocupa toda la pantalla no es un
          sitio al que llegar con el teclado. */}
      <button
        type="button"
        aria-label="Cerrar"
        tabIndex={-1}
        onClick={onClose}
        className="anim-velo fixed inset-0 bg-scrim/60"
      />
      <div
        ref={cajaRef}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        tabIndex={-1}
        className={`anim-ventana relative mt-auto w-full ${widths[width]} rounded-t-panel-card border border-panel-hairline-strong bg-panel-card p-5 pb-[max(1.25rem,env(safe-area-inset-bottom))] shadow-2xl outline-none max-sm:border-x-0 max-sm:border-b-0 sm:my-8 sm:rounded-panel-card sm:p-6`}
      >
        {!sinEncabezado && (
          <div className="mb-shell-gap-group flex items-start justify-between gap-4">
            <h2 className="type-panel-page text-on-surface">{title}</h2>
            <button
              type="button"
              onClick={onClose}
              aria-label="Cerrar"
              className="inline-flex size-10 shrink-0 items-center justify-center rounded-panel-control text-on-surface-variant transition-colors hover:bg-panel-raised hover:text-on-surface"
            >
              <X size={18} />
            </button>
          </div>
        )}
        <div ref={cuerpoRef}>{children}</div>
      </div>
    </div>
  )
}

// ── ConfirmDialog ─────────────────────────────────────────────────────────

/**
 * Cuánto cuesta equivocarse, y por tanto cuánto se pide antes de confirmar.
 *
 *   normal    un clic. Lo de siempre: `reasonLabel` y `confirmWord` siguen
 *             funcionando sueltos.
 *   sensible  afecta a todos los usuarios o al dinero de alguien: pide el
 *             motivo (con `reasonLabel` o, sin él, «Motivo»).
 *   critico   además es irreversible: pide el motivo Y escribir una palabra
 *             (`confirmWord` o, sin ella, «CONFIRMAR»), y el botón va en rojo.
 */
export type NivelConfirmacion = 'normal' | 'sensible' | 'critico'

/** La palabra de `critico` cuando la pantalla no pone la suya. */
const PALABRA_POR_DEFECTO = 'CONFIRMAR'

/** Lo mínimo para que un motivo diga algo. Lo mismo exige el servidor. */
const MOTIVO_MINIMO = 3

/**
 * El resumen de lo que va a pasar, antes de que pase.
 *
 * Toda acción de dinero o de identidad pasa por aquí, y `nivel` decide
 * cuánto se pide. `reasonLabel` convierte el diálogo en el sitio donde se
 * pide el motivo, que es donde tiene que estar: si el motivo se pide antes,
 * se escribe sin saber todavía qué se va a confirmar.
 *
 * Mientras no se pueda confirmar, el porqué va ESCRITO debajo del botón
 * (`motivoApagado`), no en un `title` que en la tablet no existe.
 */
export function ConfirmDialog({
  title,
  summary,
  detail,
  confirmLabel,
  nivel = 'normal',
  confirmWord,
  reasonLabel,
  reasonPlaceholder,
  motivoMinimo = MOTIVO_MINIMO,
  bloqueo,
  danger = false,
  busy = false,
  error,
  onConfirm,
  onClose,
}: {
  title: string
  /** Una frase con los datos concretos: "Vas a registrar €52,50 a Kabal…". */
  summary: string
  detail?: ReactNode
  confirmLabel: string
  /** Cuánto se pide antes de confirmar. Por defecto, `normal`. */
  nivel?: NivelConfirmacion
  /** Si viene, hay que teclearla para poder confirmar. En `critico` hay una
   *  por defecto. */
  confirmWord?: string
  /** Si viene, se pide motivo y se pasa a `onConfirm`. En `sensible` y
   *  `critico` se pide siempre, y esto solo cambia el rótulo. */
  reasonLabel?: string
  reasonPlaceholder?: string
  /**
   * Cuántos caracteres pide el motivo, cuando la acción exige más que los
   * tres de siempre. Tiene que ser lo mismo que exige el servidor: si pide
   * menos, el error llega después de confirmar. Solo cuenta si se pide motivo.
   */
  motivoMinimo?: number
  /**
   * Por qué todavía no se puede confirmar, en palabras.
   *
   * Lo pone la pantalla cuando le falta algo suyo —una casilla sin marcar, un
   * campo a medias—. Sin esto, el botón se pulsaba y no pasaba nada: el peor
   * de los estados, porque parece que la aplicación está rota.
   */
  bloqueo?: string
  /** El botón en rojo. `critico` lo pone solo. */
  danger?: boolean
  busy?: boolean
  error?: ReactNode
  /** Recibe el motivo ya recortado; cadena vacía si no se pidió. */
  onConfirm: (reason: string) => void
  onClose: () => void
}) {
  const [typed, setTyped] = useState('')
  const [reason, setReason] = useState('')
  const idMotivo = useId()
  const idPalabra = useId()

  const pideMotivo = nivel !== 'normal' || reasonLabel !== undefined
  const rotuloMotivo = reasonLabel ?? 'Motivo'
  const palabra = confirmWord ?? (nivel === 'critico' ? PALABRA_POR_DEFECTO : undefined)
  const rojo = danger || nivel === 'critico'

  const motivo = reason.trim()
  const wordOk = !palabra || typed.trim().toUpperCase() === palabra.toUpperCase()
  const reasonOk = !pideMotivo || motivo.length >= motivoMinimo
  const ready = wordOk && reasonOk && !bloqueo && !busy

  // El primero que falte, en el orden en que se rellena el diálogo.
  const blocked =
    bloqueo ??
    (!reasonOk
      ? motivo.length === 0
        ? 'Escribe el motivo para poder confirmar.'
        : `El motivo tiene que tener al menos ${motivoMinimo} caracteres.`
      : !wordOk
        ? `Escribe ${palabra} para confirmar.`
        : undefined)

  return (
    <Modal title={title} onClose={onClose} width="sm">
      <div className="flex flex-col gap-4">
        <p className="type-panel-body text-on-surface">{summary}</p>

        {detail && <Card tone="inset">{detail}</Card>}

        {pideMotivo && (
          <Input
            id={idMotivo}
            label={rotuloMotivo}
            value={reason}
            onChange={setReason}
            placeholder={reasonPlaceholder}
          />
        )}

        {palabra && (
          <Input
            id={idPalabra}
            label={`Escribe ${palabra} para confirmar`}
            value={typed}
            onChange={setTyped}
            placeholder={palabra}
            autoComplete="off"
          />
        )}

        {error && <ErrorBox title="No se pudo completar" detail={String(error)} />}

        {/* En el teléfono, uno encima de otro y de lado a lado: el pulgar
            acierta sin apuntar, y la acción queda arriba, donde se lee. */}
        <div className="flex flex-col gap-2 sm:flex-row sm:gap-3">
          <Button
            size="md"
            className="max-sm:w-full"
            variant={rojo ? 'danger' : 'filled'}
            disabled={!ready}
            // Mientras trabaja no hay motivo que escribir: el texto del botón
            // ya dice «Un momento…».
            motivoApagado={busy ? undefined : blocked}
            onClick={() => onConfirm(pideMotivo ? motivo : '')}
          >
            {busy ? 'Un momento…' : confirmLabel}
          </Button>
          <Button variant="text" size="md" className="max-sm:w-full" onClick={onClose}>
            Cancelar
          </Button>
        </div>
      </div>
    </Modal>
  )
}
