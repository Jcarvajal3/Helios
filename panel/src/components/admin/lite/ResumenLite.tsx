import { useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { queryOptions, useQuery } from '@tanstack/react-query'
import { ArrowRight, CalendarDays, RotateCw } from 'lucide-react'

import { HeliosIsotipo } from '@/components/HeliosLogo'
import { ordenarColas, tieneTrabajo } from '@/components/admin/inicio/colas'
import { useColas } from '@/components/admin/inicio/useColas'
import type { ColaDeInicio } from '@/components/admin/inicio/useColas'
import { useImpagoPrimeraCuota } from '@/components/admin/inicio/useCifrasDeHoy'
import { useCuentaDelPanel } from '@/components/layouts/cuenta'
import { diaOperativo, formatPct, formatUsd } from '@/components/ui'
import { sumarDias } from '@/components/kit/rango'
import { fetchMerchants } from '@/features/admin/api'
import { consultaDirectorio } from '@/features/admin/directorioDeMedicos/api'
import type { MedicoEnElDirectorio, TableroDelDirectorio } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import { consultaDeJuanPablo } from '@/features/admin/metricas/juan-pablo/api'
import type { JuanPablo } from '@/features/admin/metricas/juan-pablo/lectura'
import { nombreDeEspecialidad } from '@/features/directorio/especialidades'
import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'
import { comoFila, comoLista, numero } from '@/lib/json'
import { supabase } from '@/lib/supabase'

/**
 * El Resumen de Helios Lite: cómo va el negocio en el periodo y qué necesita
 * atención, con datos reales.
 *
 * No tiene lecturas propias: usa las mismas que Pro (Métricas › Juan Pablo,
 * el tablero del Directorio, las colas de Inicio, el impago de la cuota 1),
 * así que una cifra dice lo mismo en las dos versiones y comparte su caché.
 *
 * El periodo es hoy, 7 o 30 días hasta hoy: los clics al WhatsApp solo se
 * guardan por día los últimos 30 (`admin_directorio`), y un periodo más
 * largo o en el pasado los dejaría a cero sin decirlo.
 */
type Periodo = 'hoy' | '7d' | '30d'

const PERIODOS: ReadonlyArray<{ id: Periodo; rotulo: string; dias: number }> = [
  { id: 'hoy', rotulo: 'Hoy', dias: 1 },
  { id: '7d', rotulo: 'Últimos 7 días', dias: 7 },
  { id: '30d', rotulo: 'Últimos 30 días', dias: 30 },
]

const ENTERO = new Intl.NumberFormat('es-VE')

/** Los cinco tonos del reparto, del azul de la marca al más claro. */
const TONOS = ['#ffffff', '#cfe3ff', '#9ec7ff', '#6aa9ff', '#3d8dff']

export function ResumenLite() {
  const [periodo, setPeriodo] = useState<Periodo>('7d')
  const dias = PERIODOS.find((p) => p.id === periodo)?.dias ?? 7
  const hoy = diaOperativo()
  const rango = { from: sumarDias(hoy, -(dias - 1)), to: hoy }

  const cuenta = useCuentaDelPanel()
  const nombre = cuenta?.nombreDePila ?? null

  const metricas = useQuery(consultaDeJuanPablo(rango))
  const directorio = useQuery(consultaDirectorio())
  const altas = useQuery({ queryKey: ['merchants'], queryFn: fetchMerchants })
  const citas = useQuery(consultaCitasAgendadas(rango.from))
  const impago = useImpagoPrimeraCuota()

  const clics = useMemo(() => (directorio.data ? clicsDelPeriodo(directorio.data, dias) : null), [directorio.data, dias])
  const filas = useMemo(
    () => (directorio.data && metricas.data ? actividadPorMedico(directorio.data, metricas.data, dias) : null),
    [directorio.data, metricas.data, dias],
  )

  const medicosLive = directorio.data?.medicos.filter((m) => m.visible && m.bloqueo === null && !m.esPrueba).length
  const medicosNuevos = altas.data?.filter((m) => !m.isTest && diaDeCaracas(m.createdAt) >= rango.from).length

  return (
    <div className="flex flex-col gap-5">
      {/* La portada: el símbolo, el saludo y el periodo. */}
      <section className="relative flex flex-col items-center gap-4 pt-4 pb-2 text-center">
        <HeliosIsotipo size={84} className="lite-rayos lite-simbolo" aria-hidden />
        <h1 className="text-[1.05rem] font-medium text-panel-muted">
          Bienvenido,
          <span className="block text-[2.4rem] leading-tight font-semibold tracking-[-0.04em] text-[#157EFD]">
            {nombre ?? 'equipo de Helios'}
          </span>
        </h1>
        <div role="radiogroup" aria-label="Periodo" className="lite-capsula mt-1 flex items-center gap-1 rounded-full p-1">
          <CalendarDays size={15} aria-hidden className="ml-2 text-[#157EFD]" />
          {PERIODOS.map((p) => (
            <button
              key={p.id}
              type="button"
              role="radio"
              aria-checked={periodo === p.id}
              onClick={() => setPeriodo(p.id)}
              className={`rounded-full px-3 py-1 text-[0.8rem] font-medium ${
                periodo === p.id ? 'bg-[#157EFD] text-white' : 'text-panel-muted hover:text-on-surface'
              }`}
            >
              {p.rotulo}
            </button>
          ))}
        </div>
      </section>

      {/* Las cifras, en tres grupos, y al lado lo que necesita atención. */}
      <div className="grid gap-4 xl:grid-cols-[minmax(0,3fr)_minmax(300px,1fr)]">
        <div className="grid gap-4 md:grid-cols-3">
          <Grupo titulo="Pacientes y consultas">
            <Cifra
              rotulo="Clics a WhatsApp"
              a="/admin/directorio"
              valor={clics ? ENTERO.format(clics.clics) : undefined}
              pie={
                clics?.visitantes !== null && clics?.visitantes !== undefined
                  ? `${ENTERO.format(clics.visitantes)} navegadores distintos`
                  : 'desde el directorio público'
              }
              lectura={directorio}
            />
            <Cifra
              rotulo="Consultas en Helios"
              a="/admin/financiamientos"
              valor={metricas.data ? ENTERO.format(metricas.data.ordenes) : undefined}
              pie="órdenes confirmadas"
              lectura={metricas}
            />
          </Grupo>

          <Grupo titulo="Volumen e ingresos">
            <Cifra
              rotulo="GTV · valor de consultas"
              a="/admin/metricas"
              valor={metricas.data ? formatUsd(metricas.data.gtvUsd) : undefined}
              pie="sin la Comisión Helios"
              lectura={metricas}
            />
            <Cifra
              rotulo="Comisión Helios"
              a="/admin/metricas"
              valor={metricas.data ? formatUsd(metricas.data.revenueUsd) : undefined}
              pie={
                metricas.data?.revenuePct !== null && metricas.data?.revenuePct !== undefined
                  ? `${formatPct(metricas.data.revenuePct)} del GTV · sin IVA`
                  : 'generada · sin IVA'
              }
              lectura={metricas}
            />
            <Cifra
              rotulo="Impago de la 1.ª cuota"
              a="/admin/metricas"
              valor={
                impago.estado === 'listo'
                  ? impago.datos.pct === null
                    ? 'Sin mes maduro'
                    : formatPct(impago.datos.pct)
                  : undefined
              }
              pie={impago.estado === 'listo' && impago.datos.mes ? `consumos de ${impago.datos.mes.rotulo}` : 'último mes maduro'}
              lectura={
                impago.estado === 'error'
                  ? { isError: true, refetch: impago.reintentar }
                  : { isError: false, refetch: () => undefined }
              }
            />
          </Grupo>

          <Grupo titulo="Red de médicos">
            <Cifra
              rotulo="Médicos visibles"
              a="/admin/directorio"
              valor={medicosLive === undefined ? undefined : ENTERO.format(medicosLive)}
              pie="publicados en el directorio, hoy"
              lectura={directorio}
            />
            <Cifra
              rotulo="Médicos sumados"
              a="/admin/clinicas"
              valor={medicosNuevos === undefined ? undefined : ENTERO.format(medicosNuevos)}
              pie="clínicas dadas de alta en el periodo"
              lectura={altas}
            />
            <Cifra
              rotulo="Visitas agendadas"
              a="/admin/agenda"
              valor={citas.data === undefined ? undefined : ENTERO.format(citas.data)}
              pie="anotadas en la Agenda en el periodo"
              lectura={citas}
            />
          </Grupo>
        </div>

        <NecesitaAtencion />
      </div>

      <RepartoPorEspecialidad filas={filas} />

      <div className="grid gap-4 xl:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]">
        <InteresEnElTiempo tablero={directorio.data} dias={Math.max(dias, 7)} />
        <ActividadPorMedico filas={filas} cargando={directorio.isPending || metricas.isPending} />
      </div>
    </div>
  )
}

// ── Lecturas ───────────────────────────────────────────────────────────────

/**
 * Las visitas agendadas desde `desde` hasta ahora, de todo el equipo. Es la
 * misma RPC que la pestaña de actividad de la Agenda, con su `p_desde`.
 */
function consultaCitasAgendadas(desde: string) {
  return queryOptions({
    queryKey: ['agenda', 'actividad', 'desde', desde],
    queryFn: async (): Promise<number> => {
      const { data, error } = await supabase.rpc('admin_agenda_activity_by_person', { p_desde: desde })
      if (error) throw error
      return comoLista(data).reduce<number>((s, f) => s + numero(comoFila(f).visitas_agendadas), 0)
    },
    staleTime: 60_000,
  })
}

/** El día de Caracas de un instante: el alta de las 9 p. m. es de ese día, no del siguiente en UTC. */
function diaDeCaracas(instante: string): string {
  return diaOperativo(new Date(instante))
}

/** La suma de los últimos `dias` de una serie que acaba hoy. */
function ultimos(serie: ReadonlyArray<number>, dias: number): number {
  return serie.slice(-dias).reduce((s, n) => s + n, 0)
}

/**
 * Los clics del periodo y, cuando la base los cuenta exactos, los
 * navegadores distintos: hoy y los 30 días. Para 7 días no se pueden sumar los
 * de cada día (el mismo navegador contaría varias veces), así que no se dan.
 */
function clicsDelPeriodo(t: TableroDelDirectorio, dias: number): { clics: number; visitantes: number | null } {
  const clics = ultimos(t.porDia.map((d) => d.clics), dias)
  const visitantes = dias === 1 ? (t.porDia.at(-1)?.visitantes ?? 0) : dias === 30 ? t.totales.visitantes30d : null
  return { clics, visitantes }
}

type FilaDeActividad = {
  id: string
  nombre: string
  especialidad: string | null
  clave: ClaveDeEspecialidad
  clics: number
  ordenes: number
}

/** Cada médico real con sus clics y sus órdenes del periodo, el que más interés despertó primero. */
function actividadPorMedico(t: TableroDelDirectorio, m: JuanPablo, dias: number): FilaDeActividad[] {
  const ordenes = new Map(m.porMedico.map((p) => [p.merchantId, p.ordenes]))
  return t.medicos
    .filter((d: MedicoEnElDirectorio) => !d.esPrueba && d.estado !== 'terminated')
    .map((d) => ({
      id: d.id,
      nombre: d.tarjeta.nombre || d.clinica,
      especialidad: d.tarjeta.especialidad,
      clave: d.tarjeta.clave,
      clics: ultimos(d.clics.porDia, dias),
      ordenes: ordenes.get(d.id) ?? 0,
    }))
    .sort((a, b) => b.clics - a.clics || b.ordenes - a.ordenes || a.nombre.localeCompare(b.nombre, 'es'))
}

// ── Piezas ─────────────────────────────────────────────────────────────────

function Grupo({ titulo, children }: { titulo: string; children: ReactNode }) {
  return (
    <section className="lite-grupo flex flex-col">
      <h2 className="px-5 pt-4 text-[0.9rem] font-semibold text-on-surface">{titulo}</h2>
      <div className="flex flex-1 flex-col divide-y divide-[color:var(--lite-borde)]">{children}</div>
    </section>
  )
}

/** Lo que una cifra necesita saber de su lectura para decir que falló. */
type LecturaDeCifra = { isError: boolean; refetch: () => unknown }

function Cifra({
  rotulo,
  valor,
  pie,
  a,
  lectura,
}: {
  rotulo: string
  /** `undefined` mientras llega. */
  valor: string | undefined
  pie: string
  a: string
  lectura: LecturaDeCifra
}) {
  return (
    <div className="px-5 py-3.5">
      <Link to={a} className="group flex items-center gap-1 text-[0.78rem] text-panel-muted hover:text-on-surface">
        {rotulo}
        <ArrowRight size={12} aria-hidden className="opacity-0 transition-opacity group-hover:opacity-100" />
      </Link>
      {lectura.isError ? (
        <button
          type="button"
          onClick={() => void lectura.refetch()}
          className="my-2 inline-flex items-center gap-1.5 text-[0.82rem] text-panel-critico"
        >
          <RotateCw size={13} aria-hidden /> No se pudo leer · reintentar
        </button>
      ) : (
        <p className="lite-cifra my-1.5 text-[1.75rem] leading-tight font-semibold">
          {valor ?? <span className="inline-block h-7 w-20 animate-pulse rounded-md bg-panel-control align-middle" />}
        </p>
      )}
      <p className="text-[0.74rem] text-panel-muted">{pie}</p>
    </div>
  )
}

/** Las colas de Inicio que tienen trabajo, la más urgente arriba. */
function NecesitaAtencion() {
  const colas = ordenarColas(useColas())
  const conTrabajo = colas.filter((c) => tieneTrabajo(c.lectura))
  const fallidas = colas.filter((c) => c.lectura.estado === 'error')
  const cargando = colas.some((c) => c.lectura.estado === 'cargando')

  return (
    <section className="lite-grupo flex flex-col p-5">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-[0.95rem] font-semibold text-on-surface">Necesita atención</h2>
          <p className="text-[0.76rem] text-panel-muted">Las colas de trabajo de hoy</p>
        </div>
        {!cargando && (
          <span className="rounded-md bg-[#157EFD]/12 px-2 py-0.5 text-[0.72rem] font-semibold text-[#157EFD]">
            {conTrabajo.length === 0 ? 'Al día' : `${conTrabajo.length} pendientes`}
          </span>
        )}
      </div>

      <ul className="mt-3 flex flex-col">
        {conTrabajo.map((c) => (
          <FilaDeCola key={c.id} cola={c} />
        ))}
        {fallidas.map((c) => (
          <li key={c.id} className="flex items-center justify-between gap-2 border-t border-[color:var(--lite-borde)] py-3 text-[0.8rem]">
            <span className="text-panel-muted">{c.nombre}: no se pudo leer</span>
            {c.lectura.estado === 'error' && (
              <button type="button" onClick={c.lectura.reintentar} className="text-[#157EFD]">
                Reintentar
              </button>
            )}
          </li>
        ))}
        {cargando && conTrabajo.length === 0 && <li className="py-3 text-[0.8rem] text-panel-muted">Leyendo las colas…</li>}
        {!cargando && conTrabajo.length === 0 && fallidas.length === 0 && (
          <li className="py-3 text-[0.8rem] text-panel-muted">No hay nada esperando. Buen trabajo.</li>
        )}
      </ul>
    </section>
  )
}

function FilaDeCola({ cola }: { cola: ColaDeInicio }) {
  if (cola.lectura.estado !== 'listo') return null
  const { resumen } = cola.lectura
  const tarde = resumen.plazo === 'pasado'
  return (
    <li className="border-t border-[color:var(--lite-borde)] first:border-t-0">
      <Link {...cola.lista} className="group flex items-center gap-3 py-3">
        <span
          className={`flex size-8 shrink-0 items-center justify-center rounded-full text-[0.78rem] font-semibold tabular-nums ${
            tarde ? 'bg-error/15 text-panel-critico' : 'bg-[#157EFD]/12 text-[#157EFD]'
          }`}
        >
          {resumen.alTope ? `${resumen.cantidad}+` : resumen.cantidad}
        </span>
        <span className="min-w-0 flex-1">
          <strong className="block truncate text-[0.82rem] font-semibold text-on-surface">{cola.nombre}</strong>
          {resumen.detalle && <span className="block truncate text-[0.72rem] text-panel-muted">{resumen.detalle}</span>}
        </span>
        <ArrowRight size={15} aria-hidden className="shrink-0 text-panel-muted group-hover:text-[#157EFD]" />
      </Link>
    </li>
  )
}

/** Qué parte de los clics y de las consultas se lleva cada especialidad. */
function RepartoPorEspecialidad({ filas }: { filas: FilaDeActividad[] | null }) {
  const juegos: Array<{ titulo: string; valor: (f: FilaDeActividad) => number }> = [
    { titulo: 'Clics a WhatsApp', valor: (f) => f.clics },
    { titulo: 'Consultas', valor: (f) => f.ordenes },
  ]

  return (
    <section className="lite-reparto p-5">
      <h2 className="text-[0.95rem] font-semibold">Distribución por especialidad</h2>
      <p className="text-[0.76rem] text-white/80">Participación de cada especialidad en el periodo</p>
      {!filas ? (
        <p className="mt-4 text-[0.8rem] text-white/80">Leyendo…</p>
      ) : (
        <div className="mt-4 grid gap-6 md:grid-cols-2">
          {juegos.map((j) => (
            <Reparto key={j.titulo} titulo={j.titulo} partes={partesPorEspecialidad(filas, j.valor)} />
          ))}
        </div>
      )}
    </section>
  )
}

type Parte = { rotulo: string; n: number; pct: number }

/** Las cuatro especialidades con más y el resto junto, en porcentajes que suman 100. */
function partesPorEspecialidad(filas: FilaDeActividad[], valor: (f: FilaDeActividad) => number): Parte[] {
  const porClave = new Map<ClaveDeEspecialidad, number>()
  for (const f of filas) porClave.set(f.clave, (porClave.get(f.clave) ?? 0) + valor(f))
  const total = [...porClave.values()].reduce((s, n) => s + n, 0)
  if (total === 0) return []
  const orden = [...porClave.entries()].filter(([, n]) => n > 0).sort((a, b) => b[1] - a[1])
  const primeras = orden.slice(0, 4).map(([clave, n]) => ({ rotulo: nombreDeEspecialidad(clave), n }))
  const resto = orden.slice(4).reduce((s, [, n]) => s + n, 0)
  if (resto > 0) primeras.push({ rotulo: 'Otras', n: resto })
  return primeras.map((p) => ({ ...p, pct: (p.n / total) * 100 }))
}

function Reparto({ titulo, partes }: { titulo: string; partes: Parte[] }) {
  return (
    <div>
      <h3 className="mb-2 text-[0.8rem] font-semibold">{titulo}</h3>
      {partes.length === 0 ? (
        <p className="text-[0.78rem] text-white/80">Sin datos en el periodo.</p>
      ) : (
        <>
          <div aria-hidden className="mb-3 flex h-3.5 gap-0.5 overflow-hidden rounded-[4px] bg-white/30">
            {partes.map((p, i) => (
              <span key={p.rotulo} style={{ width: `${p.pct}%`, background: TONOS[i] }} />
            ))}
          </div>
          <ul className="flex flex-col">
            {partes.map((p, i) => (
              <li key={p.rotulo} className="flex items-center justify-between border-t border-white/20 py-1.5 text-[0.78rem] first:border-t-0">
                <span className="flex items-center gap-2">
                  <i aria-hidden className="size-2 rounded-full" style={{ background: TONOS[i] }} />
                  {p.rotulo}
                </span>
                <strong className="tabular-nums">
                  {ENTERO.format(p.n)} · {formatPct(p.pct, 0)}
                </strong>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  )
}

/** Los clics de cada día, con los navegadores distintos de ese día. */
function InteresEnElTiempo({ tablero, dias }: { tablero: TableroDelDirectorio | undefined; dias: number }) {
  const serie = tablero?.porDia.slice(-dias) ?? []
  const tope = Math.max(1, ...serie.map((d) => d.clics))
  const ancho = 600
  const alto = 170
  const x = (i: number) => (serie.length <= 1 ? ancho / 2 : (i / (serie.length - 1)) * ancho)
  const y = (n: number) => alto - 8 - (n / tope) * (alto - 24)
  const linea = serie.map((d, i) => `${i === 0 ? 'M' : 'L'}${x(i).toFixed(1)},${y(d.clics).toFixed(1)}`).join(' ')
  const area = serie.length ? `${linea} L${x(serie.length - 1)},${alto} L0,${alto} Z` : ''
  const total = serie.reduce((s, d) => s + d.clics, 0)

  return (
    <section className="lite-tarjeta p-5">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-[0.95rem] font-semibold text-on-surface">Interés por los médicos</h2>
          <p className="text-[0.76rem] text-panel-muted">Clics al WhatsApp desde el directorio, últimos {dias} días</p>
        </div>
        <Link to="/admin/directorio" className="shrink-0 text-[0.76rem] font-medium text-[#157EFD]">
          Ver detalle →
        </Link>
      </div>
      {!tablero ? (
        <div className="mt-4 h-40 animate-pulse rounded-xl bg-panel-control" />
      ) : (
        <>
          <svg
            viewBox={`0 0 ${ancho} ${alto}`}
            className="mt-4 h-40 w-full"
            preserveAspectRatio="none"
            role="img"
            aria-label={`${ENTERO.format(total)} clics en los últimos ${dias} días; el día con más tuvo ${ENTERO.format(tope)}`}
          >
            <defs>
              <linearGradient id="lite-relleno" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0" stopColor="#157EFD" stopOpacity="0.18" />
                <stop offset="1" stopColor="#157EFD" stopOpacity="0" />
              </linearGradient>
            </defs>
            <path d={area} fill="url(#lite-relleno)" />
            <path d={linea} fill="none" stroke="#157EFD" strokeWidth="2.5" vectorEffect="non-scaling-stroke" />
          </svg>
          <div className="mt-1 flex justify-between text-[0.7rem] text-panel-muted tabular-nums">
            <span>{fechaCorta(serie[0]?.dia)}</span>
            <span>Máximo diario: {ENTERO.format(tope)}</span>
            <span>{fechaCorta(serie.at(-1)?.dia)}</span>
          </div>
        </>
      )}
    </section>
  )
}

function fechaCorta(dia: string | undefined): string {
  if (!dia) return ''
  return new Date(`${dia}T12:00:00Z`).toLocaleDateString('es-VE', { day: 'numeric', month: 'short', timeZone: 'UTC' })
}

/** Los médicos con más interés del periodo: clics, consultas y la ficha a un clic. */
function ActividadPorMedico({ filas, cargando }: { filas: FilaDeActividad[] | null; cargando: boolean }) {
  const primeras = (filas ?? []).slice(0, 8)
  return (
    <section className="lite-tarjeta overflow-hidden">
      <div className="flex items-start justify-between gap-3 p-5 pb-3">
        <div>
          <h2 className="text-[0.95rem] font-semibold text-on-surface">Actividad por médico</h2>
          <p className="text-[0.76rem] text-panel-muted">Clics al WhatsApp y consultas confirmadas en el periodo</p>
        </div>
        <Link to="/admin/directorio" className="shrink-0 text-[0.76rem] font-medium text-[#157EFD]">
          Ver todos →
        </Link>
      </div>
      <div className="overflow-x-auto">
        <table className="lite-tabla w-full text-[0.8rem]">
          <thead>
            <tr className="text-left">
              <th className="px-5 py-2.5">Médico</th>
              <th className="px-3 py-2.5 text-right">Clics</th>
              <th className="px-3 py-2.5 text-right">Consultas</th>
              <th className="px-5 py-2.5">
                <span className="sr-only">Ficha</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {cargando && (
              <tr>
                <td colSpan={4} className="px-5 py-4 text-panel-muted">
                  Leyendo…
                </td>
              </tr>
            )}
            {!cargando && primeras.length === 0 && (
              <tr>
                <td colSpan={4} className="px-5 py-4 text-panel-muted">
                  No hay médicos en el directorio.
                </td>
              </tr>
            )}
            {primeras.map((f) => (
              <tr key={f.id} className="border-t border-[color:var(--lite-borde)]">
                <td className="px-5 py-2.5">
                  <strong className="block font-semibold text-on-surface">{f.nombre}</strong>
                  <span className="text-[0.72rem] text-panel-muted">{f.especialidad ?? nombreDeEspecialidad(f.clave)}</span>
                </td>
                <td className="px-3 py-2.5 text-right font-semibold tabular-nums">{ENTERO.format(f.clics)}</td>
                <td className="px-3 py-2.5 text-right tabular-nums">{ENTERO.format(f.ordenes)}</td>
                <td className="px-5 py-2.5 text-right">
                  <Link
                    to="/admin/clinicas/$id"
                    params={{ id: f.id }}
                    className="text-[0.76rem] font-medium whitespace-nowrap text-[#157EFD]"
                  >
                    Ver médico →
                  </Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
