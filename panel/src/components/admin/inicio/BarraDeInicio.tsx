import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
import type { FocusEvent, FormEvent, KeyboardEvent, RefObject } from 'react'
import { ArrowUp, Search } from 'lucide-react'

import { useAsistentePanel } from '@/components/admin/asistente'
import { useAtajoDePaleta, useCapturaDelAtajo } from '@/components/admin/paleta'
import { useEsMac } from '@/components/admin/paleta/teclado'
import { usePaleta } from '@/components/admin/paleta/usePaleta'
import { Capa, useFlotante } from '@/components/kit/flotante'
import { Tecla } from '@/components/ui'
import { ResultadosDeLaBarra } from './ResultadosDeLaBarra'

/** El ancho de un elemento mientras `activo`, para que los resultados midan lo que la barra. */
function useAnchoDe(ref: RefObject<HTMLElement | null>, activo: boolean): number | undefined {
  const [ancho, setAncho] = useState<number>()
  useLayoutEffect(() => {
    const el = ref.current
    if (!activo || !el) return
    const medir = () => setAncho(el.offsetWidth)
    medir()
    const observador = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(medir)
    observador?.observe(el)
    return () => observador?.disconnect()
  }, [ref, activo])
  return ancho
}

/**
 * La barra de Inicio: pregunta y busca a la vez.
 *
 * Al escribir, debajo salen los resultados de la paleta (personas, locales,
 * pantallas, un número de orden…), y «Preguntarle al asistente» va el primero
 * si lo escrito parece una pregunta. Flechas para moverse y Enter para elegir:
 * un resultado lleva a su ficha y la pregunta se le hace al asistente, que
 * convierte Inicio en la conversación. El botón redondo siempre pregunta.
 *
 * En Inicio no hay buscador en la barra de arriba, así que Ctrl K (⌘K) trae
 * el foco aquí.
 */
