import { useEffect, useRef, useState } from 'react'
import type { FormEvent, KeyboardEvent, ReactNode } from 'react'
import { ChevronLeft, ChevronRight } from 'lucide-react'

import { claseDeBoton } from './clases'
import { MESES_CORTOS, MESES_LARGOS, primeroDelMes, rangoCorto, sumarDias } from './rango'
import type { Rango } from './rango'

// ═══════════════════════════════════════════════════════════════════════════
// El calendario de los rangos de fechas.
//
// Sustituye a escribir «27/08/2026» dos veces: un clic en el primer día, otro
// en el último, y el tramo entre los dos se pinta mientras se elige. Sin
// librerías, y con las cuentas de `rango.ts`, que no pasan por la zona
// horaria.
// ═══════════════════════════════════════════════════════════════════════════

const INICIALES = ['L', 'M', 'X', 'J', 'V', 'S', 'D']
const DIAS = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo']

/**
 * Qué extremo pone el próximo clic. `nuevo` empieza un rango desde cero (el
 * clic es el «desde» y borra el «hasta»); `desde` y `hasta` corrigen solo ese
 * extremo, que es lo que se pide al pulsar su casilla.
 */
type Modo = 'nuevo' | 'desde' | 'hasta'

/** 0 = lunes … 6 = domingo. */
function diaDeLaSemana(dia: string): number {
  const [y = 0, m = 1, d = 1] = dia.split('-').map(Number)
  return (new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7
}

/** El día 1 del mes que está `n` meses más allá. */
function mesDeAlLado(mes: string, n: number): string {
  const [y = 0, m = 1] = mes.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1 + n, 1)).toISOString().slice(0, 10)
}

/** El mismo número de día `n` meses más allá; el 31 cae en el último que haya. */
function mismoDiaDeOtroMes(dia: string, n: number): string {
  const destino = mesDeAlLado(primeroDelMes(dia), n)
  const ultimo = sumarDias(mesDeAlLado(destino, 1), -1)
  const candidato = `${destino.slice(0, 8)}${dia.slice(8, 10)}`
  return candidato > ultimo ? ultimo : candidato
}

/**
 * Las 42 casillas del mes: seis semanas siempre, con los días del mes de al
 * lado en gris. Con cinco o seis según el mes, la capa cambiaba de alto y
 * saltaba de sitio al pasar de uno a otro.
 */
function casillasDelMes(mes: string): string[] {
  const inicio = sumarDias(mes, -diaDeLaSemana(mes))
  return Array.from({ length: 42 }, (_, i) => sumarDias(inicio, i))
}

/** '27 ago 2026'. */
function diaConAnio(dia: string): string {
  const [y = '', m = '', d = ''] = dia.split('-')
  return `${Number(d)} ${MESES_CORTOS[Number(m) - 1] ?? m} ${y}`
}

/** 'jueves 27 de agosto de 2026', para el lector de pantalla. */
function diaDicho(dia: string): string {
  const [y = '', m = '', d = ''] = dia.split('-')
  return `${DIAS[diaDeLaSemana(dia)]} ${Number(d)} de ${MESES_LARGOS[Number(m) - 1] ?? m} de ${y}`
}

/** Hoy en Caracas, para cuando quien llama no dice qué día es. */
function hoyEnCaracas(): string {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'America/Caracas' })
}

/** '24 sep – 30 sep 2026': el rango con su año, para un campo. */
export function rangoConAnio(r: Rango): string {
  const corto = rangoCorto(r)
  return r.from.slice(0, 4) === r.to.slice(0, 4) ? `${corto} ${r.to.slice(0, 4)}` : corto
}

/**
 * Elegir un rango en el calendario: las dos casillas «Desde» y «Hasta» dicen
 * qué hay puesto y cuál rellena el próximo clic; debajo, el mes; al final,
 * «Aplicar». El estado nace con el rango que ya estaba puesto (o vacío) y se
 * tira al cerrar la capa que lo contiene.
 */
