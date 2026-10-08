import { useEffect, useId, useState } from 'react'
import type { KeyboardEvent, MouseEvent, ReactNode } from 'react'
import { CalendarDays } from 'lucide-react'

import { Capa, salirConTab, useFlotante } from '@/components/kit/flotante'
import { MESES_LARGOS } from '@/components/kit/rango'
import { EDAD_MINIMA, diasDelMes, partesDeFecha } from '@/features/merchant/paciente'

// ═══════════════════════════════════════════════════════════════════════════
// La fecha de nacimiento sin teclear: día, luego mes, luego año.
//
// Un calendario de mes en mes no sirve para esto: llegar a 1974 son 600
// pulsaciones de flecha. Aquí cada parte es un clic sobre una rejilla, en el
// orden en que se dice la fecha («el 12 de abril del 90»), y el año va por
// década y año: dos clics para cualquiera.
//
// Lo que no existe no se puede elegir: con el 31 elegido, febrero, abril,
// junio, septiembre y noviembre salen apagados; con el 29 de febrero, solo
// los años bisiestos. Los años van de los 110 años a la mayoría de edad,
// que son los únicos que el alta acepta para el titular.
// ═══════════════════════════════════════════════════════════════════════════

type Paso = 'dia' | 'mes' | 'anio'

const EDAD_MAXIMA = 110

const DIAS = Array.from({ length: 31 }, (_, i) => i + 1)
const MESES = Array.from({ length: 12 }, (_, i) => i + 1)

const dos = (n: number) => String(n).padStart(2, '0')

