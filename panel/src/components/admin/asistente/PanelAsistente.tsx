import { useCallback, useEffect, useId, useState } from 'react'
import type { KeyboardEvent } from 'react'
import { SquarePen, X } from 'lucide-react'

import { hayModalAbierto } from '@/components/overlays'
import { Button, IconButton } from '@/components/ui'
import { useAsistentePanel, useConversacionDelAsistente } from './contexto'
import { ConversacionAsistente } from './ConversacionAsistente'

/** Por debajo de esto el cajón ocupa la pantalla entera y tapa lo que se abre. */
const PANTALLA_COMPLETA = '(max-width: 767px)'

/** El botón de empezar de nuevo: solo lee si hay algo que vaciar. */
function BotonConversacionNueva() {
  const { nuevaConversacion } = useAsistentePanel()
  const { conversacion } = useConversacionDelAsistente()
  return (
    <Button variant="tonal" size="sm" onClick={nuevaConversacion} disabled={conversacion.mensajes.length === 0}>
      <SquarePen size={14} aria-hidden />
      Conversación nueva
    </Button>
  )
}

/**
 * El cajón del asistente: su cabecera y la conversación.
 *
 * No es una ventana modal. Se queda abierto al lado de la pantalla, y los
 * enlaces de las respuestas navegan sin cerrarlo para comparar lo que dice
 * con lo que se ve. Por debajo de 768 px ocupa la pantalla entera: ahí un
 * enlace sí lo cierra, porque si no, la pantalla nueva quedaría debajo.
 */
export function PanelAsistente() {
  const { cerrar } = useAsistentePanel()
  const idTitulo = useId()

  // Dónde estaba el foco al abrir, para devolverlo al cerrar (como `Modal`).
  const [previo] = useState(() =>
    typeof document !== 'undefined' && document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null,
  )
  useEffect(
    () => () => {
      const perdido = document.activeElement === null || document.activeElement === document.body
      if (perdido && previo?.isConnected) previo.focus({ preventScroll: true })
    },
    [previo],
  )

  const alNavegar = useCallback(() => {
    if (window.matchMedia(PANTALLA_COMPLETA).matches) cerrar()
  }, [cerrar])

  function alTeclear(evento: KeyboardEvent<HTMLElement>) {
    if (evento.key !== 'Escape' || hayModalAbierto()) return
    evento.preventDefault()
    cerrar()
  }

  return (
    <section
      // `MARCA_DEL_CAJON`: el atajo mira si el foco está aquí dentro.
      data-asistente=""
      aria-labelledby={idTitulo}
      onKeyDown={alTeclear}
      className="flex h-full min-h-0 flex-col"
    >
      <header className="flex h-[var(--topbar-height)] shrink-0 items-center gap-2 border-b border-panel-hairline pl-4 pr-2">
        <div className="min-w-0 flex-1">
          <h2 id={idTitulo} className="type-panel-section text-on-surface">
            Asistente
          </h2>
          <p className="truncate type-panel-caption text-panel-muted">Solo lee: no cambia nada.</p>
        </div>
        <BotonConversacionNueva />
        <IconButton variant="text" label="Cerrar el asistente" onClick={cerrar}>
          <X size={18} aria-hidden />
        </IconButton>
      </header>

      <ConversacionAsistente variante="cajon" alNavegar={alNavegar} />
    </section>
  )
}
