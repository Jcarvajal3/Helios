import { cloneElement, useCallback, useEffect, useId, useRef, useState } from 'react'
import type { FocusEvent, MouseEvent, PointerEvent, ReactElement, ReactNode } from 'react'

import { Capa, useFlotante } from './flotante'
import type { LadoFlotante } from './flotante'

/** Sin espera, cruzar una tabla con el ratón enciende veinte globos seguidos. */
const ESPERA_AL_ABRIR = 150

/** Da tiempo a llevar el ratón hasta el globo para leerlo o copiar la fórmula. */
const ESPERA_AL_CERRAR = 100

/**
 * Un globo con una explicación, junto a lo que explica.
 *
 * Se abre al pasar el ratón (con 150 ms de espera) y con el foco del teclado,
 * y se cierra con Escape. Con `fijable`, un clic lo deja abierto hasta otro
 * clic, Escape o un clic fuera: es lo que hace que se pueda leer en la tablet,
 * donde no hay ratón que pase por encima.
 *
 * El hijo es UN elemento que se enfoca —un botón— y recibe el
 * `aria-describedby` del globo mientras está abierto.
 */
export function Tooltip({
  contenido,
  children,
  lado = 'arriba',
  fijable = false,
}: {
  contenido: ReactNode
  children: ReactElement<{ 'aria-describedby'?: string }>
  lado?: LadoFlotante
  fijable?: boolean
}) {
  const [abierto, setAbierto] = useState(false)
  const [fijo, setFijo] = useState(false)
  const id = useId()
  const temporizador = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)

  const cerrar = useCallback(() => {
    clearTimeout(temporizador.current)
    setAbierto(false)
    setFijo(false)
  }, [])

  const flotante = useFlotante<HTMLSpanElement>({
    abierto,
    lado,
    alineacion: 'centro',
    alCerrar: cerrar,
  })

  useEffect(() => () => clearTimeout(temporizador.current), [])

  function programar(accion: () => void, espera: number) {
    clearTimeout(temporizador.current)
    temporizador.current = setTimeout(accion, espera)
  }

  // El dedo no pasa por encima: en la tablet manda el clic.
  function alEntrar(evento: PointerEvent) {
    if (evento.pointerType === 'touch') return
    if (abierto) clearTimeout(temporizador.current)
    else programar(() => setAbierto(true), ESPERA_AL_ABRIR)
  }

  function alSalir(evento: PointerEvent) {
    if (evento.pointerType === 'touch') return
    if (fijo) clearTimeout(temporizador.current)
    else programar(() => setAbierto(false), ESPERA_AL_CERRAR)
  }

  // Solo el foco del teclado: un clic también enfoca el botón, y ahí ya
  // decide el propio clic.
  function alEnfocar(evento: FocusEvent) {
    if (evento.target instanceof Element && evento.target.matches(':focus-visible')) {
      clearTimeout(temporizador.current)
      setAbierto(true)
    }
  }

  // Si estaba fijo y el foco se va a otro control, se cierra; si se va a
  // ninguno —un clic sobre el propio globo—, decide el clic fuera.
  function alDesenfocar(evento: FocusEvent) {
    const destino = evento.relatedTarget
    if (!fijo || (destino instanceof Node && !flotante.capaRef.current?.contains(destino))) {
      cerrar()
    }
  }

  function alPulsar(evento: MouseEvent) {
    if (!fijable) return
    // Puede vivir en la cabecera de una tabla o en una fila que se pulsa.
    evento.stopPropagation()
    if (fijo) {
      cerrar()
    } else {
      clearTimeout(temporizador.current)
      setAbierto(true)
      setFijo(true)
    }
  }

  return (
    <>
      <span
        ref={flotante.anclaRef}
        className="inline-flex"
        onPointerEnter={alEntrar}
        onPointerLeave={alSalir}
        onFocus={alEnfocar}
        onBlur={alDesenfocar}
        onClick={alPulsar}
      >
        {cloneElement(children, { 'aria-describedby': abierto ? id : undefined })}
      </span>
      <Capa
        flotante={flotante}
        abierto={abierto}
        id={id}
        role="tooltip"
        onPointerEnter={alEntrar}
        onPointerLeave={alSalir}
        className="anim-globo max-w-80 rounded-panel-control border border-panel-hairline-strong bg-panel-control px-3 py-2 type-panel-label font-normal text-on-surface shadow-2xl"
      >
        {contenido}
      </Capa>
    </>
  )
}