export function SelectorDeNacimiento({
  valor,
  hoy,
  inputId,
  onElegir,
}: {
  /** Lo que hay escrito en el campo: de ahí sale lo ya elegido al abrir. */
  valor: string
  /** El día de hoy en Caracas, 'YYYY-MM-DD'. */
  hoy: string
  /** El campo de la fecha: al terminar, el foco vuelve a él. */
  inputId: string
  /** La fecha elegida, como se escribe: «12/04/1990». */
  onElegir: (texto: string) => void
}) {
  const idCapa = useId()
  const [abierto, setAbierto] = useState(false)
  const [paso, setPaso] = useState<Paso>('dia')
  const [dia, setDia] = useState<number | null>(null)
  const [mes, setMes] = useState<number | null>(null)
  const [anio, setAnio] = useState<number | null>(null)
  const [decada, setDecada] = useState<number | null>(null)

  const anioDeHoy = Number(hoy.slice(0, 4))
  const ultimo = anioDeHoy - EDAD_MINIMA
  const primero = anioDeHoy - EDAD_MAXIMA
  const decadas: number[] = []
  for (let d = Math.floor(ultimo / 10) * 10; d >= Math.floor(primero / 10) * 10; d -= 10) {
    decadas.push(d)
  }

  const flotante = useFlotante<HTMLButtonElement>({
    abierto,
    lado: 'abajo',
    alineacion: 'fin',
    alCerrar: () => setAbierto(false),
  })

  // El mes no mira el año: quien vuelve a por el 29 de febrero lo encuentra,
  // y es el año que no casa el que se suelta (`elegirMes`).
  const mesPosible = (m: number) => dia === null || dia <= diasDelMes(m, null)
  const anioPosible = (y: number) =>
    y >= primero && y <= ultimo && (dia === null || mes === null || dia <= diasDelMes(mes, y))

  function abrir(evento: MouseEvent<HTMLButtonElement>) {
    evento.stopPropagation()
    if (abierto) return setAbierto(false)
    // Se empieza por lo que falta: con «12/04» escrito, por el año. Lo
    // escrito que no casa («31/02», un 29/02 de 1990) se suelta y se pregunta.
    const { dia: d, mes: m, anio: a } = partesDeFecha(valor, hoy)
    const mesQueCasa = d !== null && m !== null && d > diasDelMes(m, null) ? null : m
    const y =
      a !== null &&
      a >= primero &&
      a <= ultimo &&
      !(d !== null && mesQueCasa !== null && d > diasDelMes(mesQueCasa, a))
        ? a
        : null
    setDia(d)
    setMes(mesQueCasa)
    setAnio(y)
    setDecada(y === null ? null : Math.floor(y / 10) * 10)
    setPaso(d === null ? 'dia' : mesQueCasa === null ? 'mes' : y === null ? 'anio' : 'dia')
    setAbierto(true)
  }

  function elegirDia(d: number) {
    setDia(d)
    // Un mes o un año que ya no casan con el día nuevo se sueltan.
    if (mes !== null && d > diasDelMes(mes, null)) setMes(null)
    else if (mes !== null && anio !== null && d > diasDelMes(mes, anio)) setAnio(null)
    setPaso('mes')
  }

  function elegirMes(m: number) {
    setMes(m)
    if (dia !== null && anio !== null && dia > diasDelMes(m, anio)) setAnio(null)
    setPaso('anio')
  }

  function elegirAnio(y: number) {
    setAnio(y)
    if (dia === null) return setPaso('dia')
    if (mes === null) return setPaso('mes')
    onElegir(`${dos(dia)}/${dos(mes)}/${y}`)
    setAbierto(false)
    document.getElementById(inputId)?.focus()
  }

  // Al abrir y en cada paso, el foco va a lo elegido o a lo primero que se
  // pueda elegir: se sigue con las flechas y Enter, sin ratón.
  useEffect(() => {
    if (!abierto) return
    const capa = flotante.capaRef.current
    const rejilla = Array.from(capa?.querySelectorAll<HTMLElement>('[data-rejilla]') ?? []).at(-1)
    const destino =
      rejilla?.querySelector<HTMLElement>('button[aria-pressed="true"]:not(:disabled)') ??
      rejilla?.querySelector<HTMLElement>('button:not(:disabled)')
    destino?.focus({ preventScroll: true })
  }, [abierto, paso, decada, flotante.capaRef])

  const enLetras = {
    dia: dia === null ? '—' : String(dia),
    mes: mes === null ? '—' : MESES_LARGOS[mes - 1],
    anio: anio === null ? '—' : String(anio),
  }

  return (
    <>
      <button
        ref={flotante.anclaRef}
        type="button"
        aria-haspopup="dialog"
        aria-expanded={abierto}
        aria-controls={abierto ? idCapa : undefined}
        aria-label="Elegir día, mes y año"
        title="Elegir día, mes y año"
        onClick={abrir}
        className="inline-flex size-9 items-center justify-center rounded-panel-control text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:bg-on-surface/8 hover:text-on-surface"
      >
        <CalendarDays size={18} aria-hidden />
      </button>

      <Capa
        flotante={flotante}
        abierto={abierto}
        id={idCapa}
        role="dialog"
        aria-label="Fecha de nacimiento"
        onKeyDown={(e) => salirConTab(e, flotante.anclaRef.current, () => setAbierto(false))}
        className="anim-globo flex w-80 max-w-[calc(100vw-2rem)] flex-col gap-3 rounded-panel-card border border-panel-hairline-strong bg-panel-control p-3 shadow-2xl"
      >
        {/* Las tres partes, en el orden en que se dicen. Cada una lleva a su
            paso, para corregir una sin rehacer las otras. */}
        <div className="grid grid-cols-3 gap-1 rounded-panel-control bg-shell-inset p-1">
          {(['dia', 'mes', 'anio'] as const).map((p) => (
            <button
              key={p}
              type="button"
              aria-current={paso === p ? 'step' : undefined}
              onClick={() => setPaso(p)}
              className={`flex min-w-0 flex-col items-start rounded-[calc(var(--radius-panel-control)-2px)] px-2 py-1 text-left transition-colors duration-[var(--transition-fast)] ${
                paso === p ? 'bg-panel-control shadow-sm' : 'hover:bg-on-surface/6'
              }`}
            >
              <span className="type-panel-caption text-panel-muted">
                {p === 'dia' ? 'Día' : p === 'mes' ? 'Mes' : 'Año'}
              </span>
              <span
                className={`w-full truncate type-panel-label tabular-nums ${
                  p === 'mes' ? 'capitalize' : ''
                } ${enLetras[p] === '—' ? 'text-panel-muted' : 'text-on-surface'}`}
              >
                {enLetras[p]}
              </span>
            </button>
          ))}
        </div>

        {paso === 'dia' && (
          <Rejilla columnas={7} rotulo="Día">
            {DIAS.map((d) => (
              <Casilla key={d} puesta={d === dia} onClick={() => elegirDia(d)} redonda>
                {d}
              </Casilla>
            ))}
          </Rejilla>
        )}

        {paso === 'mes' && (
          <Rejilla columnas={3} rotulo="Mes">
            {MESES.map((m) => (
              <Casilla
                key={m}
                puesta={m === mes}
                disabled={!mesPosible(m)}
                motivo={dia !== null ? `${MESES_LARGOS[m - 1]} no tiene día ${dia}` : undefined}
                onClick={() => elegirMes(m)}
              >
                <span className="capitalize">{MESES_LARGOS[m - 1]}</span>
              </Casilla>
            ))}
          </Rejilla>
        )}

        {paso === 'anio' && (
          <>
            <p className="type-panel-caption text-panel-muted">
              Primero la década, luego el año. Solo mayores de edad: el titular tiene {EDAD_MINIMA}{' '}
              años o más.
            </p>
            <Rejilla columnas={5} rotulo="Década">
              {decadas.map((d) => (
                <Casilla key={d} puesta={d === decada} onClick={() => setDecada(d)}>
                  {/* «1990–99» y no «1990»: solo, se lee como un año. */}
                  <span className="whitespace-nowrap type-panel-caption font-semibold">
                    {d}–{String(d + 9).slice(2)}
                  </span>
                </Casilla>
              ))}
            </Rejilla>
            {decada !== null && (
              <Rejilla columnas={5} rotulo="Año">
                {Array.from({ length: 10 }, (_, i) => decada + i).map((y) => (
                  <Casilla
                    key={y}
                    puesta={y === anio}
                    disabled={!anioPosible(y)}
                    motivo={
                      y > ultimo
                        ? 'Sería menor de edad'
                        : y < primero
                          ? `Más de ${EDAD_MAXIMA} años`
                          : `${y} no es bisiesto: febrero no tiene día 29`
                    }
                    onClick={() => elegirAnio(y)}
                  >
                    {y}
                  </Casilla>
                ))}
              </Rejilla>
            )}
          </>
        )}
      </Capa>
    </>
  )
}

