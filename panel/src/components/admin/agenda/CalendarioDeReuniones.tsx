import { useMemo, useState } from 'react'
import { CalendarDays, ChevronLeft, ChevronRight, GraduationCap, Phone, Users } from 'lucide-react'

import { Button, EmptyState, IconButton } from '@/components/ui'
import { MESES_LARGOS } from '@/components/kit/rango'
import { ROTULO_MODO, casillasDelMes, citasDe, mesDeAlLado, rotuloDelDia } from '@/features/admin/agenda/agenda'
import type { Cita, Lead } from '@/features/admin/agenda/agenda'

const INICIALES = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom']

/** Lo que cabe en una casilla antes de «+2 más». */
const POR_CASILLA = 3

/** Los puntos que caben en una casilla del teléfono antes de «+». */
const PUNTOS_POR_CASILLA = 3

/** Cuántas citas enseña la lista de las próximas. */
const PROXIMAS = 25

function nombreDelMes(mes: string): string {
  const [y = '', m = '1'] = mes.split('-')
  const nombre = MESES_LARGOS[Number(m) - 1] ?? m
  return `${nombre.charAt(0).toUpperCase()}${nombre.slice(1)} ${y}`
}

function claseDeCita(c: Cita, hoy: string): string {
  const pasada = c.dia < hoy
  if (c.tipo === 'llamada') return 'bg-on-surface/6 text-on-surface-variant'
  return pasada ? 'bg-on-surface/6 text-on-surface-variant line-through' : 'bg-primary/12 text-on-surface'
}

/** «2 visitas y 1 llamada», para el nombre de la casilla en el teléfono. */
function describirCitas(citas: ReadonlyArray<Cita>): string {
  const visitas = citas.filter((c) => c.tipo === 'visita').length
  const llamadas = citas.length - visitas
  return [
    visitas > 0 ? `${visitas} ${visitas === 1 ? 'visita' : 'visitas'}` : null,
    llamadas > 0 ? `${llamadas} ${llamadas === 1 ? 'llamada' : 'llamadas'}` : null,
  ]
    .filter(Boolean)
    .join(' y ')
}

/**
 * La agenda en calendario: el mes con cada visita (a su hora) y cada día de
 * volver a llamar, y al lado las próximas citas en orden. La capacitación
 * presencial que pidió un médico en el formulario sale con su birrete. Un
 * clic en una cita abre la ficha del médico. El mes va en la URL (`?mes=`).
 *
 * En el teléfono (por debajo de 640 px) una casilla mide unos 48 px y no cabe
 * un nombre: cada día es un botón con un punto por cita, y debajo del mes
 * salen las citas del día elegido. Antes cada punto era un botón, y el mínimo
 * táctil de 44 px (styles.css) los convertía en círculos que ensanchaban el
 * mes por encima de la pantalla.
 */
