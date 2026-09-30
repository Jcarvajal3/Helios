import { Info } from 'lucide-react'
import type { ReactNode } from 'react'

import { Tooltip } from './Tooltip'

/**
 * El icono de información que explica una cifra, una columna o un bloque.
 *
 * No es un adorno: es la regla de «un número, una definición, un lugar». La
 * tarjeta enseña la cifra; esto enseña qué es, la cuenta **con los valores de
 * ese momento** —lo único que permite descubrir que dos pantallas suman cosas
 * distintas— y de qué datos sale.
 *
 * Es el sitio de las explicaciones: lo que antes era un párrafo gris debajo
 * de un título viene aquí. Se abre al pasar el ratón o con el foco y se queda
 * fijo con un clic.
 */
export function InfoDot({
  title,
  what,
  formula,
  origen,
}: {
  title: string
  /** Qué es, en una frase. */
  what: string
  /** La cuenta con los valores de ahora: "Caja €126,55 − Por pagar €168,00 = −€41,45". */
  formula?: string
  /** De qué pantalla o de qué datos sale: "Cartera vencida, sin las cuentas de prueba". */
  origen?: string
}) {
  return (
    <Tooltip
      fijable
      lado="abajo"
      contenido={
        <span className="flex w-72 flex-col gap-2.5 py-1">
          <span className="type-panel-body font-bold text-on-surface">{title}</span>
          <Apartado rotulo="Qué es">{what}</Apartado>
          {formula && (
            <Apartado rotulo="Cómo se calcula">
              <span className="tabular-nums">{formula}</span>
            </Apartado>
          )}
          {origen && <Apartado rotulo="De dónde sale">{origen}</Apartado>}
        </span>
      }
    >
      <button
        type="button"
        aria-label={`Qué es ${title}`}
        // `en-linea`: cuelga del rótulo de una cifra o de una columna, dentro
        // del renglón. Con el mínimo táctil de 44 px, cada cabecera con regla
        // crecería hasta partir la fila de cabeceras en dos alturas.
        className="en-linea inline-flex size-5 shrink-0 items-center justify-center rounded-full text-panel-muted transition-colors duration-[var(--transition-fast)] hover:bg-panel-control hover:text-on-surface"
      >
        <Info size={14} aria-hidden />
      </button>
    </Tooltip>
  )
}

function Apartado({ rotulo, children }: { rotulo: string; children: ReactNode }) {
  return (
    <span className="flex flex-col gap-0.5">
      <span className="type-panel-caption font-bold text-on-surface-variant">{rotulo}</span>
      <span className="type-panel-label font-normal text-on-surface">{children}</span>
    </span>
  )
}