/**
 * Una rejilla de botones que se recorre con las flechas, saltando los
 * apagados. Tab entra y sale de ella como de un solo control.
 */
function Rejilla({
  columnas,
  rotulo,
  children,
}: {
  columnas: number
  rotulo: string
  children: ReactNode
}) {
  function alTeclear(e: KeyboardEvent<HTMLDivElement>) {
    const paso =
      e.key === 'ArrowRight'
        ? 1
        : e.key === 'ArrowLeft'
          ? -1
          : e.key === 'ArrowDown'
            ? columnas
            : e.key === 'ArrowUp'
              ? -columnas
              : 0
    if (paso === 0) return
    const botones = Array.from(e.currentTarget.querySelectorAll<HTMLButtonElement>('button'))
    let i = botones.indexOf(document.activeElement as HTMLButtonElement)
    if (i < 0) return
    e.preventDefault()
    do i += paso
    while (i >= 0 && i < botones.length && botones[i].disabled)
    botones[i]?.focus()
  }

  return (
    <div
      role="group"
      aria-label={rotulo}
      data-rejilla=""
      onKeyDown={alTeclear}
      className="grid gap-1"
      style={{ gridTemplateColumns: `repeat(${columnas}, minmax(0, 1fr))` }}
    >
      {children}
    </div>
  )
}

function Casilla({
  puesta,
  disabled = false,
  motivo,
  redonda = false,
  onClick,
  children,
}: {
  puesta: boolean
  disabled?: boolean
  /** Por qué está apagada: sale al pasar el ratón. */
  motivo?: string
  redonda?: boolean
  onClick: () => void
  children: ReactNode
}) {
  return (
    // El `title` va en el envoltorio: un botón apagado no recibe el ratón y
    // el navegador nunca enseñaría el suyo.
    <span title={disabled ? motivo : undefined} className="flex justify-center">
      <button
        type="button"
        aria-pressed={puesta}
        disabled={disabled}
        onClick={onClick}
        className={`inline-flex h-9 items-center justify-center type-panel-label tabular-nums outline-none transition-colors duration-[var(--transition-fast)] focus-visible:ring-2 focus-visible:ring-primary ${
          redonda ? 'size-9 rounded-full' : 'w-full rounded-panel-control px-1'
        } ${
          puesta
            ? 'bg-on-surface font-semibold text-on-inverse-surface'
            : disabled
              ? 'cursor-not-allowed text-on-surface-faint/60'
              : 'text-on-surface hover:bg-on-surface/12'
        }`}
      >
        {children}
      </button>
    </span>
  )
}
