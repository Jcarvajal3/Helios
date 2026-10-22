import { useMemo } from 'react'
import { CalendarDays, ChevronLeft, ChevronRight, Phone, Users } from 'lucide-react'

import { Button, EmptyState, IconButton, formatDayShort } from '@/components/ui'
import { MESES_LARGOS, sumarDias } from '@/components/kit/rango'
import { ROTULO_MODO, casillasDelMes, citasDe, mesDeAlLado } from '@/features/admin/agenda/agenda'
import type { Cita, Lead } from '@/features/admin/agenda/agenda'

const INICIALES = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom']
const DIAS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado']

/** Lo que cabe en una casilla antes de «+2 más». */
const POR_CASILLA = 3

/** Cuántas citas enseña la lista de las próximas. */
const PROXIMAS = 25

function nombreDelMes(mes: string): string {
  const [y = '', m = '1'] = mes.split('-')
  const nombre = MESES_LARGOS[Number(m) - 1] ?? m
  return `${nombre.charAt(0).toUpperCase()}${nombre.slice(1)} ${y}`
}

/** 'Jueves 23 oct', o 'Hoy' / 'Mañana'. */
function rotuloDelDia(dia: string, hoy: string, manana: string): string {
  if (dia === hoy) return 'Hoy'
  if (dia === manana) return 'Mañana'
  const [y = 0, m = 1, d = 1] = dia.split('-').map(Number)
  const semana = DIAS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()] ?? ''
  return `${semana.charAt(0).toUpperCase()}${semana.slice(1)} ${formatDayShort(dia)}`
}

function claseDeCita(c: Cita, hoy: string): string {
  const pasada = c.dia < hoy
  if (c.tipo === 'llamada') return 'bg-on-surface/6 text-on-surface-variant'
  return pasada ? 'bg-on-surface/6 text-on-surface-variant line-through' : 'bg-primary/12 text-on-surface'
}

