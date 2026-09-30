import { createContext, useContext, useEffect } from 'react'
import { createPortal } from 'react-dom'
import type { ReactNode } from 'react'

/**
 * El hueco de la topbar donde una pantalla cuelga SU acción.
 *
 * El problema que resuelve: el título dejó de vivir dentro del scroll y pasó
 * a la barra de arriba, pero la acción principal de una pantalla —"Añadir
 * comercio"— es de la pantalla, no del marco. Sin un hueco, o el shell tiene
 * que conocer las veinticinco pantallas, o la acción se queda enterrada en el
 * contenido, que es de donde la sacamos.
 *
 * Se hace con un portal y no pasando JSX por props porque la acción suele
 * necesitar el estado de la pantalla —abrir un modal, saber si hay una
 * selección—, y subirlo hasta la ruta padre para volver a bajarlo es la clase
 * de cableado que después nadie se atreve a tocar.
 *
 * En el servidor no hay nodo donde portar, así que no sale en el HTML y
 * aparece al hidratar. Es un botón: entra un fotograma después y nadie lo
 * nota. El título, que sí importa que salga de una, viaja por `staticData` y
 * se pinta en el servidor.
 */
const Hueco = createContext<HTMLElement | null>(null)

export function PageActionProvider({
  nodo,
  children,
}: {
  nodo: HTMLElement | null
  children: ReactNode
}) {
  return <Hueco.Provider value={nodo}>{children}</Hueco.Provider>
}

/**
 * Cuelga su contenido en la topbar. Se usa dentro de una pantalla, en
 * cualquier punto del árbol:
 *
 *     <PageAction>
 *       <Button size="sm" onClick={() => setAbierto(true)}>Añadir comercio</Button>
 *     </PageAction>
 */
export function PageAction({ children }: { children: ReactNode }) {
  const nodo = useContext(Hueco)
  if (!nodo) return null
  return createPortal(children, nodo)
}

// ── El título cuando no es estático ──────────────────────────────────────

/**
 * Una página de detalle no puede declarar su título en `staticData`: el
 * título es el nombre de la persona, y eso llega con la consulta. Esto deja
 * que la pantalla lo diga cuando lo sabe. Hasta entonces la barra enseña el
 * de la ruta —«Persona»—, así que nunca está vacía.
 */
const Titulo = createContext<(titulo: string | null) => void>(() => {})

export function PageTitleProvider({
  onChange,
  children,
}: {
  onChange: (titulo: string | null) => void
  children: ReactNode
}) {
  return <Titulo.Provider value={onChange}>{children}</Titulo.Provider>
}

/** Pone el título de la barra mientras el componente esté montado. */
export function usePageTitle(titulo: string | null) {
  const poner = useContext(Titulo)
  useEffect(() => {
    poner(titulo)
    return () => poner(null)
  }, [titulo, poner])
}
