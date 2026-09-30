import { useId } from 'react'
import type { ReactNode } from 'react'

import { InfoDot } from '@/components/ui'

/**
 * Un bloque de una pestaña de Métricas: una tarjeta con su título, su
 * `InfoDot`, una línea de ayuda como mucho y las acciones a la derecha (un
 * Segmented, un enlace «Ver en Por cobrar»).
 *
 * Es la tarjeta de «Semana a semana» de la maqueta. Para un gráfico solo está
 * `ChartCard` (con su botón de tabla); esto es para lo demás: una tabla, una
 * lista, varias cifras juntas. La explicación larga va al `info`, no a un
 * párrafo: la gente no lee.
 */
export function SeccionMetricas({
  titulo,
  info,
  ayuda,
  acciones,
  children,
  className = '',
}: {
  titulo: string
  /** Qué es y cómo se calcula. Va al `InfoDot`. */
  info?: string
  /** Una línea al lado del título, en gris: «Pulsa una fila para ver su detalle». */
  ayuda?: string
  /** A la derecha de la cabecera. Se parten a otra línea si no caben. */
  acciones?: ReactNode
  children: ReactNode
  className?: string
}) {
  const id = useId()

  return (
    // La caja de `Card`, escrita aquí porque `Card` no deja nombrar la
    // sección con su título (`aria-labelledby`).
    <section
      aria-labelledby={id}
      className={`flex flex-col gap-4 rounded-panel-card border border-panel-hairline bg-panel-card p-panel-pad-card ${className}`}
    >
      <div className="flex min-h-9 flex-wrap items-center gap-x-3 gap-y-2">
        <div className="flex min-w-0 items-center gap-1.5">
          <h2 id={id} className="type-panel-section text-on-surface">
            {titulo}
          </h2>
          {info && <InfoDot title={titulo} what={info} />}
        </div>
        {ayuda && <p className="type-panel-caption text-panel-muted">{ayuda}</p>}
        {acciones && (
          <div className="ml-auto flex flex-wrap items-center justify-end gap-2">{acciones}</div>
        )}
      </div>
      {children}
    </section>
  )
}
