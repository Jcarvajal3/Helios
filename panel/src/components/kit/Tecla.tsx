import type { ReactNode } from 'react'

/**
 * Una tecla, dibujada como tecla: un atajo junto a lo que hace, o dentro de
 * la frase que lo explica.
 *
 * Había dos, la de la paleta con borde y la de las colas con relleno, cada una
 * con su radio y su letra. Lo único que cambia de verdad es `enBoton`: dentro
 * de un botón que ya dice lo que hace («Aprobar»), la tecla sobra para el
 * lector de pantalla, y solo sale con ratón porque la tablet no tiene teclado.
 */
export function Tecla({
  children,
  enBoton = false,
}: {
  children: ReactNode
  enBoton?: boolean
}) {
  return (
    <kbd
      aria-hidden={enBoton || undefined}
      className={`${enBoton ? 'hidden pointer-fine:inline-flex' : 'inline-flex'} h-5 min-w-5 shrink-0 items-center justify-center rounded-extra-small border border-panel-hairline-strong bg-panel-control px-1.5 type-panel-caption font-semibold text-on-surface-variant`}
    >
      {children}
    </kbd>
  )
}