export function RangoEnCalendario({
  inicial,
  maximo,
  minimo,
  hoy,
  titulo,
  alAplicar,
}: {
  inicial: Rango | null
  /** El último día elegible; los de después salen apagados. */
  maximo?: string
  /** El primer día elegible. */
  minimo?: string
  /** Lleva un punto debajo. Por defecto, hoy en Caracas. */
  hoy?: string
  /** El rótulo de arriba: «Rango propio». */
  titulo?: string
  alAplicar: (rango: Rango) => void
}) {
  const [desde, setDesde] = useState<string | null>(inicial?.from ?? null)
  const [hasta, setHasta] = useState<string | null>(inicial?.to ?? null)
  const [modo, setModo] = useState<Modo>('nuevo')

  function elegir(dia: string) {
    if (modo === 'nuevo' || (modo === 'hasta' && (desde === null || dia < desde))) {
      setDesde(dia)
      setHasta(null)
      setModo('hasta')
    } else if (modo === 'hasta') {
      setHasta(dia)
      setModo('nuevo')
    } else if (hasta !== null && dia > hasta) {
      // Un «desde» después del «hasta» no corrige el inicio: empieza otro.
      setDesde(dia)
      setHasta(null)
      setModo('hasta')
    } else {
      setDesde(dia)
      setModo(hasta === null ? 'hasta' : 'nuevo')
    }
  }

  function aplicar(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault()
    // Va en un portal, pero el envío sube por el árbol de React: sin esto
    // enviaría también el formulario de la pantalla que tenga alrededor.
    evento.stopPropagation()
    if (desde !== null && hasta !== null) alAplicar({ from: desde, to: hasta })
  }

  const siguiente = modo === 'hasta' ? 'hasta' : 'desde'
  const completo = desde !== null && hasta !== null

  return (
    <form onSubmit={aplicar} noValidate className="flex flex-col gap-3 p-2">
      {titulo && (
        <p className="type-panel-caption font-semibold text-on-surface-variant">{titulo}</p>
      )}

      <div className="grid grid-cols-2 gap-2">
        <Casilla
          label="Desde"
          dia={desde}
          vacia="Elige un día"
          activa={siguiente === 'desde'}
          onClick={() => setModo('desde')}
        />
        <Casilla
          label="Hasta"
          dia={hasta}
          vacia={desde ? 'Elige el último' : '—'}
          activa={siguiente === 'hasta'}
          onClick={() => setModo(desde ? 'hasta' : 'nuevo')}
        />
      </div>

      <Calendario
        desde={desde}
        hasta={hasta}
        modo={modo}
        maximo={maximo}
        minimo={minimo}
        hoy={hoy ?? hoyEnCaracas()}
        onDia={elegir}
      />

      {/* Lima: es la acción de la capa. El tonal era del mismo gris que el
          fondo y el botón no se veía. */}
      <button type="submit" disabled={!completo} className={claseDeBoton('filled', 'sm')}>
        {completo ? `Aplicar · ${rangoCorto({ from: desde, to: hasta })}` : 'Aplicar'}
      </button>
    </form>
  )
}

/** Una de las dos casillas de arriba: qué día hay puesto y si es la que toca. */
function Casilla({
  label,
  dia,
  vacia,
  activa,
  onClick,
}: {
  label: string
  dia: string | null
  vacia: string
  activa: boolean
  onClick: () => void
}) {
  return (
    <button
      type="button"
      aria-pressed={activa}
      aria-label={`${label}: ${dia ? diaDicho(dia) : 'sin elegir'}`}
      onClick={onClick}
      className={`flex min-w-0 flex-col items-start gap-0.5 rounded-panel-control border bg-panel-raised px-2.5 py-1.5 text-left transition-colors duration-[var(--transition-fast)] ${
        activa ? 'border-primary' : 'border-transparent hover:border-panel-hairline-strong'
      }`}
    >
      <span className="type-panel-caption text-on-surface-variant">{label}</span>
      <span
        className={`w-full truncate type-panel-label tabular-nums ${
          dia ? 'text-on-surface' : 'font-normal text-placeholder'
        }`}
      >
        {dia ? diaConAnio(dia) : vacia}
      </span>
    </button>
  )
}

/**
 * El mes: flechas, las iniciales de la semana (lunes primero) y seis filas de
 * días. Los extremos del rango van en círculo blanco y el tramo entre ellos
 * en una banda; mientras se elige el segundo extremo, la banda sigue al
 * ratón. Hoy lleva un punto lima debajo.
 *
 * Con teclado es una rejilla: flechas de día en día y de semana en semana,
 * Inicio y Fin de la semana, Re Pág y Av Pág de mes en mes.
 */
