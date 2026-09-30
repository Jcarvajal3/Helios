import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'

import { hayModalAbierto } from '@/components/overlays'
import { useAsistente } from '@/features/admin/asistente/useAsistente'
import type { EstadoAsistente } from '@/features/admin/asistente/useAsistente'
import { asistenteActivo } from '@/lib/asistente'

/** Lo que marca el cajón en el DOM: Ctrl J lo cierra si el foco está dentro. */
export const MARCA_DEL_CAJON = 'data-asistente'

/** Abrir, cerrar y preguntar: lo que usan la barra, la paleta y el marco. */
export type ContextoAsistente = {
  /** Si el cajón está abierto. Con un anfitrión registrado, nunca lo está. */
  abierto: boolean
  abrir: () => void
  cerrar: () => void
  /** El botón de la barra: abre o cierra. */
  alternar: () => void
  /** Hace la pregunta y enseña la conversación. La usa la paleta. */
  preguntar: (texto: string) => void
  /** Vacía la conversación y lo escrito, y lleva el foco al campo. */
  nuevaConversacion: () => void
  /** Cambia cada vez que alguien pide llevar el foco al campo de la pregunta. */
  focoPedido: number
}

/** La conversación y lo escrito en el campo: solo lo usa quien la pinta. */
export type ConversacionDelAsistente = {
  conversacion: EstadoAsistente
  /** Lo que hay escrito en el campo, que sobrevive a cerrar el cajón. */
  borrador: string
  setBorrador: (texto: string) => void
}

/**
 * Una pantalla que se ofrece como sitio de la charla (Inicio). Mientras está
 * registrada, preguntar, abrir, Ctrl J y el botón de la barra llaman a
 * `mostrar` en vez de abrir el cajón.
 *
 * `texto` llega cuando se acaba de hacer una pregunta: ya está enviada (o
 * esperando en el campo si había otra respuesta llegando), así que el
 * anfitrión no la reenvía; solo pasa a enseñar la conversación. Sin texto es
 * «trae el asistente»: el anfitrión decide dónde poner el foco.
 */
export type AnfitrionDeCharla = { mostrar: (texto?: string) => void }

type RegistrarAnfitrion = (anfitrion: AnfitrionDeCharla) => () => void

const Control = createContext<ContextoAsistente | null>(null)
const Conversacion = createContext<ConversacionDelAsistente | null>(null)
const Registro = createContext<RegistrarAnfitrion | null>(null)

/**
 * El asistente del super admin, para todo el panel.
 *
 * La conversación vive aquí y no en el cajón: cerrarlo no para la respuesta
 * que está llegando ni borra lo escrito, y al volver a abrirlo sigue donde
 * estaba. Se abre con el botón de la barra de arriba, desde la paleta o con
 * Ctrl J (⌘J en Mac), que en el panel no usa nadie más; con otra ventana
 * abierta, el atajo no hace nada.
 *
 * Son tres contextos a propósito: la respuesta llega a trozos, decenas de
 * veces por segundo, y con uno solo el marco entero (menú, barra) se volvería
 * a pintar con cada trozo. Así solo se repinta quien pinta la conversación.
 * El anfitrión se guarda en una referencia por lo mismo: registrarlo no
 * cambia nada que el marco lea.
 */
