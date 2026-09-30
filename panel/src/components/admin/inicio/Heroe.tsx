import { useId } from 'react'
import { MessageSquareText } from 'lucide-react'

import {
  COLUMNA_DE_LA_CHARLA,
  SugerenciasDelAsistente,
  useAsistentePanel,
  useConversacionDelAsistente,
} from '@/components/admin/asistente'
import { Button } from '@/components/ui'
import { BarraDeInicio } from './BarraDeInicio'
import { Halo } from './Halo'
import { Saludo } from './Saludo'

/**
 * «Seguir la conversación», solo si hay una guardada. Va aparte porque lee la
 * conversación, que cambia con cada trozo de respuesta: así solo se repinta él.
 */
function SeguirLaConversacion({ onSeguir }: { onSeguir: () => void }) {
  const { conversacion } = useConversacionDelAsistente()
  if (conversacion.mensajes.length === 0) return null
  return (
    <Button variant="text" size="sm" onClick={onSeguir}>
      <MessageSquareText size={15} aria-hidden />
      Seguir la conversación
    </Button>
  )
}

/**
 * El héroe de Inicio, centrado en lo que queda de pantalla: el saludo, la
 * barra que pregunta y busca, tres preguntas de ejemplo y qué hace el
 * asistente, en una línea. Detrás, el halo.
 *
 * Sin asistente (`VITE_ASISTENTE`) queda el saludo y la barra, que solo busca.
 */
export function Heroe({
  onSeguirLaConversacion,
  conAsistente,
}: {
  onSeguirLaConversacion: () => void
  conAsistente: boolean
}) {
  const { preguntar } = useAsistentePanel()
  const idSaludo = useId()

  return (
    <section
      aria-labelledby={idSaludo}
      className="relative isolate flex flex-1 flex-col items-center justify-center gap-4.5 pb-2 pt-4"
    >
      <Halo donde="heroe" />
      <Saludo id={idSaludo} />
      <div className={COLUMNA_DE_LA_CHARLA}>
        <BarraDeInicio conAsistente={conAsistente} />
      </div>
      {conAsistente && (
        <>
          <SeguirLaConversacion onSeguir={onSeguirLaConversacion} />
          <SugerenciasDelAsistente onElegir={preguntar} className="justify-center" />
          <p className="text-center type-panel-caption text-panel-muted">
            Lee las cifras de la base en el momento. No cambia nada.
          </p>
        </>
      )}
    </section>
  )
}