export function BarraDeInicio({ conAsistente }: { conAsistente: boolean }) {
  const { preguntar } = useAsistentePanel()
  // Lo cerró la persona (Escape, un clic fuera, al elegir). Se reabre al escribir.
  const [cerrada, setCerrada] = useState(false)
  const p = usePaleta({
    onCerrar: () => setCerrada(true),
    // Sin asistente, la barra solo busca: no hay «Preguntarle al asistente».
    onPreguntar: conAsistente ? preguntar : undefined,
  })
  const hayTexto = p.texto.trim() !== ''
  const abierta = hayTexto && !cerrada

  const flotante = useFlotante<HTMLDivElement>({ abierto: abierta, alCerrar: () => setCerrada(true) })
  const ancho = useAnchoDe(flotante.anclaRef, abierta)
  const campoRef = useRef<HTMLInputElement>(null)
  const esMac = useEsMac()
  const atajo = useAtajoDePaleta()

  const base = useId()
  const idCampo = `${base}-campo`
  const idLista = `${base}-lista`
  const idDe = (clave: string) => `${base}-opcion-${clave}`
  const idActiva = abierta && p.activa ? idDe(p.activa.clave) : undefined

  // La señalada, siempre a la vista: con las flechas se puede bajar más allá de lo que cabe.
  useEffect(() => {
    if (idActiva) document.getElementById(idActiva)?.scrollIntoView({ block: 'nearest' })
  }, [idActiva])

  // Aquí Ctrl K no abre la ventana de la paleta: trae el foco a esta barra,
  // que ya es el buscador. `abrirPaleta()` sí la sigue abriendo.
  const enfocar = useCallback(() => {
    campoRef.current?.focus()
    campoRef.current?.select()
  }, [])
  useCapturaDelAtajo(enfocar)

  function cambiar(texto: string) {
    p.cambiarTexto(texto)
    setCerrada(false)
  }

  function alTeclear(evento: KeyboardEvent<HTMLInputElement>) {
    if (evento.nativeEvent.isComposing) return
    // Abierta, las flechas, Enter y Tab son de la lista (Escape lo atiende la capa).
    if (abierta) {
      p.alTeclear(evento)
      return
    }
    if ((evento.key === 'ArrowDown' || evento.key === 'ArrowUp') && hayTexto) {
      evento.preventDefault()
      setCerrada(false)
    } else if (evento.key === 'Escape' && p.texto !== '') {
      evento.preventDefault()
      cambiar('')
    }
  }

  function alSalir(evento: FocusEvent<HTMLInputElement>) {
    const destino = evento.relatedTarget
    if (destino instanceof Node && flotante.capaRef.current?.contains(destino)) return
    setCerrada(true)
  }

  // Con la lista cerrada, Enter llega aquí; y el botón redondo, siempre.
  function mandar(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault()
    const texto = p.texto.trim()
    if (texto === '') return
    // Sin asistente, Enter con la lista cerrada la vuelve a abrir.
    if (!conAsistente) {
      setCerrada(false)
      return
    }
    setCerrada(true)
    preguntar(texto)
  }

  return (
    <form role="search" onSubmit={mandar} className="w-full">
      <div
        ref={flotante.anclaRef}
        // El foco se marca en la píldora entera, no en el campo de dentro.
        className="flex h-16 items-center gap-3 rounded-full border border-panel-hairline-strong bg-panel-card pl-5.5 pr-2.5 shadow-2xl transition-colors duration-(--transition-fast) focus-within:border-primary"
      >
        <Search size={20} aria-hidden className="shrink-0 text-panel-muted" />
        <label htmlFor={idCampo} className="sr-only">
          {conAsistente ? 'Pregunta o busca en el panel' : 'Busca en el panel'}
        </label>
        <input
          ref={campoRef}
          id={idCampo}
          type="text"
          role="combobox"
          aria-autocomplete="list"
          aria-expanded={abierta}
          aria-controls={abierta ? idLista : undefined}
          aria-activedescendant={idActiva}
          aria-keyshortcuts={esMac ? 'Meta+K' : 'Control+K'}
          autoComplete="off"
          spellCheck={false}
          value={p.texto}
          onChange={(e) => cambiar(e.target.value)}
          onKeyDown={alTeclear}
          onFocus={() => setCerrada(false)}
          onBlur={alSalir}
          placeholder={
            conAsistente
              ? 'Pregunta por una cifra, una clínica o un paciente'
              : 'Busca un paciente, una clínica o una pantalla'
          }
          // `!`: el anillo global de :focus-visible va sin capa; aquí lo lleva la píldora.
          className="h-10 min-w-0 flex-1 bg-transparent type-panel-body text-on-surface outline-none! placeholder:text-placeholder"
        />
        <span className="hidden md:inline-flex">
          <Tecla>{atajo}</Tecla>
        </span>
        {conAsistente && (
        <button
          type="submit"
          disabled={!hayTexto}
          aria-label="Preguntarle al asistente"
          // Lima solo con algo que preguntar: es la acción cuando se puede hacer.
          className={`inline-flex size-11 shrink-0 items-center justify-center rounded-full transition-colors duration-(--transition-fast) ${
            hayTexto ? 'bg-primary text-on-primary hover:bg-primary-bright' : 'bg-panel-control text-panel-muted'
          }`}
        >
          <ArrowUp size={18} aria-hidden />
        </button>
        )}
      </div>

      <Capa
        flotante={flotante}
        abierto={abierta}
        style={{ width: ancho }}
        className="anim-globo overflow-hidden rounded-panel-card border border-panel-hairline-strong bg-panel-card shadow-2xl"
      >
        <ResultadosDeLaBarra
          paleta={p}
          idBase={base}
          idLista={idLista}
          idDe={idDe}
          conAsistente={conAsistente}
        />
      </Capa>

      {/* Lo que oye quien usa lector de pantalla al terminar de buscar. */}
      <p role="status" className="sr-only">
        {abierta ? p.anuncio : ''}
      </p>
    </form>
  )
}
