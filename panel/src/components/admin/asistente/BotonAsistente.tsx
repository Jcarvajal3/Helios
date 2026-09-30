import { MessageSquareText } from 'lucide-react'

import { useEsMac } from '@/components/admin/paleta/teclado'
import { useAsistentePanel } from './contexto'

/**
 * El botón del asistente en la barra de arriba: abre y cierra el cajón (o,
 * con un anfitrión registrado, lleva a su charla). Desde 768 px lleva el
 * rótulo; por debajo queda el icono, al lado de la lupa.
 */
export function BotonAsistente() {
  const { abierto, alternar } = useAsistentePanel()
  const esMac = useEsMac()
  const atajo = esMac ? '⌘J' : 'Ctrl J'

  return (
    <button
      type="button"
      onClick={alternar}
      aria-expanded={abierto}
      aria-keyshortcuts={esMac ? 'Meta+J' : 'Control+J'}
      title={`Asistente (${atajo})`}
      className={`inline-flex h-panel-control-md shrink-0 items-center gap-2 rounded-panel-control px-2.5 text-on-surface transition-colors duration-[var(--transition-fast)] md:px-3.5 ${
        abierto ? 'bg-panel-control' : 'bg-panel-raised hover:bg-panel-control'
      }`}
    >
      <MessageSquareText size={18} aria-hidden />
      <span className="sr-only type-panel-control md:not-sr-only">Asistente</span>
    </button>
  )
}