function Calendario({
  desde,
  hasta,
  modo,
  maximo,
  minimo,
  hoy,
  onDia,
}: {
  desde: string | null
  hasta: string | null
  modo: Modo
  maximo?: string
  minimo?: string
  hoy: string
  onDia: (dia: string) => void
}) {
  const ancla = hasta ?? desde ?? (maximo && hoy > maximo ? maximo : hoy)
  const [mes, setMes] = useState(() => primeroDelMes(ancla))
  const [foco, setFoco] = useState(ancla)
  const [sobre, setSobre] = useState<string | null>(null)
  const [sentido, setSentido] = useState<'siguiente' | 'anterior' | null>(null)
  const rejillaRef = useRef<HTMLDivElement>(null)
  const enfocar = useRef(false)

  const casillas = casillasDelMes(mes)
  const focoVisible = casillas.includes(foco) ? foco : mes

  useEffect(() => {
    if (!enfocar.current) return
    enfocar.current = false
    rejillaRef.current?.querySelector<HTMLElement>(`[data-dia="${focoVisible}"]`)?.focus()
  }, [focoVisible])

  function fuera(dia: string): boolean {
    return (maximo !== undefined && dia > maximo) || (minimo !== undefined && dia < minimo)
  }

  function limitar(dia: string): string {
    if (maximo !== undefined && dia > maximo) return maximo
    if (minimo !== undefined && dia < minimo) return minimo
    return dia
  }

  function irAMes(destino: string) {
    if (destino === mes) return
    setSentido(destino > mes ? 'siguiente' : 'anterior')
    setMes(destino)
  }

  const hayAnterior = minimo === undefined || sumarDias(mes, -1) >= minimo
  const haySiguiente = maximo === undefined || mesDeAlLado(mes, 1) <= maximo

  function alTeclear(evento: KeyboardEvent<HTMLDivElement>) {
    const base = focoVisible
    const semana = diaDeLaSemana(base)
    const destinos: Partial<Record<string, () => string>> = {
      ArrowLeft: () => sumarDias(base, -1),
      ArrowRight: () => sumarDias(base, 1),
      ArrowUp: () => sumarDias(base, -7),
      ArrowDown: () => sumarDias(base, 7),
      Home: () => sumarDias(base, -semana),
      End: () => sumarDias(base, 6 - semana),
      PageUp: () => mismoDiaDeOtroMes(base, -1),
      PageDown: () => mismoDiaDeOtroMes(base, 1),
    }
    const calcular = destinos[evento.key]
    if (!calcular) return
    evento.preventDefault()
    const destino = limitar(calcular())
    irAMes(primeroDelMes(destino))
    setFoco(destino)
    setSobre(destino)
    enfocar.current = true
  }

  // La banda: el rango puesto o, mientras se elige un extremo, el que saldría
  // con el día que está bajo el ratón.
  let bandaDesde = desde
  let bandaHasta = hasta
  let previa = false
  if (sobre !== null && !fuera(sobre)) {
    if (modo === 'hasta' && desde !== null && sobre >= desde) {
      bandaHasta = sobre
      previa = sobre !== hasta
    } else if (modo === 'desde' && hasta !== null && sobre <= hasta) {
      bandaDesde = sobre
      previa = sobre !== desde
    }
  }

  const [anio = '', numeroDeMes = ''] = mes.split('-')
  const semanas = Array.from({ length: 6 }, (_, i) => casillas.slice(i * 7, i * 7 + 7))

  return (
    <div className="flex flex-col gap-1">
      <div className="flex items-center justify-between">
        <FlechaDeMes
          rotulo="Mes anterior"
          disabled={!hayAnterior}
          onClick={() => irAMes(mesDeAlLado(mes, -1))}
        >
          <ChevronLeft size={16} aria-hidden />
        </FlechaDeMes>
        <p aria-live="polite" className="type-panel-control text-on-surface">
          <span className="capitalize">{MESES_LARGOS[Number(numeroDeMes) - 1]}</span>{' '}
          <span className="text-on-surface-variant">{anio}</span>
        </p>
        <FlechaDeMes
          rotulo="Mes siguiente"
          disabled={!haySiguiente}
          onClick={() => irAMes(mesDeAlLado(mes, 1))}
        >
          <ChevronRight size={16} aria-hidden />
        </FlechaDeMes>
      </div>

      <div
        ref={rejillaRef}
        role="grid"
        aria-label={`${MESES_LARGOS[Number(numeroDeMes) - 1]} de ${anio}`}
        onKeyDown={alTeclear}
        onMouseLeave={() => setSobre(null)}
        className="overflow-hidden"
      >
        <div role="row" className="grid grid-cols-7 pb-1">
          {INICIALES.map((inicial, i) => (
            <span
              key={inicial}
              role="columnheader"
              aria-label={DIAS[i]}
              className={`flex h-7 items-center justify-center type-panel-caption ${
                i >= 5 ? 'text-on-surface-variant' : 'text-panel-muted'
              }`}
            >
              {inicial}
            </span>
          ))}
        </div>

        <div
          key={mes}
          className={`flex flex-col gap-0.5 ${sentido ? `anim-mes-${sentido}` : ''}`}
        >
          {semanas.map((semana) => (
            <div key={semana[0]} role="row" className="grid grid-cols-7">
              {semana.map((dia, columna) => {
                const apagado = fuera(dia)
                const delMes = dia.slice(0, 7) === mes.slice(0, 7)
                const puesto = dia === desde || dia === hasta
                const esInicio = dia === bandaDesde
                const esFin = dia === bandaHasta
                const extremoPrevio = previa && (esInicio || esFin) && !puesto
                const enBanda =
                  bandaDesde !== null &&
                  bandaHasta !== null &&
                  bandaDesde < bandaHasta &&
                  dia >= bandaDesde &&
                  dia <= bandaHasta

                const aspecto = puesto
                  ? 'bg-on-surface font-semibold text-on-inverse-surface'
                  : extremoPrevio
                    ? 'text-on-surface ring-1 ring-inset ring-on-surface/60'
                    : apagado
                      ? 'cursor-not-allowed text-on-surface-faint/60'
                      : delMes
                        ? 'text-on-surface hover:bg-on-surface/12'
                        : 'text-panel-muted hover:bg-on-surface/12'

                return (
                  <div
                    key={dia}
                    role="gridcell"
                    aria-selected={puesto || (enBanda && !previa)}
                    className="relative flex h-9 items-center justify-center"
                  >
                    {enBanda && (
                      <span
                        aria-hidden
                        className={`absolute inset-y-0 ${esInicio ? 'left-1/2' : 'left-0'} ${
                          esFin ? 'right-1/2' : 'right-0'
                        } ${columna === 0 && !esInicio ? 'rounded-l-full' : ''} ${
                          columna === 6 && !esFin ? 'rounded-r-full' : ''
                        } ${previa ? 'bg-on-surface/6' : 'bg-on-surface/10'}`}
                      />
                    )}
                    <button
                      type="button"
                      data-dia={dia}
                      tabIndex={dia === focoVisible ? 0 : -1}
                      disabled={apagado}
                      aria-label={diaDicho(dia)}
                      aria-current={dia === hoy ? 'date' : undefined}
                      onClick={() => {
                        setFoco(dia)
                        onDia(dia)
                      }}
                      onMouseEnter={() => setSobre(dia)}
                      className={`relative inline-flex size-9 items-center justify-center rounded-full type-panel-label tabular-nums outline-none transition-colors duration-[var(--transition-fast)] focus-visible:ring-2 focus-visible:ring-primary ${aspecto}`}
                    >
                      {Number(dia.slice(8, 10))}
                      {dia === hoy && (
                        <span
                          aria-hidden
                          className={`absolute bottom-1 left-1/2 size-1 -translate-x-1/2 rounded-full ${
                            puesto ? 'bg-on-inverse-surface' : 'bg-primary'
                          }`}
                        />
                      )}
                    </button>
                  </div>
                )
              })}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

function FlechaDeMes({
  rotulo,
  disabled,
  onClick,
  children,
}: {
  rotulo: string
  disabled: boolean
  onClick: () => void
  children: ReactNode
}) {
  return (
    <button
      type="button"
      aria-label={rotulo}
      disabled={disabled}
      onClick={onClick}
      className="inline-flex size-8 items-center justify-center rounded-panel-control text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:bg-panel-raised hover:text-on-surface disabled:pointer-events-none disabled:opacity-35"
    >
      {children}
    </button>
  )
}
