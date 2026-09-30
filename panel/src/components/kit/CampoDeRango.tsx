import { useEffect, useId, useState } from 'react'
import { CalendarDays, ChevronDown } from 'lucide-react'

import { RangoEnCalendario, rangoConAnio } from './Calendario'
import { CLASE_CAMPO, bordeDeCampo } from './clases'
import { Capa, salirConTab, useFlotante } from './flotante'
import type { Rango } from './rango'

/**
 * Un rango de fechas en un formulario: un campo que dice «24 sep – 30 sep
 * 2026» y abre el calendario. Sustituye a los dos `<input type="date">` de
 * Desde y Hasta, que se escribían a mano y cada navegador pintaba a su manera.
 *
 * Para acotar una lista con atajos y flechas está `Periodo`; esto es para
 * donde las fechas son un campo más.
 */
export function CampoDeRango({
  id,
  label,
  rango,
  onChange,
  maximo,
  minimo,
  hoy,
  error = false,
  className = '',
}: {
  id: string
  label?: string
  rango: Rango | null
  onChange: (rango: Rango) => void
  maximo?: string
  minimo?: string
  hoy?: string
  error?: boolean
  className?: string
}) {
  const [abierto, setAbierto] = useState(false)
  const idCapa = useId()

  const flotante = useFlotante<HTMLButtonElement>({
    abierto,
    lado: 'abajo',
    alineacion: 'inicio',
    alCerrar: () => setAbierto(false),
  })

  // Al abrir, el foco va al día del calendario que se puede tabular: desde
  // ahí se sigue con las flechas.
  useEffect(() => {
    if (!abierto) return
    flotante.capaRef.current
      ?.querySelector<HTMLElement>('[role="grid"] [tabindex="0"]')
      ?.focus({ preventScroll: true })
  }, [abierto, flotante.capaRef])

  const texto = rango ? rangoConAnio(rango) : null

  return (
    <div className={className}>
      {label && (
        <label htmlFor={id} className="mb-shell-gap-stack block">
          <span className="block type-panel-label text-on-surface-variant">{label}</span>
        </label>
      )}
      <button
        ref={flotante.anclaRef}
        id={id}
        type="button"
        aria-haspopup="dialog"
        aria-expanded={abierto}
        aria-controls={abierto ? idCapa : undefined}
        aria-invalid={error}
        aria-label={`${label ?? 'Fechas'}: ${texto ?? 'sin elegir'}`}
        onClick={(e) => {
          e.stopPropagation()
          setAbierto((v) => !v)
        }}
        className={`flex h-panel-control-md items-center gap-2 text-left ${CLASE_CAMPO} ${
          abierto ? 'border-primary' : bordeDeCampo(error)
        }`}
      >
        <CalendarDays size={16} aria-hidden className="shrink-0 text-on-surface-variant" />
        <span className={`flex-1 truncate tabular-nums ${texto ? '' : 'text-placeholder'}`}>
          {texto ?? 'Elige las fechas'}
        </span>
        <ChevronDown
          size={14}
          aria-hidden
          className={`shrink-0 text-panel-muted transition-transform duration-[var(--transition-fast)] ${
            abierto ? 'rotate-180' : ''
          }`}
        />
      </button>

      <Capa
        flotante={flotante}
        abierto={abierto}
        id={idCapa}
        role="dialog"
        aria-label={`Elegir: ${(label ?? 'fechas').toLowerCase()}`}
        onKeyDown={(e) => salirConTab(e, flotante.anclaRef.current, () => setAbierto(false))}
        className="anim-globo w-80 rounded-panel-card border border-panel-hairline-strong bg-panel-control p-1.5 shadow-2xl"
      >
        <RangoEnCalendario
          inicial={rango}
          maximo={maximo}
          minimo={minimo}
          hoy={hoy}
          alAplicar={(r) => {
            flotante.anclaRef.current?.focus()
            setAbierto(false)
            onChange(r)
          }}
        />
      </Capa>
    </div>
  )
}