/**
 * La agenda en calendario: el mes con cada reunión (a su hora) y cada día de
 * volver a llamar, y al lado las próximas citas en orden. Un clic en una cita
 * abre la ficha del médico. El mes va en la URL (`?mes=`).
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
    () => citasDe(leads).filter((c) => conLlamadas || c.tipo === 'reunion'),
    [leads, conLlamadas],
  )
  const porDia = useMemo(() => {
    const mapa = new Map<string, Cita[]>()
    for (const c of citas) mapa.set(c.dia, [...(mapa.get(c.dia) ?? []), c])
    return mapa
  }, [citas])

  const casillas = casillasDelMes(mes)
  const mesHoy = `${hoy.slice(0, 7)}-01`
  const manana = sumarDias(hoy, 1)
  const proximas = citas.filter((c) => c.dia >= hoy).slice(0, PROXIMAS)
  const delMes = citas.filter((c) => c.dia.startsWith(mes.slice(0, 7)))
  const reunionesDelMes = delMes.filter((c) => c.tipo === 'reunion').length

  return (
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
      <section className="flex min-w-0 flex-col gap-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h2 className="type-panel-section text-on-surface">{nombreDelMes(mes)}</h2>
            <p className="type-panel-caption text-on-surface-variant">
              {reunionesDelMes} {reunionesDelMes === 1 ? 'reunión' : 'reuniones'}
              {conLlamadas ? ` · ${delMes.length - reunionesDelMes} para llamar` : ''}
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
              <div key={d} className="px-2 py-1.5 type-panel-caption text-on-surface-variant">
                {d}
              </div>
            ))}
          </div>
          <div className="grid grid-cols-7">
            {casillas.map((dia, i) => {
              const delDia = porDia.get(dia) ?? []
              const fuera = !dia.startsWith(mes.slice(0, 7))
              const esHoy = dia === hoy
              return (
                <div
                  key={dia}
                  className={`flex min-h-16 flex-col gap-1 border-panel-hairline p-1 sm:min-h-24 sm:p-1.5 ${
                    i % 7 !== 6 ? 'border-r' : ''
                  } ${i < casillas.length - 7 ? 'border-b' : ''} ${fuera ? 'bg-panel-raised/60' : ''}`}
                >
                  <span
                    className={`inline-flex size-6 items-center justify-center self-end rounded-full type-panel-caption tabular-nums ${
                      esHoy ? 'bg-primary font-semibold text-on-primary' : fuera ? 'text-panel-muted' : 'text-on-surface-variant'
                    }`}
                  >
                    {Number(dia.slice(8, 10))}
                  </span>
                  {/* En el teléfono no cabe el texto: un punto por cita, y la lista de al lado. */}
                  <div className="flex flex-wrap gap-0.5 sm:hidden">
                    {delDia.map((c) => (
                      <button
                        key={`${c.lead.id}:${c.tipo}`}
                        type="button"
                        aria-label={`${c.tipo === 'reunion' ? 'Reunión' : 'Llamar a'} ${c.lead.nombre}`}
                        className={`size-2 rounded-full ${c.tipo === 'reunion' ? 'bg-primary' : 'bg-on-surface-variant'}`}
                        onClick={() => onAbrir(c.lead)}
                      />
                    ))}
                  </div>
                  <ul className="hidden flex-col gap-0.5 sm:flex">
                    {delDia.slice(0, POR_CASILLA).map((c) => (
                      <li key={`${c.lead.id}:${c.tipo}`}>
                        <button
                          type="button"
                          title={`${c.hora ? `${c.hora} · ` : 'Llamar · '}${c.lead.nombre}`}
                          className={`w-full truncate rounded px-1.5 py-0.5 text-left type-panel-caption hover:brightness-95 ${claseDeCita(c, hoy)}`}
                          onClick={() => onAbrir(c.lead)}
                        >
                          {c.hora ? <span className="tabular-nums">{c.hora} </span> : <Phone size={11} aria-hidden className="mr-1 inline" />}
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
              )
            })}
          </div>
        </div>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="type-panel-label text-on-surface-variant">Próximas</h2>
        {proximas.length === 0 ? (
          <EmptyState
            icon={<CalendarDays size={32} />}
            title="Nada agendado"
            description="Agenda una reunión desde la ficha de un médico: «Queda en» › Reunión agendada."
          />
        ) : (
          <ol className="flex flex-col gap-4">
            {agruparPorDia(proximas).map(([dia, delDia]) => (
              <li key={dia} className="flex flex-col gap-1.5">
                <p className="type-panel-caption font-semibold text-on-surface">{rotuloDelDia(dia, hoy, manana)}</p>
                <ul className="flex flex-col gap-1.5">
                  {delDia.map((c) => (
                    <li key={`${c.lead.id}:${c.tipo}`}>
                      <button
                        type="button"
                        className="flex w-full items-start gap-2 rounded-panel-control border border-panel-hairline px-3 py-2 text-left hover:bg-panel-raised"
                        onClick={() => onAbrir(c.lead)}
                      >
                        {c.tipo === 'reunion' ? (
                          <Users size={15} aria-hidden className="mt-0.5 shrink-0 text-primary" />
                        ) : (
                          <Phone size={15} aria-hidden className="mt-0.5 shrink-0 text-on-surface-variant" />
                        )}
                        <span className="min-w-0">
                          <span className="block truncate type-panel-body text-on-surface">{c.lead.nombre}</span>
                          <span className="block truncate type-panel-caption text-on-surface-variant">
                            {c.tipo === 'reunion'
                              ? [c.hora, c.lead.modo ? ROTULO_MODO[c.lead.modo] : null, c.lead.lugar]
                                  .filter(Boolean)
                                  .join(' · ')
                              : 'Volver a llamar'}
                          </span>
                        </span>
                      </button>
                    </li>
                  ))}
                </ul>
              </li>
            ))}
          </ol>
        )}
      </section>
    </div>
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
