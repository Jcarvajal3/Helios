import { Menu } from 'lucide-react'
import type { ReactNode } from 'react'

/**
 * La barra de arriba: el título de la pantalla, el buscador (Ctrl K), el
 * asistente y la acción de la pantalla, en ese orden.
 *
 * Antes el título de la pantalla vivía dentro del scroll, en `ContentHeader`,
 * y a la fila sesenta de una tabla ya no se sabía en qué pestaña estabas ni
 * quedaba a mano la acción principal. Ahora el título sale de `staticData` de
 * la ruta y lo pinta el marco: una pantalla no puede olvidarse de decir dónde
 * está, porque ya no es cosa suya.
 *
 * El logo no está aquí, ni el botón que pliega el menú: los dos viven en la
 * cabecera del menú, que es donde se ven.
 *
 * `inmersiva` (Inicio): la pantalla es su propia cabecera. De la barra queda
 * solo el botón que abre el menú por debajo de 1024 px; de ahí para arriba
 * no queda nada, ni siquiera el alto.
 */
export function Topbar({
  title,
  search,
  asistente,
  inmersiva,
  onAbrirCajon,
  slotRef,
}: {
  title: string
  /**
   * La paleta de búsqueda (Ctrl K). Solo la pasa el super admin. Se pinta
   * ella misma según el ancho: campo desde 768 px y lupa por debajo.
   */
  search?: ReactNode
  /** El botón del asistente, junto a la paleta. Solo lo pasa el super admin. */
  asistente?: ReactNode
  inmersiva: boolean
  onAbrirCajon: () => void
  /** Dónde cuelgan su acción las pantallas, vía `PageAction`. */
  slotRef: (nodo: HTMLDivElement | null) => void
}) {
  if (inmersiva) {
    return (
      <header className="sticky top-0 z-20 flex h-(--topbar-height) shrink-0 items-center bg-shell-canvas/90 px-4 backdrop-blur lg:hidden">
        <AbrirMenu onClick={onAbrirCajon} />
      </header>
    )
  }

  return (
    <header className="sticky top-0 z-20 flex h-(--topbar-height) shrink-0 items-center gap-3 border-b border-panel-hairline bg-shell-canvas/90 px-4 backdrop-blur lg:px-8">
      <AbrirMenu onClick={onAbrirCajon} />

      <h1 className="type-panel-page min-w-0 shrink truncate text-on-surface">{title}</h1>

      <div className="flex min-w-0 flex-1 items-center justify-end gap-3">
        {/* Compacto a propósito, 340 como mucho: busca en TODO el panel, y si
            midiera lo mismo que el buscador de una lista, en Consumos habría
            dos cajas iguales en la misma pantalla y nadie sabría cuál teclear.
            Por debajo de 768 px queda la lupa. */}
        {search && <div className="flex min-w-0 md:max-w-85 md:flex-1">{search}</div>}
        {asistente}
        <div ref={slotRef} className="flex shrink-0 items-center gap-2" />
      </div>
    </header>
  )
}

/** Por debajo de lg la barra lateral es un cajón y esto la abre. */
function AbrirMenu({ onClick }: { onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label="Abrir el menú"
      className="inline-flex size-10 shrink-0 items-center justify-center rounded-panel-control text-on-surface-variant transition-colors duration-(--transition-fast) hover:bg-panel-raised hover:text-on-surface lg:hidden"
    >
      <Menu size={18} aria-hidden />
    </button>
  )
}