export function CalendarioDeReuniones({
  leads,
  mes,
  hoy,
  conLlamadas,
  onMes,
  onAbrir,
}: {
  leads: ReadonlyArray<Lead>
  /** El día 1 del mes que se mira, 'YYYY-MM-01'. */
  mes: string
  hoy: string
  /** Si salen también los días de volver a llamar. */
  conLlamadas: boolean
  onMes: (mes: string) => void
  onAbrir: (lead: Lead) => void
}) {
  const citas = useMemo(
    () => citasDe(leads).filter((c) => conLlamadas || c.tipo === 'visita'),
    [leads, conLlamadas],
  )
  const porDia = useMemo(() => {
    const mapa = new Map<string, Cita[]>()
    for (const c of citas) mapa.set(c.dia, [...(mapa.get(c.dia) ?? []), c])
    return mapa
  }, [citas])

  const casillas = casillasDelMes(mes)
  const mesHoy = `${hoy.slice(0, 7)}-01`
  const proximas = citas.filter((c) => c.dia >= hoy).slice(0, PROXIMAS)
  const delMes = citas.filter((c) => c.dia.startsWith(mes.slice(0, 7)))
  const visitasDelMes = delMes.filter((c) => c.tipo === 'visita').length

  // El día que se mira en el teléfono. Si no es de este mes (se cambió de
  // mes), vale el de hoy si cae en él, y si no, el primero con citas.
  const [elegido, setElegido] = useState<string | null>(null)
  const delMesVisto = (dia: string | null) => dia !== null && dia.startsWith(mes.slice(0, 7))
  const diaVisto = delMesVisto(elegido)
    ? elegido
    : delMesVisto(hoy)
      ? hoy
      : (delMes[0]?.dia ?? null)
  const citasDelDiaVisto = diaVisto ? (porDia.get(diaVisto) ?? []) : []

  return (
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
      <section className="flex min-w-0 flex-col gap-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="min-w-0">
            <h2 className="type-panel-section text-on-surface">{nombreDelMes(mes)}</h2>
            <p className="type-panel-caption text-on-surface-variant">
              {visitasDelMes} {visitasDelMes === 1 ? 'visita' : 'visitas'}
              {conLlamadas ? ` · ${delMes.length - visitasDelMes} para llamar` : ''}
            </p>
          </div>
          <div className="flex items-center gap-1">
            {mes !== mesHoy && (
              <Button size="sm" variant="text" onClick={() => onMes(mesHoy)}>
                Este mes
              </Button>
            )}
            <IconButton label="Mes anterior" onClick={() => onMes(mesDeAlLado(mes, -1))}>
              <ChevronLeft size={18} aria-hidden />
            </IconButton>
            <IconButton label="Mes siguiente" onClick={() => onMes(mesDeAlLado(mes, 1))}>
              <ChevronRight size={18} aria-hidden />
            </IconButton>
          </div>
        </div>

        <div className="overflow-hidden rounded-panel-card border border-panel-hairline">
          <div className="grid grid-cols-7 border-b border-panel-hairline bg-panel-raised">
            {INICIALES.map((d) => (
              <div
                key={d}
                className="min-w-0 truncate px-0.5 py-1.5 text-center type-panel-caption text-on-surface-variant sm:px-2 sm:text-left"
              >
                {d}
              </div>
            ))}
          </div>
          <div className="grid grid-cols-7">
            {casillas.map((dia, i) => {
              const delDia = porDia.get(dia) ?? []
              const fuera = !dia.startsWith(mes.slice(0, 7))
              const esHoy = dia === hoy
              const visto = dia === diaVisto
              const numero = (
                <span
                  className={`inline-flex size-6 items-center justify-center rounded-full type-panel-caption tabular-nums ${
                    esHoy ? 'bg-primary font-semibold text-on-primary' : fuera ? 'text-panel-muted' : 'text-on-surface-variant'
                  }`}
                >
                  {Number(dia.slice(8, 10))}
                </span>
              )
              return (
                <div
                  key={dia}
                  className={`min-w-0 border-panel-hairline ${i % 7 !== 6 ? 'border-r' : ''} ${
                    i < casillas.length - 7 ? 'border-b' : ''
                  } ${fuera ? 'bg-panel-raised/60' : ''}`}
                >
                  {/* El teléfono: el día entero se pulsa y elige qué citas
                      salen debajo del mes. `en-linea`: la casilla ya mide lo
                      que mide, y el mínimo táctil la descuadraría. */}
                  <button
                    type="button"
                    aria-pressed={visto}
                    aria-label={`${rotuloDelDia(dia, hoy)}${delDia.length > 0 ? `: ${describirCitas(delDia)}` : ''}`}
                    onClick={() => setElegido(dia)}
                    className={`en-linea flex h-14 w-full flex-col items-center gap-1 pt-1 transition-colors sm:hidden ${
                      visto ? 'bg-primary/10 shadow-[inset_0_0_0_2px_var(--color-primary)]' : 'active:bg-panel-raised'
                    }`}
                  >
                    {numero}
                    {delDia.length > 0 && (
                      <span aria-hidden className="flex items-center gap-0.5">
                        {delDia.slice(0, PUNTOS_POR_CASILLA).map((c) => (
                          <span
                            key={`${c.lead.id}:${c.tipo}`}
                            className={`size-1.5 rounded-full ${c.tipo === 'visita' ? 'bg-primary' : 'bg-on-surface-variant'}`}
                          />
                        ))}
                        {delDia.length > PUNTOS_POR_CASILLA && (
                          <span className="text-[10px] leading-none text-on-surface-variant">+</span>
                        )}
                      </span>
                    )}
                  </button>

                  {/* Desde 640 px: el día con sus citas escritas. */}
                  <div className="hidden min-h-24 flex-col gap-1 p-1.5 sm:flex">
                    <span className="self-end">{numero}</span>
                    <ul className="flex flex-col gap-0.5">
                      {delDia.slice(0, POR_CASILLA).map((c) => (
                        <li key={`${c.lead.id}:${c.tipo}`}>
                          <button
                            type="button"
                            title={`${c.hora ? `${c.hora} · ` : 'Llamar · '}${c.capacitacion ? 'Capacitación · ' : ''}${c.lead.nombre}`}
                            className={`w-full truncate rounded px-1.5 py-0.5 text-left type-panel-caption hover:brightness-95 ${claseDeCita(c, hoy)}`}
                            onClick={() => onAbrir(c.lead)}
                          >
                            {c.hora ? <span className="tabular-nums">{c.hora} </span> : <Phone size={11} aria-hidden className="mr-1 inline" />}
                            {c.capacitacion && <GraduationCap size={11} aria-label="Capacitación" className="mr-1 inline" />}
                            {c.lead.nombre}
                          </button>
                        </li>
                      ))}
                      {delDia.length > POR_CASILLA && (
                        <li className="px-1.5 type-panel-caption text-on-surface-variant">
                          +{delDia.length - POR_CASILLA} más
                        </li>
                      )}
                    </ul>
                  </div>
                </div>
              )
            })}
          </div>
        </div>

        {/* Solo en el teléfono: lo del día elegido, con el mismo aspecto que
            las próximas. Se anuncia al cambiar de día. */}
        {diaVisto && (
          <div className="flex flex-col gap-1.5 sm:hidden" aria-live="polite">
            <p className="type-panel-caption font-semibold text-on-surface">{rotuloDelDia(diaVisto, hoy)}</p>
            {citasDelDiaVisto.length === 0 ? (
              <p className="type-panel-caption text-on-surface-variant">Nada agendado ese día.</p>
            ) : (
              <ListaDeCitas citas={citasDelDiaVisto} onAbrir={onAbrir} />
            )}
          </div>
        )}
      </section>

      <section className="flex min-w-0 flex-col gap-3">
        <h2 className="type-panel-label text-on-surface-variant">Próximas</h2>
        {proximas.length === 0 ? (
          <EmptyState
            icon={<CalendarDays size={32} />}
            title="Nada agendado"
            description="Agenda una visita desde la ficha de un médico: «Anotar gestión» › Visita."
          />
        ) : (
          <ol className="flex flex-col gap-4">
            {agruparPorDia(proximas).map(([dia, delDia]) => (
              <li key={dia} className="flex flex-col gap-1.5">
                <p className="type-panel-caption font-semibold text-on-surface">{rotuloDelDia(dia, hoy)}</p>
                <ListaDeCitas citas={delDia} onAbrir={onAbrir} />
              </li>
            ))}
          </ol>
        )}
      </section>
    </div>
  )
}

