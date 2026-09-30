import { useEffect, useId, useState } from 'react'
import type { KeyboardEvent, MouseEvent, ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Check, ChevronDown, Store } from 'lucide-react'

import { NoSePudoLeer } from '@/components/ui'
import { Capa, useFlotante } from '@/components/kit/flotante'
import { fetchMerchants } from '@/features/admin/api'
import { nombreDelLocal, opcionesDeLocal } from '@/features/admin/metricas/opcionesDeLocal'
import type { LocalElegible } from '@/features/admin/metricas/opcionesDeLocal'

/**
 * Los locales, con la misma clave que Directorio › Locales y las fichas: con
 * cualquiera de ellas abierta, el selector no pide nada nuevo.
 */
export function useLocalesDeMetricas() {
  return useQuery({ queryKey: ['merchants'], queryFn: fetchMerchants, staleTime: 5 * 60_000 })
}

/**
 * El local que se mira en Métricas: «🏪 Todos los locales ▾».
 *
 * Tiene la forma del selector de semana de al lado (la misma caja levantada
 * y la misma lista), porque son los dos controles que valen para todas las
 * pestañas. Lista los locales de verdad —sin los de prueba—: primero los
 * activos y, aparte, los pausados y terminados, que ya no venden pero tienen
 * historia.
 */
