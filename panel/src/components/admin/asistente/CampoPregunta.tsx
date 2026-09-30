import { useEffect, useId, useRef } from 'react'
import type { FormEvent, KeyboardEvent, RefObject } from 'react'
import { ArrowUp, Square } from 'lucide-react'

import { Tecla } from '@/components/ui'

/** Lo más alto que crece el campo antes de desplazarse por dentro. */
const ALTO_MAXIMO = 160

/**
 * Dónde vive el campo: `cajon`, al pie del cajón lateral; `pagina`, la
 * píldora anclada abajo en la charla de Inicio.
 */
export type VarianteDelCampo = 'cajon' | 'pagina'

const FORMA: Record<
  VarianteDelCampo,
  { form: string; caja: string; campo: string; boton: string; apagado: string; parar: string }
> = {
  cajon: {
    form: 'shrink-0 border-t border-panel-hairline p-3',
    caja: 'gap-2 rounded-panel-control bg-panel-control py-1.5 pl-3 pr-1.5',
    campo: 'min-h-9 py-2 type-panel-body',
    boton: 'size-9 rounded-panel-control',
    apagado: 'text-panel-muted',
    parar: 'bg-panel-raised hover:bg-panel-card',
  },
  pagina: {
    form: 'shrink-0',
    // 58 de alto: 8 arriba, el botón de 42 y 8 abajo. Con más de una línea
    // la píldora pasa al radio de la tarjeta héroe, o el texto chocaría con
    // la curva.
    caja: 'gap-3 rounded-full bg-panel-card py-2 pl-5.5 pr-2 shadow-2xl data-varias:rounded-panel-hero',
    campo: 'min-h-10.5 py-2.25 type-panel-body',
    boton: 'size-10.5 rounded-full',
    apagado: 'bg-panel-control text-panel-muted',
    parar: 'bg-panel-control hover:bg-panel-raised',
  },
}

/**
 * El campo de la pregunta. Enter manda, Shift+Enter hace un salto de línea;
 * mientras llega una respuesta, el botón de enviar pasa a «Parar».
 *
 * Crece con lo escrito hasta un tope, como en cualquier chat: una pregunta
 * larga se relee entera antes de mandarla. El botón de enviar es gris
 * mientras no hay nada que mandar y lima cuando lo hay: es la acción de la
 * pantalla solo cuando se puede hacer.
 */
export function CampoPregunta({
  valor,
  onCambiar,
  onEnviar,
  onParar,
  enviando,
  campoRef,
  variante = 'cajon',
  placeholder = 'Pregunta por una cifra, una clínica o un paciente',
}: {
  valor: string
  onCambiar: (texto: string) => void
  onEnviar: () => void
  onParar: () => void
  enviando: boolean
  campoRef: RefObject<HTMLTextAreaElement | null>
  variante?: VarianteDelCampo
  placeholder?: string
}) {
  const id = useId()
  const ayuda = `${id}-ayuda`
  const vacio = valor.trim() === ''
  const cajaRef = useRef<HTMLDivElement>(null)
  const f = FORMA[variante]

  useEffect(() => {
    const campo = campoRef.current
    if (!campo) return
    campo.style.height = 'auto'
    // Con la altura automática el campo mide una fila: lo que sobra por
    // abajo es la segunda línea.
    cajaRef.current?.toggleAttribute('data-varias', campo.scrollHeight > campo.clientHeight)
    campo.style.height = `${Math.min(campo.scrollHeight, ALTO_MAXIMO)}px`
  }, [valor, campoRef])

  function alTeclear(evento: KeyboardEvent<HTMLTextAreaElement>) {
    if (evento.key !== 'Enter' || evento.shiftKey || evento.nativeEvent.isComposing) return
    evento.preventDefault()
    if (!enviando && !vacio) onEnviar()
  }

  function alMandar(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault()
    if (!enviando && !vacio) onEnviar()
  }

  return (
    <form onSubmit={alMandar} className={f.form}>
      <div
        ref={cajaRef}
        // El foco se marca en la caja entera y no en el campo de dentro, que
        // es solo una parte de lo que se ve como campo.
        className={`flex items-end border border-panel-hairline transition-colors duration-[var(--transition-fast)] focus-within:border-primary ${f.caja}`}
      >
        <label htmlFor={id} className="sr-only">
          Pregunta para el asistente
        </label>
        <textarea
          ref={campoRef}
          id={id}
          rows={1}
          value={valor}
          onChange={(e) => onCambiar(e.target.value)}
          onKeyDown={alTeclear}
          aria-describedby={ayuda}
          placeholder={placeholder}
          // `!`: el anillo global de :focus-visible va sin capa y ganaría a un
          // `outline-none` normal; aquí lo lleva la caja.
          className={`min-w-0 flex-1 resize-none bg-transparent text-on-surface outline-none! placeholder:text-placeholder ${f.campo}`}
        />
        {enviando ? (
          <button
            type="button"
            onClick={onParar}
            aria-label="Parar la respuesta"
            className={`inline-flex shrink-0 items-center justify-center text-on-surface transition-colors duration-[var(--transition-fast)] ${f.boton} ${f.parar}`}
          >
            <Square size={14} aria-hidden fill="currentColor" />
          </button>
        ) : (
          <button
            type="submit"
            disabled={vacio}
            aria-label="Enviar la pregunta"
            className={`inline-flex shrink-0 items-center justify-center transition-colors duration-[var(--transition-fast)] ${f.boton} ${
              vacio ? f.apagado : 'bg-primary text-on-primary hover:bg-primary-bright'
            }`}
          >
            <ArrowUp size={variante === 'pagina' ? 18 : 16} aria-hidden />
          </button>
        )}
      </div>
      {variante === 'pagina' ? (
        <p id={ayuda} className="mt-2.5 text-center type-panel-caption text-panel-muted">
          Lee las cifras de la base en el momento. No cambia nada.
        </p>
      ) : (
        <p
          id={ayuda}
          className="mt-2 hidden flex-wrap items-center gap-x-3 gap-y-1 type-panel-caption text-panel-muted md:flex"
        >
          <span className="inline-flex items-center gap-1">
            <Tecla>Enter</Tecla> para enviar
          </span>
          <span className="inline-flex items-center gap-1">
            <Tecla>Shift</Tecla>
            <Tecla>Enter</Tecla> para un salto de línea
          </span>
          <span className="inline-flex items-center gap-1">
            <Tecla>Esc</Tecla> para cerrar
          </span>
        </p>
      )}
    </form>
  )
}
