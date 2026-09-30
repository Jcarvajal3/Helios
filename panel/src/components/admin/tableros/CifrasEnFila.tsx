import type { ReactNode } from 'react'

import { InfoDot } from '@/components/ui'

/** Una cifra pequeña dentro de una tarjeta: el volumen, las partes del capital. */
export type CifraEnFila = {
  rotulo: string
  /** Ya formateada. Puede ser un enlace a la lista que la compone. */
  valor: ReactNode
  /** Una línea debajo, que se corta si no cabe. */
  pie?: ReactNode
  info?: string
}

/**
 * Cuántas por fila en ancho completo, y desde qué hueco caben. Los separadores
 * de un pelo solo salen cuando van todas en una fila: partidas en dos, el
 * primero de la segunda llevaría una raya a la izquierda que no separa nada.
 */
const REJILLA = {
  2: {
    fila: 'grid-cols-2',
    celda: 'border-l border-panel-hairline pl-5 first:border-l-0 first:pl-0',
  },
  3: {
    fila: 'grid-cols-1 @md:grid-cols-3',
    celda: '@md:border-l @md:border-panel-hairline @md:pl-5 @md:first:border-l-0 @md:first:pl-0',
  },
  4: {
    fila: 'grid-cols-2 @2xl:grid-cols-4',
    celda:
      '@2xl:border-l @2xl:border-panel-hairline @2xl:pl-5 @2xl:first:border-l-0 @2xl:first:pl-0',
  },
} as const

/**
 * Cifras secundarias en una fila, separadas por un pelo, dentro de una
 * tarjeta que ya tiene su titular.
 *
 * Es lo que va debajo de una cifra grande o dentro de un bloque: cuatro
 * `Stat` enteras competirían con la cifra que manda; esto se lee como sus
 * partes. Sustituye los `<dl>` que cada tablero escribía a su manera.
 */
export function CifrasEnFila({
  cifras,
  className = '',
}: {
  cifras: ReadonlyArray<CifraEnFila>
  className?: string
}) {
  const n = cifras.length >= 4 ? 4 : cifras.length === 3 ? 3 : 2
  const { fila, celda } = REJILLA[n]

  return (
    <div className={`@container ${className}`}>
      <dl className={`grid gap-x-5 gap-y-4 ${fila}`}>
        {cifras.map((c) => (
          <div key={c.rotulo} className={`flex min-w-0 flex-col gap-1 ${celda}`}>
            <dt className="flex items-center gap-1 type-panel-caption text-panel-muted">
              {c.rotulo}
              {c.info && <InfoDot title={c.rotulo} what={c.info} />}
            </dt>
            {/* 22 y no la cifra de tarjeta (28): son las partes de una cifra que
                ya manda en la tarjeta, y a la misma medida competirían con ella.
                Es la medida del título de página, sin más relación con él. */}
            <dd className="type-panel-page text-on-surface">{c.valor}</dd>
            {c.pie && <dd className="truncate type-panel-caption text-panel-muted">{c.pie}</dd>}
          </div>
        ))}
      </dl>
    </div>
  )
}

/** Una cifra dentro de una frase: en blanco, para que se lea antes que el resto. */
export function Cifra({ children }: { children: ReactNode }) {
  return <strong className="font-semibold text-on-surface">{children}</strong>
}
