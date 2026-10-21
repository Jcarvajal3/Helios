import { useEffect, useRef } from 'react'
import type { CSSProperties, ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { SquarePen } from 'lucide-react'

import {
  ConversacionAsistente,
  useAsistentePanel,
  useConversacionDelAsistente,
} from '@/components/admin/asistente'
import { ICONO_DE_TONO } from '@/components/kit/tonos'
import { hayModalAbierto } from '@/components/overlays'
import { Button, Tecla } from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import { pastillasDeLaCharla } from './charla'
import type { PastillaDeLaCharla } from './charla'
import { Halo } from './Halo'
import { useCierreDeHoy, useDeudaVencida, useImpagoPrimeraCuota } from './useCifrasDeHoy'
import { usePendiente } from './usePendiente'

/**
 * El alto de la charla: la pantalla menos la barra de arriba, que en Inicio
 * solo existe por debajo de 1024 px (desde ahí es `lg:h-dvh`). Con el alto
 * acotado, la conversación desplaza por dentro y el campo queda anclado abajo.
 */
const ALTO: CSSProperties & { '--alto-de-la-charla': string } = {
  '--alto-de-la-charla': 'calc(100dvh - var(--topbar-height))',
}

/** El color del icono de estado de una pastilla: el mismo rojo de texto que las pastillas del kit. */
const COLOR_DEL_ICONO: Partial<Record<BadgeTone, string>> = {
  success: 'text-success',
  warning: 'text-warning',
  error: 'text-panel-critico',
}

const CLASE_PASTILLA =
  'inline-flex h-7.5 items-center gap-1.5 whitespace-nowrap rounded-full border border-panel-hairline bg-panel-card px-3 type-panel-label text-on-surface-variant transition-colors duration-(--transition-fast) hover:bg-panel-raised hover:text-on-surface'

/** Una pastilla de la tira: su estado con icono (o un punto neutro) y a dónde lleva. */
function Pastilla({ pastilla, onVolver }: { pastilla: PastillaDeLaCharla; onVolver: () => void }) {
  const Icono = ICONO_DE_TONO[pastilla.tono]
  const contenido: ReactNode = (
    <>
      {Icono ? (
        <Icono size={13} strokeWidth={2.25} aria-hidden className={`shrink-0 ${COLOR_DEL_ICONO[pastilla.tono] ?? ''}`} />
      ) : (
        <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-panel-muted" />
      )}
      {pastilla.texto}
    </>
  )

  if (!pastilla.destino) {
    return (
      <button type="button" onClick={onVolver} className={CLASE_PASTILLA}>
        {contenido}
      </button>
    )
  }
  return (
    <Link {...pastilla.destino} className={CLASE_PASTILLA}>
      {contenido}
    </Link>
  )
}

/** Lo pendiente y tres cifras, plegados: las mismas lecturas que la pantalla normal. */
function TiraDeLaCharla({ onVolver }: { onVolver: () => void }) {
  const pastillas = pastillasDeLaCharla({
    pendiente: usePendiente(),
    mora: useDeudaVencida(),
    cierre: useCierreDeHoy(),
    impago: useImpagoPrimeraCuota(),
  })

  return (
    <nav aria-label="Lo que pide atención" className="flex min-w-0 flex-1 flex-wrap items-center gap-2">
      {pastillas.map((p) => (
        <Pastilla key={p.clave} pastilla={p} onVolver={onVolver} />
      ))}
    </nav>
  )
}

/** Empezar de nuevo. Lee la conversación, así que va aparte y solo se repinta él. */
function BotonConversacionNueva() {
  const { nuevaConversacion } = useAsistentePanel()
  const { conversacion } = useConversacionDelAsistente()
  return (
    <Button variant="text" size="sm" onClick={nuevaConversacion} disabled={conversacion.mensajes.length === 0}>
      <SquarePen size={15} aria-hidden />
      Conversación nueva
    </Button>
  )
}

/**
 * Inicio en conversación: la pregunta sube, lo pendiente y las cifras se
 * pliegan en una tira de pastillas arriba, y la conversación ocupa la
 * columna central con el campo anclado abajo.
 *
 * «Volver a Inicio», Escape y Atrás del navegador llevan a la pantalla
 * normal; la conversación se queda guardada y el héroe ofrece seguirla.
 */
export function CharlaDeInicio({ onVolver }: { onVolver: () => void }) {
  // El último `onVolver`, sin volver a colgar el oyente de Escape.
  const volver = useRef(onVolver)
  useEffect(() => {
    volver.current = onVolver
  })

  useEffect(() => {
    function alTeclear(evento: KeyboardEvent) {
      // Lo que flota (un tooltip, un menú) y las ventanas usan Escape antes.
      if (evento.key !== 'Escape' || evento.defaultPrevented || hayModalAbierto()) return
      evento.preventDefault()
      volver.current()
    }
    document.addEventListener('keydown', alTeclear)
    return () => document.removeEventListener('keydown', alTeclear)
  }, [])

  return (
    <div className="relative isolate -my-5 flex h-(--alto-de-la-charla) flex-col lg:-my-6 lg:h-dvh" style={ALTO}>
      <Halo donde="charla" />

      <header className="-mx-4 flex min-h-15 shrink-0 flex-wrap items-center gap-2 border-b border-panel-hairline px-4 py-2.5 lg:-mx-8 lg:px-8">
        <TiraDeLaCharla onVolver={onVolver} />
        <div className="ml-auto flex shrink-0 items-center gap-2">
          <BotonConversacionNueva />
          <Button variant="tonal" size="sm" onClick={onVolver}>
            Volver a Inicio
            <Tecla enBoton>Esc</Tecla>
          </Button>
        </div>
      </header>

      <ConversacionAsistente variante="pagina" />
    </div>
  )
}
