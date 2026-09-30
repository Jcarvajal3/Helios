import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import type {
  CSSProperties,
  ComponentPropsWithoutRef,
  MouseEvent,
  KeyboardEvent as ReactKeyboardEvent,
  ReactNode,
  RefObject,
} from 'react'
import { createPortal } from 'react-dom'

import { calcularPosicion } from './posicion'
import type { AlineacionFlotante, LadoFlotante, Posicion } from './posicion'

export type { AlineacionFlotante, LadoFlotante } from './posicion'

// ═══════════════════════════════════════════════════════════════════════════
// La maquinaria común de lo que flota: el tooltip, el menú «⋯» y el periodo.
//
// Las tres cosas necesitan lo mismo y ninguna lo tenía: salir de la caja que
// las recorta (portal a `document.body`), pintarse junto al disparador sin
// salirse de la ventana, cerrarse con Escape y con un clic fuera, y devolver
// el foco a donde estaba. Sin librerías.
// ═══════════════════════════════════════════════════════════════════════════

/** Por qué se cerró. Con Escape el foco vuelve al disparador; con un clic fuera se queda donde se pulsó. */
export type MotivoDeCierre = 'escape' | 'fuera'

export type Flotante<TAncla extends HTMLElement> = {
  /** Para el disparador: de él se mide la posición y a él vuelve el foco. */
  anclaRef: RefObject<TAncla | null>
  capaRef: RefObject<HTMLDivElement | null>
  /** `position: fixed` en la esquina calculada. */
  estilo: CSSProperties
  /** El lado en el que acabó, que puede no ser el pedido. */
  lado: LadoFlotante
}

/**
 * Coloca una capa junto a su disparador y la cierra con Escape o con un clic
 * fuera. La capa se pinta con `Capa`.
 */
export function useFlotante<TAncla extends HTMLElement = HTMLElement>({
  abierto,
  lado = 'abajo',
  alineacion = 'inicio',
  separacion = 8,
  alCerrar,
}: {
  abierto: boolean
  lado?: LadoFlotante
  alineacion?: AlineacionFlotante
  /** Píxeles entre el disparador y la capa. */
  separacion?: number
  alCerrar: (motivo: MotivoDeCierre) => void
}): Flotante<TAncla> {
  const anclaRef = useRef<TAncla>(null)
  const capaRef = useRef<HTMLDivElement>(null)
  const [posicion, setPosicion] = useState<Posicion | null>(null)

  // El último `alCerrar`, sin volver a colgar los oyentes cada vez que la
  // pantalla lo recrea.
  const alCerrarRef = useRef(alCerrar)
  useLayoutEffect(() => {
    alCerrarRef.current = alCerrar
  })

  const colocar = useCallback(() => {
    const ancla = anclaRef.current
    const capa = capaRef.current
    if (!ancla || !capa) return
    setPosicion(
      calcularPosicion({
        ancla: ancla.getBoundingClientRect(),
        capa: { ancho: capa.offsetWidth, alto: capa.offsetHeight },
        vista: { ancho: document.documentElement.clientWidth, alto: window.innerHeight },
        lado,
        alineacion,
        separacion,
      }),
    )
  }, [lado, alineacion, separacion])

  // Se mide antes de pintar, así que la capa nunca asoma en la esquina de la
  // ventana. Se vuelve a medir al desplazar cualquier contenedor (en captura),
  // al cambiar la ventana y cuando la propia capa cambia de tamaño —un error
  // que aparece dentro del periodo—.
  useLayoutEffect(() => {
    if (!abierto) return
    colocar()
    const capa = capaRef.current
    const observador =
      typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(() => colocar())
    if (capa) observador?.observe(capa)
    window.addEventListener('resize', colocar)
    window.addEventListener('scroll', colocar, true)
    return () => {
      observador?.disconnect()
      window.removeEventListener('resize', colocar)
      window.removeEventListener('scroll', colocar, true)
      setPosicion(null)
    }
  }, [abierto, colocar])

  useEffect(() => {
    if (!abierto) return

    // En captura y cortando la propagación: Escape es de lo que flota antes
    // que de la ventana que lo contiene. Sin esto, cerrar un menú dentro de
    // un `Modal` cerraba también el `Modal` y se perdía lo escrito.
    function alTeclear(evento: KeyboardEvent) {
      if (evento.key !== 'Escape') return
      evento.preventDefault()
      evento.stopPropagation()
      const activo = document.activeElement
      const focoDentro = activo instanceof Node && !!capaRef.current?.contains(activo)
      alCerrarRef.current('escape')
      if (focoDentro) anclaRef.current?.focus()
    }

    function alPulsar(evento: PointerEvent) {
      const objetivo = evento.target
      if (!(objetivo instanceof Node)) return
      if (anclaRef.current?.contains(objetivo) || capaRef.current?.contains(objetivo)) return
      alCerrarRef.current('fuera')
    }

    document.addEventListener('keydown', alTeclear, true)
    document.addEventListener('pointerdown', alPulsar, true)
    return () => {
      document.removeEventListener('keydown', alTeclear, true)
      document.removeEventListener('pointerdown', alPulsar, true)
    }
  }, [abierto])

  return {
    anclaRef,
    capaRef,
    estilo: {
      position: 'fixed',
      top: posicion?.top ?? 0,
      left: posicion?.left ?? 0,
    },
    lado: posicion?.lado ?? lado,
  }
}

/**
 * Tab en el primer o el último control de una capa: la capa va en un portal
 * al final de la página, y tabular más allá llevaría el foco fuera del
 * documento. Al salir por un extremo se cierra y el foco sigue desde el
 * disparador, como si la capa estuviera justo detrás de él.
 */
export function salirConTab(
  evento: ReactKeyboardEvent<HTMLElement>,
  ancla: HTMLElement | null,
  cerrar: () => void,
) {
  if (evento.key !== 'Tab') return
  const controles = Array.from(
    evento.currentTarget.querySelectorAll<HTMLElement>(
      'button:not([tabindex="-1"]):not(:disabled), input:not(:disabled)',
    ),
  )
  const activo = document.activeElement
  const saleHaciaAtras = evento.shiftKey && activo === controles.at(0)
  const saleHaciaDelante = !evento.shiftKey && activo === controles.at(-1)
  if (!saleHaciaAtras && !saleHaciaDelante) return
  if (saleHaciaAtras) evento.preventDefault()
  ancla?.focus()
  cerrar()
}

/**
 * La capa de lo que flota, en un portal a `document.body`.
 *
 * Lleva `data-flotante` para que un `Modal` no le robe el foco al tabular
 * dentro de ella. Los clics de dentro no siguen subiendo por el árbol de
 * React: un menú abierto desde una fila que se pulsa no abre también la fila.
 */
export function Capa({
  flotante,
  abierto,
  children,
  className = '',
  style,
  onClick,
  ...resto
}: {
  flotante: Pick<Flotante<HTMLElement>, 'capaRef' | 'estilo'>
  abierto: boolean
  children: ReactNode
} & Omit<ComponentPropsWithoutRef<'div'>, 'children'>) {
  if (!abierto) return null

  function alPulsar(evento: MouseEvent<HTMLDivElement>) {
    evento.stopPropagation()
    onClick?.(evento)
  }

  return createPortal(
    <div
      {...resto}
      ref={flotante.capaRef}
      data-flotante=""
      onClick={alPulsar}
      style={{ ...flotante.estilo, ...style }}
      className={`z-60 ${className}`}
    >
      {children}
    </div>,
    document.body,
  )
}