export function SelectorDeLocal({
  local,
  onCambiar,
  motivoApagado,
}: {
  /** El uuid elegido, o `null`: todos. */
  local: string | null
  onCambiar: (local: string | null) => void
  /** Si la pestaña no se parte por local: el selector se apaga con esto en el globo. */
  motivoApagado?: string
}) {
  const locales = useLocalesDeMetricas()
  const [abierto, setAbierto] = useState(false)
  const idCapa = useId()

  const flotante = useFlotante<HTMLButtonElement>({
    abierto,
    lado: 'abajo',
    alineacion: 'inicio',
    alCerrar: () => setAbierto(false),
  })

  // Al abrir, el foco va a la opción puesta: desde ahí se sigue con Tab.
  useEffect(() => {
    if (!abierto) return
    const capa = flotante.capaRef.current
    const destino =
      capa?.querySelector<HTMLElement>('[aria-pressed="true"]') ?? capa?.querySelector<HTMLElement>('button')
    destino?.focus({ preventScroll: true })
  }, [abierto, flotante.capaRef])

  const lista: ReadonlyArray<LocalElegible> = locales.data ?? []
  const { activos, otros } = opcionesDeLocal(lista)
  const nombre = nombreDelLocal(lista, local)

  const rotulo =
    local === null
      ? 'Todas las clínicas'
      : (nombre ??
        (locales.isPending ? 'Leyendo la clínica…' : locales.isError ? 'La clínica elegida' : 'Una clínica que no está en la lista'))

  function elegir(id: string | null) {
    flotante.anclaRef.current?.focus()
    setAbierto(false)
    if (id !== local) onCambiar(id)
  }

  function alPulsar(evento: MouseEvent<HTMLButtonElement>) {
    evento.stopPropagation()
    setAbierto((v) => !v)
  }

  // La lista va en un portal: salir por un extremo con Tab la cierra y el foco
  // sigue desde el botón, como si estuviera justo detrás de él.
  function alTeclear(evento: KeyboardEvent<HTMLDivElement>) {
    if (evento.key !== 'Tab') return
    const controles = Array.from(evento.currentTarget.querySelectorAll<HTMLElement>('button'))
    const activo = document.activeElement
    const saleHaciaAtras = evento.shiftKey && activo === controles.at(0)
    const saleHaciaDelante = !evento.shiftKey && activo === controles.at(-1)
    if (!saleHaciaAtras && !saleHaciaDelante) return
    if (saleHaciaAtras) evento.preventDefault()
    flotante.anclaRef.current?.focus()
    setAbierto(false)
  }

  const apagado = motivoApagado !== undefined

  return (
    // El `title` va en el envoltorio: un botón apagado no recibe el ratón.
    <span title={motivoApagado} className="inline-flex">
      <button
        ref={flotante.anclaRef}
        type="button"
        disabled={apagado}
        aria-haspopup="dialog"
        aria-expanded={abierto}
        aria-controls={abierto ? idCapa : undefined}
        aria-label={`Clínica: ${rotulo}`}
        onClick={alPulsar}
        className="inline-flex h-panel-control-sm max-w-72 items-center gap-2 rounded-panel-control bg-panel-raised px-2.5 type-panel-control text-on-surface transition-colors duration-[var(--transition-fast)] hover:bg-panel-control disabled:pointer-events-none disabled:opacity-40"
      >
        <Store size={15} aria-hidden className="shrink-0 text-panel-muted" />
        <span aria-live="polite" className="min-w-0 truncate">
          {rotulo}
        </span>
        <ChevronDown size={14} aria-hidden className="shrink-0 text-panel-muted" />
      </button>

      <Capa
        flotante={flotante}
        abierto={abierto}
        id={idCapa}
        role="dialog"
        aria-label="Elegir la clínica"
        onKeyDown={alTeclear}
        className="anim-globo flex max-h-[70vh] w-72 flex-col overflow-y-auto rounded-panel-card border border-panel-hairline-strong bg-panel-control p-1.5 shadow-2xl"
      >
        <ul className="flex flex-col">
          <Opcion rotulo="Todas las clínicas" puesta={local === null} onElegir={() => elegir(null)} />
          {/* Un local que llegó por un enlace y no está en la lista se sigue
              viendo puesto: si no, parecería que no hay ninguno elegido. */}
          {local !== null && nombre === null && locales.isSuccess && (
            <Opcion rotulo="Una clínica que no está en la lista" puesta onElegir={() => elegir(local)} />
          )}
        </ul>

        {locales.isError && (
          <div className="px-2.5 py-2">
            <NoSePudoLeer onReintentar={() => void locales.refetch()} />
          </div>
        )}
        {locales.isPending && <p className="px-2.5 py-2 type-panel-caption text-panel-muted">Leyendo las clínicas…</p>}

        {activos.length > 0 && (
          <Grupo titulo="Activos">
            {activos.map((l) => (
              <Opcion key={l.id} rotulo={l.name} puesta={l.id === local} onElegir={() => elegir(l.id)} />
            ))}
          </Grupo>
        )}
        {otros.length > 0 && (
          <Grupo titulo="Pausados o terminados">
            {otros.map((l) => (
              <Opcion key={l.id} rotulo={l.name} puesta={l.id === local} onElegir={() => elegir(l.id)} />
            ))}
          </Grupo>
        )}
      </Capa>
    </span>
  )
}

function Grupo({ titulo, children }: { titulo: string; children: ReactNode }) {
  const id = useId()
  return (
    <>
      <div role="separator" className="mx-1 my-1.5 h-px bg-panel-hairline-strong" />
      <p id={id} className="px-2.5 pt-1 pb-0.5 type-panel-caption font-semibold text-panel-muted">
        {titulo}
      </p>
      <ul aria-labelledby={id} className="flex flex-col">
        {children}
      </ul>
    </>
  )
}

function Opcion({ rotulo, puesta, onElegir }: { rotulo: string; puesta: boolean; onElegir: () => void }) {
  return (
    <li>
      <button
        type="button"
        aria-pressed={puesta}
        onClick={onElegir}
        className={`flex w-full items-center gap-2 rounded-panel-control px-2.5 py-2 text-left type-panel-label transition-colors duration-[var(--transition-fast)] hover:bg-shell-inset hover:text-on-surface ${
          puesta ? 'bg-shell-inset text-on-surface' : 'text-on-surface-variant'
        }`}
      >
        <span className="min-w-0 flex-1 truncate">{rotulo}</span>
        <Check size={14} aria-hidden className={`shrink-0 ${puesta ? 'text-on-surface' : 'invisible'}`} />
      </button>
    </li>
  )
}
