import { useId } from 'react'
import type { ReactNode } from 'react'

import { InfoDot } from './InfoDot'

/**
 * Una sección de un tablero: el título, su explicación en el `InfoDot` y los
 * controles a la derecha, en la misma línea.
 *
 * Los controles van en la cabecera y no encima: en Riesgo, «Ventana» y su
 * filtro flotaban sobre el título sin alinearse con nada, y no se sabía a qué
 * sección tocaban. Lo que antes era un párrafo gris debajo del título va al
 * `info`.
 */
export function Seccion({
  titulo,
  info,
  controles,
  as: Etiqueta = 'section',
  children,
  className = '',
}: {
  titulo: string
  info?: string
  /** Filtros, periodo, la acción de la sección. Se parten a otra línea si no caben. */
  controles?: ReactNode
  as?: 'section' | 'div'
  children: ReactNode
  className?: string
}) {
  const id = useId()

  return (
    <Etiqueta
      aria-labelledby={Etiqueta === 'section' ? id : undefined}
      className={`flex flex-col gap-3.5 ${className}`}
    >
      <div className="flex min-h-9 flex-wrap items-center gap-x-2 gap-y-2">
        <h2 id={id} className="type-panel-section text-on-surface">
          {titulo}
        </h2>
        {info && <InfoDot title={titulo} what={info} />}
        {controles && (
          <div className="ml-auto flex flex-wrap items-center justify-end gap-2">{controles}</div>
        )}
      </div>
      {children}
    </Etiqueta>
  )
}
