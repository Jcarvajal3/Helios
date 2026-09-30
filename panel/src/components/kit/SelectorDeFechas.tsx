import { useEffect, useId, useState } from 'react'
import type { MouseEvent, ReactNode } from 'react'
import { CalendarDays, Check, ChevronDown, ChevronLeft, ChevronRight, X } from 'lucide-react'

import { RangoEnCalendario } from './Calendario'
import { Capa, salirConTab, useFlotante } from './flotante'
import { Tooltip } from './Tooltip'
import type { Rango } from './rango'

/** Una flecha: ir al periodo anterior o al siguiente. */
export type Paso = {
  onClick: () => void
  disabled?: boolean
  /** Por qué no se puede: sale al pasar el ratón por la flecha apagada. */
  motivo?: string
}

/** Una fila de la lista que abre el botón: un atajo, una semana, un mes. */
export type OpcionDeFecha = {
  clave: string
  /** Lo que se lee: «30 días», «Semana pasada», «agosto de 2026». */
  label: string
  /** Las fechas que cubre, en gris a la derecha: «27 ago – 25 sep». */
  detalle?: string
  puesta: boolean
  onElegir: () => void
}

/**
 * El selector de fechas del panel, el mismo en todas las pantallas:
 * «‹ 📅 27 ago – 25 sep ▾ ›».
 *
 * Las flechas van al periodo anterior y al siguiente sin abrir nada, que es
 * lo que más se hace; el botón del medio abre la lista (atajos, semanas o
 * meses) y, donde se admite, un rango propio elegido en el calendario. Una pantalla que solo
 * mira «los últimos N días» no lleva flechas: no hay anterior que mirar.
 *
 * Las variantes (`Periodo`, `SelectorDeSemana`, `SelectorDeMes`,
 * `SelectorDeVentana`, `SelectorDePaso`) solo deciden qué va en cada sitio;
 * la forma es esta y no se repite.
 */
