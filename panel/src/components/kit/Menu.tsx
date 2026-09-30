import { useEffect, useId, useRef, useState } from 'react'
import type { KeyboardEvent, MouseEvent, ReactNode } from 'react'
import { MoreHorizontal } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

import { claseDeBoton } from './clases'
import { Capa, useFlotante } from './flotante'

export type ItemDeMenu = {
  label: string
  icon?: LucideIcon
  onSelect: () => void
  /** Destructiva (bloquear, anular, revertir): en rojo, y con su `ConfirmDialog` detrás. */
  peligro?: boolean
  disabled?: boolean
  /** Por qué no se puede, escrito debajo: un ítem apagado sin motivo es un callejón. */
  motivoApagado?: string
}

/** Los ítems que se recorren con las flechas, en orden. */
function itemsDe(capa: HTMLDivElement | null): Array<HTMLElement> {
  return capa ? Array.from(capa.querySelectorAll<HTMLElement>('[role="menuitem"]')) : []
}

/**
 * El menú «⋯»: las acciones de una ficha que no son la principal.
 *
 * Aquí van las destructivas. Un botón rojo relleno a la vista era lo que más
 * pesaba de toda la ficha, más que lo que se hace cada día; dentro del menú
 * siguen a dos clics y con su confirmación.
 *
 * Se maneja como un menú de sistema: flechas, Inicio y Fin para moverse,
 * Enter para elegir, Escape para cerrar, y Tab sale del menú hacia lo
 * siguiente. Al elegir, el foco vuelve al «⋯», así que el `ConfirmDialog` que
 * abra el ítem devuelve el foco ahí al cerrarse.
 */
export function Menu({
  etiqueta,
  items,
  disparador,
}: {
  /** El nombre del disparador y del menú para el lector de pantalla: «Más acciones». */
  etiqueta: string
  items: ReadonlyArray<ItemDeMenu | 'separador'>
  /** Lo que va dentro del botón. Por defecto, el icono «⋯» solo. */
  disparador?: ReactNode
}) {
  const [abierto, setAbierto] = useState(false)
  const idMenu = useId()
  // Con la flecha arriba se entra por el último, como en un menú de sistema.
  const entrarPor = useRef<'primero' | 'ultimo'>('primero')

  const flotante = useFlotante<HTMLButtonElement>({
    abierto,
    lado: 'abajo',
    alineacion: 'fin',
    separacion: 6,
    alCerrar: () => setAbierto(false),
  })

  // Al abrir, el foco entra en el menú: si se quedara en el botón, las
  // flechas no llegarían a los ítems.
  useEffect(() => {
    if (!abierto) return
    const lista = itemsDe(flotante.capaRef.current)
    const destino = entrarPor.current === 'ultimo' ? lista.at(-1) : lista.at(0)
    destino?.focus({ preventScroll: true })
  }, [abierto, flotante.capaRef])

  function abrir(por: 'primero' | 'ultimo') {
    entrarPor.current = por
    setAbierto(true)
  }

  function alPulsarDisparador(evento: MouseEvent<HTMLButtonElement>) {
    // Puede vivir en una fila que también se pulsa.
    evento.stopPropagation()
    if (abierto) setAbierto(false)
    else abrir('primero')
  }

  function alTeclearDisparador(evento: KeyboardEvent<HTMLButtonElement>) {
    if (evento.key === 'ArrowDown' || evento.key === 'ArrowUp') {
      evento.preventDefault()
      abrir(evento.key === 'ArrowUp' ? 'ultimo' : 'primero')
    }
  }

  function alTeclearMenu(evento: KeyboardEvent<HTMLDivElement>) {
    const lista = itemsDe(flotante.capaRef.current)
    const actual = lista.findIndex((el) => el === document.activeElement)
    const ir = (i: number) => lista.at((i + lista.length) % lista.length)?.focus()

    if (evento.key === 'ArrowDown') ir(actual + 1)
    else if (evento.key === 'ArrowUp') ir(actual < 0 ? -1 : actual - 1)
    else if (evento.key === 'Home') ir(0)
    else if (evento.key === 'End') ir(-1)
    else if (evento.key === 'Tab') {
      // Sin cortar la tecla: el foco vuelve al «⋯» y el Tab del navegador
      // sigue desde ahí hacia lo siguiente, que es donde lo espera quien
      // tabula.
      flotante.anclaRef.current?.focus()
      setAbierto(false)
      return
    } else return

    evento.preventDefault()
  }

  function elegir(item: ItemDeMenu) {
    if (item.disabled) return
    flotante.anclaRef.current?.focus()
    setAbierto(false)
    item.onSelect()
  }

  return (
    <>
      <button
        ref={flotante.anclaRef}
        type="button"
        aria-label={etiqueta}
        aria-haspopup="menu"
        aria-expanded={abierto}
        aria-controls={abierto ? idMenu : undefined}
        onClick={alPulsarDisparador}
        onKeyDown={alTeclearDisparador}
        className={
          disparador === undefined
            ? 'inline-flex size-panel-control-sm shrink-0 items-center justify-center rounded-panel-control bg-panel-control text-on-surface transition-colors duration-[var(--transition-fast)] hover:bg-shell-inset'
            : claseDeBoton('tonal', 'sm')
        }
      >
        {disparador ?? <MoreHorizontal size={16} aria-hidden />}
      </button>

      <Capa
        flotante={flotante}
        abierto={abierto}
        id={idMenu}
        role="menu"
        aria-label={etiqueta}
        aria-orientation="vertical"
        onKeyDown={alTeclearMenu}
        className="anim-globo flex min-w-56 max-w-80 flex-col rounded-panel-card border border-panel-hairline-strong bg-panel-control p-1.5 shadow-2xl"
      >
        {items.map((item, i) =>
          item === 'separador' ? (
            <div
              key={`separador-${i}`}
              role="separator"
              className="mx-1 my-1.5 h-px bg-panel-hairline-strong"
            />
          ) : (
            <ItemDelMenu key={item.label} item={item} alElegir={() => elegir(item)} />
          ),
        )}
      </Capa>
    </>
  )
}

function ItemDelMenu({ item, alElegir }: { item: ItemDeMenu; alElegir: () => void }) {
  const Icono = item.icon
  const color = item.disabled
    ? 'cursor-not-allowed text-panel-muted'
    : item.peligro
      ? 'text-error'
      : 'text-on-surface'

  return (
    <button
      type="button"
      role="menuitem"
      // Fuera del recorrido de Tab: dentro del menú se va con las flechas.
      tabIndex={-1}
      // `aria-disabled` y no `disabled`: un ítem apagado se sigue pudiendo
      // enfocar, que es como el lector de pantalla llega a su motivo.
      aria-disabled={item.disabled || undefined}
      onClick={alElegir}
      // El ratón mueve el foco, así que el resaltado es uno solo aunque se
      // mezclen ratón y flechas.
      onPointerMove={(evento) => evento.currentTarget.focus({ preventScroll: true })}
      className={`flex w-full items-start gap-2.5 rounded-panel-control px-2.5 py-2 text-left transition-colors duration-[var(--transition-fast)] hover:bg-shell-inset focus:bg-shell-inset ${color}`}
    >
      {Icono && <Icono size={15} aria-hidden className="mt-0.5 shrink-0" />}
      <span className="flex min-w-0 flex-col">
        <span className="type-panel-label">{item.label}</span>
        {item.disabled && item.motivoApagado && (
          <span className="type-panel-caption text-panel-muted">{item.motivoApagado}</span>
        )}
      </span>
    </button>
  )
}
