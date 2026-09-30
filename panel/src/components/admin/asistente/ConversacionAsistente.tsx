import { useCallback, useEffect, useLayoutEffect, useRef } from 'react'
import type { ReactNode } from 'react'

import { ultimaPregunta } from '@/features/admin/asistente/conversacion'
import { CampoPregunta } from './CampoPregunta'
import { useAsistentePanel, useConversacionDelAsistente } from './contexto'
import { MensajeAsistente } from './MensajeAsistente'
import { SugerenciasDelAsistente } from './Sugerencias'

/** Dónde se pinta la conversación: el cajón lateral o la página de Inicio. */
export type VarianteDeConversacion = 'cajon' | 'pagina'

/**
 * La columna de la charla en página: 760 como mucho y centrada. La exporta
 * para que la barra de Inicio mida lo mismo que la conversación que abre.
 */
export const COLUMNA_DE_LA_CHARLA = 'mx-auto w-full max-w-190'

/** Cuánto se tolera estar por encima del final y seguir «pegado» a lo nuevo. */
const MARGEN_DE_PEGADO = 80

const FORMA: Record<VarianteDeConversacion, { registro: string; columna: string; burbuja: string }> = {
  cajon: {
    registro: 'px-4 py-4',
    // El cuerpo de 14 del panel: lo heredan el texto y la burbuja.
    columna: 'gap-5 type-panel-body',
    burbuja: 'max-w-4/5',
  },
  pagina: {
    registro: 'px-4 pt-7 md:px-8',
    // En página se lee como un documento: la misma letra, más aire entre mensajes.
    columna: `${COLUMNA_DE_LA_CHARLA} gap-6 pb-6 type-panel-body`,
    burbuja: 'max-w-130',
  },
}

/** Sin mensajes: qué es, en una línea, y tres preguntas para empezar. */
function ConversacionVacia({
  variante,
  onPreguntar,
}: {
  variante: VarianteDeConversacion
  onPreguntar: (texto: string) => void
}) {
  const centrada = variante === 'pagina'
  return (
    <div className={`flex flex-col gap-4 ${centrada ? 'items-center py-10 text-center' : 'py-2'}`}>
      <div className="flex flex-col gap-1">
        <p className="type-panel-section text-on-surface">¿Qué quieres saber?</p>
        <p className="type-panel-caption text-panel-muted">
          Contesta con las cifras de la base y enlaza la pantalla donde se ven.
        </p>
      </div>
      <SugerenciasDelAsistente onElegir={onPreguntar} className={centrada ? 'justify-center' : ''} />
    </div>
  )
}

/**
 * La conversación con el asistente: el registro de mensajes y el campo de la
 * pregunta. La usan el cajón (`cajon`) y la charla de Inicio (`pagina`); los
 * dos pintan la misma conversación, que vive en `AsistenteProvider`.
 *
 * En `pagina` es una columna de 760 como mucho, centrada, con el campo en
 * píldora anclado abajo. Necesita un padre en columna con el alto acotado:
 * el registro ocupa lo que queda y desplaza por dentro.
 *
 * Lo que llega se anuncia desde una región `log`. Mientras una respuesta se
 * escribe, la región está ocupada (`aria-busy`) y el lector la lee entera al
 * terminar, no palabra a palabra.
 */
export function ConversacionAsistente({
  variante,
  alNavegar,
  vacia,
}: {
  variante: VarianteDeConversacion
  /** Después de seguir un enlace de una respuesta: el cajón a pantalla completa se cierra. */
  alNavegar?: () => void
  /** Lo que se ve sin mensajes. Por defecto, un título y tres sugerencias. */
  vacia?: ReactNode
}) {
  const { preguntar, focoPedido } = useAsistentePanel()
  const { conversacion, borrador, setBorrador } = useConversacionDelAsistente()
  const { mensajes, enviando, consultando, enviar, parar } = conversacion
  const campoRef = useRef<HTMLTextAreaElement>(null)
  const registroRef = useRef<HTMLDivElement>(null)
  const pegadoAbajo = useRef(true)
  const f = FORMA[variante]

  useEffect(() => {
    campoRef.current?.focus()
  }, [focoPedido])

  // Lo nuevo se ve sin bajar a mano, salvo que la persona haya subido a leer.
  useLayoutEffect(() => {
    const registro = registroRef.current
    if (registro && pegadoAbajo.current) registro.scrollTop = registro.scrollHeight
  }, [mensajes])

  const alDesplazar = useCallback(() => {
    const r = registroRef.current
    if (r) pegadoAbajo.current = r.scrollHeight - r.scrollTop - r.clientHeight < MARGEN_DE_PEGADO
  }, [])

  const trasNavegar = useCallback(() => alNavegar?.(), [alNavegar])

  function mandar() {
    pegadoAbajo.current = true
    enviar(borrador)
    setBorrador('')
  }

  const campo = (
    <CampoPregunta
      variante={variante}
      valor={borrador}
      onCambiar={setBorrador}
      onEnviar={mandar}
      onParar={parar}
      enviando={enviando}
      campoRef={campoRef}
      placeholder={variante === 'pagina' && mensajes.length > 0 ? 'Pregunta otra cosa…' : undefined}
    />
  )

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div
        ref={registroRef}
        onScroll={alDesplazar}
        role="log"
        aria-live="polite"
        aria-busy={enviando}
        aria-label="Conversación con el asistente"
        className={`min-h-0 flex-1 overflow-y-auto overscroll-contain ${f.registro}`}
      >
        <div className={`flex flex-col ${f.columna}`}>
          {mensajes.length === 0
            ? (vacia ?? <ConversacionVacia variante={variante} onPreguntar={preguntar} />)
            : mensajes.map((m, i) =>
                m.rol === 'persona' ? (
                  <p
                    key={m.id}
                    // 16/16/6/16: la esquina de abajo, hacia quien habla.
                    className={`ml-auto ${f.burbuja} whitespace-pre-wrap break-words rounded-panel-card rounded-br-md bg-panel-raised px-4 py-3 text-on-surface`}
                  >
                    <span className="sr-only">Tú: </span>
                    {m.texto}
                  </p>
                ) : (
                  <MensajeAsistente
                    key={m.id}
                    mensaje={m}
                    esLaUltima={i === mensajes.length - 1}
                    pregunta={ultimaPregunta(mensajes.slice(0, i))?.texto ?? null}
                    alNavegar={trasNavegar}
                  />
                ),
              )}
        </div>
      </div>

      {/* Fuera del registro ocupado: la consulta en curso sí se anuncia ya. */}
      <p role="status" className="sr-only">
        {consultando ? `${consultando}…` : ''}
      </p>

      {variante === 'pagina' ? (
        <div className="shrink-0 px-4 pb-6 md:px-8">
          <div className={COLUMNA_DE_LA_CHARLA}>{campo}</div>
        </div>
      ) : (
        campo
      )}
    </div>
  )
}