export function AsistenteProvider({ children }: { children: ReactNode }) {
  const conversacion = useAsistente()
  const [abierto, setAbierto] = useState(false)
  const [focoPedido, setFocoPedido] = useState(0)
  const [borrador, setBorrador] = useState('')
  const anfitrion = useRef<AnfitrionDeCharla | null>(null)

  // La última conversación, para que `preguntar` no cambie con cada trozo.
  const ultima = useRef(conversacion)
  useEffect(() => {
    ultima.current = conversacion
  })

  const pedirFoco = useCallback(() => setFocoPedido((n) => n + 1), [])

  /** Enseña la conversación: en el anfitrión si lo hay, si no en el cajón. */
  const mostrar = useCallback(
    (texto?: string) => {
      if (anfitrion.current) anfitrion.current.mostrar(texto)
      else setAbierto(true)
      pedirFoco()
    },
    [pedirFoco],
  )

  const abrir = useCallback(() => mostrar(), [mostrar])
  const cerrar = useCallback(() => setAbierto(false), [])
  const alternar = useCallback(() => {
    if (anfitrion.current) {
      mostrar()
      return
    }
    setAbierto((a) => !a)
    pedirFoco()
  }, [mostrar, pedirFoco])

  const preguntar = useCallback(
    (texto: string) => {
      // Con una respuesta llegando no se pisa: la pregunta espera en el campo.
      if (ultima.current.enviando) setBorrador(texto)
      else ultima.current.enviar(texto)
      mostrar(texto)
    },
    [mostrar],
  )

  const nuevaConversacion = useCallback(() => {
    ultima.current.nueva()
    setBorrador('')
    pedirFoco()
  }, [pedirFoco])

  const registrar = useCallback<RegistrarAnfitrion>((a) => {
    anfitrion.current = a
    // Donde hay anfitrión la charla vive en su página: el cajón al lado sobraría.
    setAbierto(false)
    return () => {
      if (anfitrion.current === a) anfitrion.current = null
    }
  }, [])

  useEffect(() => {
    // Sin asistente (`VITE_ASISTENTE`), Ctrl J vuelve a ser del navegador.
    if (!asistenteActivo()) return
    function alTeclear(evento: KeyboardEvent) {
      if (!(evento.ctrlKey || evento.metaKey) || evento.altKey || evento.shiftKey) return
      if (evento.key.toLowerCase() !== 'j' || evento.isComposing) return
      // En el navegador Ctrl J abre las descargas: dentro del panel manda el asistente.
      evento.preventDefault()
      if (hayModalAbierto()) return
      const dentro = document.activeElement?.closest(`[${MARCA_DEL_CAJON}]`)
      if (abierto && dentro) cerrar()
      else abrir()
    }
    document.addEventListener('keydown', alTeclear)
    return () => document.removeEventListener('keydown', alTeclear)
  }, [abierto, abrir, cerrar])

  const control = useMemo(
    () => ({ abierto, abrir, cerrar, alternar, preguntar, nuevaConversacion, focoPedido }),
    [abierto, abrir, cerrar, alternar, preguntar, nuevaConversacion, focoPedido],
  )
  const charla = useMemo(() => ({ conversacion, borrador, setBorrador }), [conversacion, borrador])

  return (
    <Registro.Provider value={registrar}>
      <Control.Provider value={control}>
        <Conversacion.Provider value={charla}>{children}</Conversacion.Provider>
      </Control.Provider>
    </Registro.Provider>
  )
}

/** Abrir, cerrar o preguntar. Solo existe dentro del super admin. */
export function useAsistentePanel(): ContextoAsistente {
  const c = useContext(Control)
  if (!c) throw new Error('useAsistentePanel necesita un <AsistenteProvider> por encima.')
  return c
}

/** La conversación, para quien la pinta: el cajón o el anfitrión. */
export function useConversacionDelAsistente(): ConversacionDelAsistente {
  const c = useContext(Conversacion)
  if (!c) throw new Error('useConversacionDelAsistente necesita un <AsistenteProvider> por encima.')
  return c
}

function useRegistroDeAnfitrion(): RegistrarAnfitrion {
  const r = useContext(Registro)
  if (!r) throw new Error('useAnfitrionDeCharla necesita un <AsistenteProvider> por encima.')
  return r
}

/**
 * Ofrece la pantalla como sitio de la charla mientras esté montada: preguntar
 * y abrir la traen aquí en vez de abrir el cajón. Al desmontar (o con `null`)
 * se retira, y todo vuelve al cajón.
 *
 * El objeto puede crearse en cada render: se llama siempre al último, y solo
 * se registra de nuevo cuando pasa de haber anfitrión a no haberlo.
 */
export function useAnfitrionDeCharla(anfitrion: AnfitrionDeCharla | null): void {
  const registrar = useRegistroDeAnfitrion()
  const actual = useRef(anfitrion)
  useEffect(() => {
    actual.current = anfitrion
  })

  const hay = anfitrion !== null
  useEffect(() => {
    if (!hay) return
    return registrar({ mostrar: (texto) => actual.current?.mostrar(texto) })
  }, [hay, registrar])
}