export function SelectorDeFechas({
  rotulo,
  titulo,
  etiqueta,
  anterior,
  siguiente,
  opciones = [],
  rangoPropio,
  onQuitar,
  extra,
}: {
  /** Lo que se mira, corto: «27 ago – 25 sep», «agosto de 2026». */
  rotulo: string
  /** El mismo periodo dicho entero, al pasar el ratón. */
  titulo?: string
  /** Qué se elige, para el lector de pantalla: «Periodo», «Semana», «Mes». */
  etiqueta: string
  /** Sin él, no hay flechas. */
  anterior?: Paso
  siguiente?: Paso
  /** Sin opciones ni rango propio, el centro es un rótulo y no abre nada. */
  opciones?: ReadonlyArray<OpcionDeFecha>
  rangoPropio?: {
    inicial: Rango | null
    maximo: string
    /** El día que lleva el punto de hoy en el calendario. */
    hoy?: string
    alAplicar: (rango: Rango) => void
  }
  /** Vacía el periodo. Con él aparece la equis; sin él, no se puede quitar. */
  onQuitar?: () => void
  /** Lo que va a la izquierda del control: la marca «En curso». */
  extra?: ReactNode
}) {
  const [abierto, setAbierto] = useState(false)
  const idCapa = useId()
  const abre = opciones.length > 0 || rangoPropio !== undefined

  const flotante = useFlotante<HTMLButtonElement>({
    abierto,
    lado: 'abajo',
    alineacion: 'inicio',
    alCerrar: () => setAbierto(false),
  })

  // Al abrir, el foco va a la opción puesta (o a la primera): desde ahí se
  // sigue con Tab hasta el rango propio. Solo en la lista: las casillas del
  // calendario también llevan `aria-pressed`.
  useEffect(() => {
    if (!abierto) return
    const capa = flotante.capaRef.current
    const destino =
      capa?.querySelector<HTMLElement>('ul [aria-pressed="true"]') ??
      capa?.querySelector<HTMLElement>('button')
    destino?.focus({ preventScroll: true })
  }, [abierto, flotante.capaRef])

  function cerrarY(accion: () => void) {
    flotante.anclaRef.current?.focus()
    setAbierto(false)
    accion()
  }

  function alPulsar(evento: MouseEvent<HTMLButtonElement>) {
    evento.stopPropagation()
    setAbierto((v) => !v)
  }

  const centro = abre ? (
    <button
      ref={flotante.anclaRef}
      type="button"
      aria-haspopup="dialog"
      aria-expanded={abierto}
      aria-controls={abierto ? idCapa : undefined}
      aria-label={`${etiqueta}: ${rotulo}`}
      title={titulo}
      onClick={alPulsar}
      className="inline-flex h-8 shrink-0 items-center gap-2 rounded-panel-control px-2 type-panel-control text-on-surface transition-colors duration-[var(--transition-fast)] hover:bg-panel-control"
    >
      <CalendarDays size={15} aria-hidden />
      <span aria-live="polite" className="whitespace-nowrap">
        {rotulo}
      </span>
      <ChevronDown size={14} aria-hidden className="text-panel-muted" />
    </button>
  ) : (
    <span
      aria-live="polite"
      title={titulo}
      className="inline-flex h-8 items-center gap-2 whitespace-nowrap px-2 type-panel-control text-on-surface"
    >
      <CalendarDays size={15} aria-hidden />
      {rotulo}
    </span>
  )

  return (
    <div className="flex flex-wrap items-center justify-end gap-2">
      {extra}
      <span className="inline-flex items-center gap-1">
        <div
          role="group"
          aria-label={etiqueta}
          className="inline-flex h-panel-control-sm items-center rounded-panel-control bg-panel-raised px-0.5"
        >
          {anterior && (
            <Flecha paso={anterior} rotulo={`${etiqueta}: el anterior`}>
              <ChevronLeft size={16} aria-hidden />
            </Flecha>
          )}
          {centro}
          {siguiente && (
            <Flecha paso={siguiente} rotulo={`${etiqueta}: el siguiente`}>
              <ChevronRight size={16} aria-hidden />
            </Flecha>
          )}
        </div>
        {onQuitar && (
          <Tooltip contenido="Quitar las fechas">
            <button
              type="button"
              aria-label="Quitar las fechas"
              onClick={() => cerrarY(onQuitar)}
              className="inline-flex size-panel-control-sm shrink-0 items-center justify-center rounded-panel-control text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:bg-panel-raised hover:text-on-surface"
            >
              <X size={15} aria-hidden />
            </button>
          </Tooltip>
        )}
      </span>

      {abre && (
        <Capa
          flotante={flotante}
          abierto={abierto}
          id={idCapa}
          role="dialog"
          aria-label={`Elegir: ${etiqueta.toLowerCase()}`}
          onKeyDown={(e) => salirConTab(e, flotante.anclaRef.current, () => setAbierto(false))}
          className={`anim-globo flex max-h-[85vh] ${rangoPropio ? 'w-80' : 'w-72'} flex-col overflow-y-auto rounded-panel-card border border-panel-hairline-strong bg-panel-control p-1.5 shadow-2xl`}
        >
          {opciones.length > 0 && (
            <ul className="flex flex-col">
              {opciones.map((o) => (
                <li key={o.clave}>
                  <button
                    type="button"
                    aria-pressed={o.puesta}
                    onClick={() => cerrarY(o.onElegir)}
                    className={`flex w-full items-center gap-2 rounded-panel-control px-2.5 py-2 text-left type-panel-label transition-colors duration-[var(--transition-fast)] hover:bg-shell-inset hover:text-on-surface ${
                      o.puesta ? 'bg-shell-inset text-on-surface' : 'text-on-surface-variant'
                    }`}
                  >
                    <span className="flex-1">{o.label}</span>
                    {o.detalle && (
                      <span className="type-panel-caption font-normal text-panel-muted">{o.detalle}</span>
                    )}
                    <Check
                      size={14}
                      aria-hidden
                      className={`shrink-0 ${o.puesta ? 'text-on-surface' : 'invisible'}`}
                    />
                  </button>
                </li>
              ))}
            </ul>
          )}

          {opciones.length > 0 && rangoPropio && (
            <div role="separator" className="mx-1 my-1.5 h-px bg-panel-hairline-strong" />
          )}

          {rangoPropio && (
            <RangoEnCalendario
              titulo="Rango propio"
              inicial={rangoPropio.inicial}
              maximo={rangoPropio.maximo}
              hoy={rangoPropio.hoy}
              alAplicar={(r) => cerrarY(() => rangoPropio.alAplicar(r))}
            />
          )}
        </Capa>
      )}
    </div>
  )
}

function Flecha({ paso, rotulo, children }: { paso: Paso; rotulo: string; children: ReactNode }) {
  return (
    // El `title` va en el envoltorio: un botón apagado no recibe el ratón y
    // el navegador nunca enseñaría el suyo.
    <span title={paso.disabled ? paso.motivo : undefined} className="inline-flex">
      <button
        type="button"
        aria-label={rotulo}
        onClick={paso.onClick}
        disabled={paso.disabled}
        className="en-linea inline-flex size-8 items-center justify-center rounded-panel-control text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:bg-panel-control hover:text-on-surface disabled:pointer-events-none disabled:opacity-35"
      >
        {children}
      </button>
    </span>
  )
}
