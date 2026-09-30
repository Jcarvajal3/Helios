import { useSyncExternalStore } from 'react'

import { Tecla } from '@/components/ui'

/** Nada que escuchar: el sistema no cambia con la página abierta. */
const sinCambios = () => () => {}

/**
 * Si el navegador corre en un Mac (o un iPad con teclado), donde el atajo es
 * ⌘K y no Ctrl K. En el servidor se asume que no, y el cliente lo corrige al
 * hidratar sin que React proteste.
 */
export function useEsMac(): boolean {
  return useSyncExternalStore(
    sinCambios,
    () => /Mac|iPhone|iPad|iPod/.test(navigator.userAgent),
    () => false,
  )
}

/**
 * Las teclas del pie de la paleta, una por atajo: es una lista, no una frase.
 * Con el dedo no hace falta.
 */
export function AyudaDeTeclado({ esMac }: { esMac: boolean }) {
  return (
    <ul
      aria-label="Atajos de teclado"
      className="hidden flex-wrap items-center gap-x-4 gap-y-1 border-t border-panel-hairline pt-3 type-panel-caption text-panel-muted md:flex"
    >
      <li className="inline-flex items-center gap-1">
        <Tecla>↑</Tecla>
        <Tecla>↓</Tecla> para moverte
      </li>
      <li className="inline-flex items-center gap-1">
        <Tecla>Enter</Tecla> para abrir
      </li>
      <li className="inline-flex items-center gap-1">
        <Tecla>{esMac ? '⌘' : 'Ctrl'}</Tecla>
        <Tecla>Enter</Tecla> para abrir en otra pestaña
      </li>
      <li className="inline-flex items-center gap-1">
        <Tecla>Esc</Tecla> para cerrar
      </li>
    </ul>
  )
}
