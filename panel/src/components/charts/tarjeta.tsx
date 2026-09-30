import { useId, useState } from 'react'
import type { ReactNode } from 'react'
import { Table2 } from 'lucide-react'

import { Card, InfoDot } from '@/components/ui'
import { Muestra } from '@/components/charts/lectura'
import type { FormaDeMuestra } from '@/components/charts/lectura'

/** Una entrada de la leyenda: la muestra dibujada como su marca. */
export type EntradaDeLeyenda = { rotulo: string; color: string; forma?: FormaDeMuestra }

export type ChartCardProps = {
  titulo: string
  /** La explicación del gráfico: va al InfoDot, no a un párrafo debajo. */
  info?: string
  /** La línea con las cifras del periodo, debajo del título. */
  resumen?: ReactNode
  /** Con dos series o más. Una sola serie no la necesita: la nombra el título. */
  leyenda?: ReadonlyArray<EntradaDeLeyenda>
  /** Lo que va a la derecha de la cabecera: un Segmented, un enlace. */
  controles?: ReactNode
  /** Los números del gráfico. Si hay, la cabecera lleva el botón gráfico/tabla. */
  tabla?: ReactNode
  children: ReactNode
  className?: string
}

/**
 * EL MARCO DE UN GRÁFICO.
 *
 * A la izquierda, el título con su InfoDot y la línea de resumen; a la
 * derecha, la leyenda, los controles y el botón que cambia el gráfico por su
 * tabla. Ese botón sustituye al «Ver los números» que colgaba debajo de cada
 * gráfico: la tabla sigue a un clic, pero ya no ocupa una línea en cada
 * tarjeta.
 */
export function ChartCard({
  titulo,
  info,
  resumen,
  leyenda,
  controles,
  tabla,
  children,
  className = '',
}: ChartCardProps) {
  const [enTabla, setEnTabla] = useState(false)
  const cuerpoId = useId()
  const conTabla = tabla !== undefined && tabla !== null
  const verTabla = conTabla && enTabla

  return (
    <Card className={className}>
      <figure className="flex flex-col">
        <figcaption>
          <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
            <div className="flex min-w-0 items-center gap-1.5">
              <h3 className="type-panel-section text-on-surface">{titulo}</h3>
              {info && <InfoDot title={titulo} what={info} />}
            </div>

            <div className="ml-auto flex flex-wrap items-center gap-x-4 gap-y-2">
              {leyenda && leyenda.length > 0 && (
                <ul className="flex flex-wrap items-center gap-x-3 gap-y-1">
                  {leyenda.map((l, i) => (
                    <li
                      key={`${i}-${l.rotulo}`}
                      className="inline-flex items-center gap-1.5 type-panel-caption text-on-surface-variant"
                    >
                      <Muestra color={l.color} forma={l.forma} />
                      {l.rotulo}
                    </li>
                  ))}
                </ul>
              )}
              {controles}
              {conTabla && (
                <button
                  type="button"
                  onClick={() => setEnTabla((v) => !v)}
                  aria-pressed={enTabla}
                  aria-controls={cuerpoId}
                  aria-label="Ver los números en una tabla"
                  title={enTabla ? 'Volver al gráfico' : 'Ver los números en una tabla'}
                  className={`inline-flex size-8 items-center justify-center rounded-panel-control transition-colors duration-[var(--transition-fast)] hover:bg-panel-raised hover:text-on-surface ${
                    enTabla ? 'bg-panel-raised text-on-surface' : 'text-panel-muted'
                  }`}
                >
                  <Table2 size={16} aria-hidden />
                </button>
              )}
            </div>
          </div>

          {resumen && <p className="mt-1 type-panel-body text-on-surface-variant">{resumen}</p>}
        </figcaption>

        <div id={cuerpoId} className="mt-4">
          {verTabla ? tabla : children}
        </div>
      </figure>
    </Card>
  )
}
