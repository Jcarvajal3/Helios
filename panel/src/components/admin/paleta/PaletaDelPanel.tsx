import { useCallback, useEffect, useState } from 'react'
import { Search } from 'lucide-react'

import { hayModalAbierto } from '@/components/overlays'
import { Tecla } from '@/components/ui'
import { Paleta } from './Paleta'
import type { SiNoHayNada } from './Paleta'
import { useEsMac } from './teclado'

/** El aviso con el que otra parte del panel pide abrir la paleta. */
const EVENTO_ABRIR = 'helios-panel:abrir-paleta'

/**
 * Abre la paleta desde fuera, con `texto` ya escrito si llega: lo usan el
 * asistente («Buscar en el panel» con la pregunta que no pudo contestar) y
 * cualquier botón que quiera llevar a buscar. Es un evento y no un estado
 * compartido porque la paleta vive montada una sola vez, en el marco. Si ya está abierta, se queda como está.
 */
export function abrirPaleta(texto?: string): void {
  // Pasada tal cual como `onClick`, lo que llega es el evento del clic y no
  // un texto: se abre vacía.
  const detail = typeof texto === 'string' ? texto : ''
  window.dispatchEvent(new CustomEvent<string>(EVENTO_ABRIR, { detail }))
}

/** El atajo tal como se lee en este sistema: «⌘K» en un Mac, «Ctrl K» en el resto. */
export function useAtajoDePaleta(): string {
  return useEsMac() ? '⌘K' : 'Ctrl K'
}

/**
 * Quién se queda el atajo Ctrl K en vez de la paleta, si alguien lo pide.
 *
 * Inicio no tiene buscador en la barra de arriba: su barra grande ya es el
 * buscador, así que ahí Ctrl K lleva el foco a esa barra y no abre la
 * ventana. Es una pila y no un valor suelto para que, si dos piezas lo piden
 * a la vez, al desmontarse una mande la anterior y no la paleta.
 */
const capturas: Array<() => void> = []

/**
 * Mientras el componente esté montado, Ctrl K llama a `alPulsar` en vez de
 * abrir la paleta. `abrirPaleta()` la sigue abriendo: lo pide alguien que
 * quiere la ventana, no el atajo.
 */
export function useCapturaDelAtajo(alPulsar: (() => void) | null): void {
  useEffect(() => {
    if (!alPulsar) return
    capturas.push(alPulsar)
    return () => {
      const i = capturas.lastIndexOf(alPulsar)
      if (i >= 0) capturas.splice(i, 1)
    }
  }, [alPulsar])
}

/**
 * La paleta del super admin: el atajo, la ventana y los avisos para abrirla.
 *
 * Contesta la pregunta con la que empieza casi toda llamada («me da un
 * teléfono, una cédula, una referencia») y lleva a cualquier pantalla o
 * acción por su nombre, sin saber en qué equipo vive.
 *
 * Se abre con Ctrl K (⌘K en Mac) desde cualquier pantalla, con el botón de la
 * barra de arriba (`BuscadorDeLaBarra`) o con `abrirPaleta()`. Vive aparte
 * del botón porque hay pantallas sin barra de arriba —Inicio— y la ventana
 * tiene que poder abrirse igual. Con otra ventana abierta el atajo no hace
 * nada: saltar de pantalla desde encima de un formulario a medias se llevaría
 * lo escrito. Con la paleta abierta, el mismo atajo la cierra.
 */
export function PaletaDelPanel({
  siNoHayNada,
  onPreguntar,
}: {
  siNoHayNada?: SiNoHayNada
  /** Lleva lo tecleado al asistente: la paleta pasa a «Buscar o preguntar». */
  onPreguntar?: (texto: string) => void
}) {
  // `null`: cerrada. Abierta, con lo que había que dejar escrito al abrirla.
  const [abierta, setAbierta] = useState<{ texto: string } | null>(null)
  const cerrar = useCallback(() => setAbierta(null), [])

  useEffect(() => {
    function alTeclear(evento: KeyboardEvent) {
      if (!(evento.ctrlKey || evento.metaKey) || evento.altKey || evento.shiftKey) return
      if (evento.key.toLowerCase() !== 'k' || evento.isComposing) return
      // Siempre se lo queda el panel: en el navegador Ctrl K lleva a la barra
      // de direcciones, y a medio trabajo eso es perder el sitio.
      evento.preventDefault()
      if (abierta) {
        setAbierta(null)
        return
      }
      if (hayModalAbierto()) return
      const captura = capturas.at(-1)
      if (captura) captura()
      else setAbierta({ texto: '' })
    }
    document.addEventListener('keydown', alTeclear)
    return () => document.removeEventListener('keydown', alTeclear)
  }, [abierta])

  useEffect(() => {
    function alPedir(evento: Event) {
      const texto = evento instanceof CustomEvent && typeof evento.detail === 'string' ? evento.detail : ''
      setAbierta((a) => a ?? { texto })
    }
    window.addEventListener(EVENTO_ABRIR, alPedir)
    return () => window.removeEventListener(EVENTO_ABRIR, alPedir)
  }, [])

  if (!abierta) return null
  return (
    <Paleta
      onCerrar={cerrar}
      siNoHayNada={siNoHayNada}
      onPreguntar={onPreguntar}
      textoInicial={abierta.texto}
    />
  )
}

/**
 * El botón de la barra de arriba que abre la paleta. Tiene aspecto de campo
 * porque es donde la gente busca; debajo de 768 px queda solo la lupa, que
 * cabe al lado del título.
 */
export function BuscadorDeLaBarra({ conAsistente = false }: { conAsistente?: boolean }) {
  const esMac = useEsMac()
  const atajo = useAtajoDePaleta()
  const rotulo = conAsistente ? 'Buscar o preguntar' : 'Buscar o ir a'
  const abrir = () => abrirPaleta()

  return (
    <>
      <button
        type="button"
        onClick={abrir}
        aria-haspopup="dialog"
        aria-keyshortcuts={esMac ? 'Meta+K' : 'Control+K'}
        className="hidden h-panel-control-md w-full min-w-0 items-center gap-2.5 rounded-panel-control border border-panel-hairline bg-panel-card px-3 text-left text-panel-muted transition-colors duration-[var(--transition-fast)] hover:bg-panel-raised md:flex"
      >
        <Search size={16} aria-hidden className="shrink-0" />
        <span className="min-w-0 flex-1 truncate type-panel-body">{rotulo}…</span>
        <Tecla>{atajo}</Tecla>
      </button>

      <button
        type="button"
        onClick={abrir}
        aria-haspopup="dialog"
        aria-label={rotulo}
        aria-keyshortcuts={esMac ? 'Meta+K' : 'Control+K'}
        className="inline-flex size-panel-control-md shrink-0 items-center justify-center rounded-panel-control text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:bg-panel-raised hover:text-on-surface md:hidden"
      >
        <Search size={18} aria-hidden />
      </button>
    </>
  )
}