/** Las citas de un día, cada una con su icono, el médico y la hora o «Volver a llamar». */
function ListaDeCitas({ citas, onAbrir }: { citas: ReadonlyArray<Cita>; onAbrir: (lead: Lead) => void }) {
  return (
    <ul className="flex flex-col gap-1.5">
      {citas.map((c) => (
        <li key={`${c.lead.id}:${c.tipo}`}>
          <button
            type="button"
            className="flex w-full min-w-0 items-start gap-2 rounded-panel-control border border-panel-hairline px-3 py-2 text-left hover:bg-panel-raised"
            onClick={() => onAbrir(c.lead)}
          >
            {c.capacitacion ? (
              <GraduationCap size={15} aria-hidden className="mt-0.5 shrink-0 text-primary" />
            ) : c.tipo === 'visita' ? (
              <Users size={15} aria-hidden className="mt-0.5 shrink-0 text-primary" />
            ) : (
              <Phone size={15} aria-hidden className="mt-0.5 shrink-0 text-on-surface-variant" />
            )}
            <span className="min-w-0">
              <span className="block truncate type-panel-body text-on-surface">{c.lead.nombre}</span>
              <span className="block truncate type-panel-caption text-on-surface-variant">
                {c.tipo === 'visita'
                  ? [
                      c.hora,
                      c.capacitacion ? 'Capacitación presencial' : c.lead.modo ? ROTULO_MODO[c.lead.modo] : null,
                      c.lead.lugar,
                    ]
                      .filter(Boolean)
                      .join(' · ')
                  : 'Volver a llamar'}
              </span>
            </span>
          </button>
        </li>
      ))}
    </ul>
  )
}

function agruparPorDia(citas: ReadonlyArray<Cita>): Array<[string, Cita[]]> {
  const grupos: Array<[string, Cita[]]> = []
  for (const c of citas) {
    const ultimo = grupos.at(-1)
    if (ultimo && ultimo[0] === c.dia) ultimo[1].push(c)
    else grupos.push([c.dia, [c]])
  }
  return grupos
}
