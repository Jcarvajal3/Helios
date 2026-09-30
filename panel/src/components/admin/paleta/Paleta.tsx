import { useEffect, useId, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { Search } from 'lucide-react'

import { Modal } from '@/components/overlays'
import { GrupoPaleta } from './GrupoPaleta'
import { AyudaDeTeclado, useEsMac } from './teclado'
import { usePaleta } from './usePaleta'
import type { Consulta } from './consulta'

/**
 * Lo que se ofrece cuando la búsqueda no encuentra nada, además del aviso.
 *
 * Es el punto de extensión del asistente (fase 6): recibe la consulta ya
 * interpretada y pinta su propia salida debajo de «Nada con…».
 */
export type SiNoHayNada = (consulta: Consulta) => ReactNode

/**
 * La ventana de la paleta.
 *
 * Es el `Modal` del kit, así que comparte la pila con las demás ventanas:
 * Escape cierra solo la de arriba, Tab no sale de ella y el foco vuelve a
 * quien la abrió. Va a `document.body` con un portal porque la barra de arriba
 * lleva `backdrop-blur`, y un filtro convierte al elemento en el marco de todo
 * lo `fixed` que tenga dentro: montada ahí, la ventana ocuparía la barra y no
 * la pantalla.
 *
 * Sin encabezado: el buscador ya dice qué es la ventana, y el título solo
 * queda para el lector de pantalla.
 */
export function Paleta({
  onCerrar,
  siNoHayNada,
  onPreguntar,
  textoInicial = '',
}: {
  onCerrar: () => void
  siNoHayNada?: SiNoHayNada
  /** Con esto, lo tecleado también se le puede preguntar al asistente. */
  onPreguntar?: (texto: string) => void
  /** Lo que ya viene escrito al abrir. Llega seleccionado: se cambia tecleando. */
  textoInicial?: string
}) {
  const p = usePaleta({ onCerrar, onPreguntar, textoInicial })
  const conAsistente = onPreguntar !== undefined
  const esMac = useEsMac()
  const campoRef = useRef<HTMLInputElement>(null)

  // Después de que la ventana ponga el foco en el campo (su efecto va antes
  // que este): lo que venía escrito queda seleccionado.
  const [conTextoInicial] = useState(textoInicial !== '')
  useEffect(() => {
    if (conTextoInicial) campoRef.current?.select()
  }, [conTextoInicial])

  const base = useId()
  const idLista = `${base}-lista`
  const idDe = (clave: string) => `${base}-opcion-${clave}`
  const idActiva = p.activa ? idDe(p.activa.clave) : undefined

  // La señalada, siempre a la vista: con las flechas se puede bajar más allá
  // de lo que cabe.
  useEffect(() => {
    if (idActiva) document.getElementById(idActiva)?.scrollIntoView({ block: 'nearest' })
  }, [idActiva])

  const hayGrupos = p.grupos.length > 0

  return createPortal(
    <Modal title={conAsistente ? 'Buscar o preguntar' : 'Buscar o ir a'} onClose={onCerrar} sinEncabezado>
      <div className="flex flex-col gap-3">
        <div className="relative">
          <Search
            size={16}
            aria-hidden
            className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-on-surface-variant"
          />
          <input
            ref={campoRef}
            data-autofocus
            type="text"
            role="combobox"
            aria-label={conAsistente ? 'Buscar en el panel o preguntar al asistente' : 'Buscar en el panel'}
            aria-autocomplete="list"
            aria-expanded={hayGrupos}
            aria-controls={idLista}
            aria-activedescendant={idActiva}
            autoComplete="off"
            spellCheck={false}
            value={p.texto}
            onChange={(e) => p.cambiarTexto(e.target.value)}
            onKeyDown={p.alTeclear}
            placeholder={
              conAsistente
                ? 'Nombre, teléfono, #orden, pantalla o una pregunta'
                : 'Nombre, teléfono, cédula, #orden o pantalla'
            }
            className="h-panel-control w-full rounded-panel-control border border-transparent bg-panel-control pl-9 pr-3 type-panel-body text-on-surface outline-none transition-colors duration-[var(--transition-fast)] placeholder:text-placeholder focus:border-primary"
          />
        </div>

        <div
          id={idLista}
          role="listbox"
          aria-label="Resultados"
          className={`-mx-2 max-h-[min(60vh,30rem)] overflow-y-auto ${hayGrupos ? '' : 'hidden'}`}
        >
          {p.grupos.map((grupo) => (
            <GrupoPaleta
              key={grupo.id}
              grupo={grupo}
              idBase={base}
              idDe={idDe}
              activa={p.activa?.clave ?? null}
              desplegada={p.desplegada}
              onSenalar={p.senalar}
              onElegir={p.elegir}
            />
          ))}
        </div>

        {p.vacia && (
          <div className="px-1 py-2">
            <p className="type-panel-body text-on-surface">Nada con «{p.consulta.texto}».</p>
            <p className="type-panel-caption text-panel-muted">
              Prueba con un teléfono, una cédula o un número de orden.
            </p>
            {siNoHayNada?.(p.consulta)}
          </div>
        )}

        {/* Lo que oye quien usa lector de pantalla al terminar de buscar. */}
        <p role="status" className="sr-only">
          {p.anuncio}
        </p>

        <AyudaDeTeclado esMac={esMac} />
      </div>
    </Modal>,
    document.body,
  )
}
