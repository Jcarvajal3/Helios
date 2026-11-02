import { useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { queryOptions, useQuery } from '@tanstack/react-query'

import { ordenarColas, tieneTrabajo } from '@/components/admin/inicio/colas'
import { useColas } from '@/components/admin/inicio/useColas'
import type { ColaDeInicio } from '@/components/admin/inicio/useColas'
import { useImpagoPrimeraCuota } from '@/components/admin/inicio/useCifrasDeHoy'
import { useCuentaDelPanel } from '@/components/layouts/cuenta'
import { diaOperativo, formatPct, formatUsd } from '@/components/ui'
import { sumarDias } from '@/components/kit/rango'
import { fetchMerchants } from '@/features/admin/api'
import { consultaDirectorio } from '@/features/admin/directorioDeMedicos/api'
import type { TableroDelDirectorio } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import { consultaDeJuanPablo } from '@/features/admin/metricas/juan-pablo/api'
import type { JuanPablo } from '@/features/admin/metricas/juan-pablo/lectura'
import { nombreDeEspecialidad } from '@/features/directorio/especialidades'
import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'
import { comoFila, comoLista, numero } from '@/lib/json'
import { supabase } from '@/lib/supabase'
import { SelectorDePeriodo, cambio, diasDe, inicialesDeMedico, textoDeCambio } from './kit'
import type { Periodo } from './kit'

/**
 * El Resumen de Helios Lite, con la estructura de la maqueta: el saludo y el
 * periodo; tres grupos de cifras; a la derecha, en azul, el reparto por
 * especialidad; debajo, lo que necesita atención; y la actividad por médico.
 *
 * Con datos reales y sin lecturas propias: las mismas de Pro (Métricas › Juan
 * Pablo, el tablero del Directorio, las colas de Inicio y el impago de la
 * cuota 1), así que una cifra dice lo mismo en las dos versiones.
 *
 * El periodo es hoy, 7 o 30 días hasta hoy: los clics al WhatsApp solo se
 * guardan por día los últimos 30 (`admin_directorio`). Cada cifra se compara
 * con el periodo igual de antes, cuando la base lo tiene.
 */

const ENTERO = new Intl.NumberFormat('es-VE')

/** Los tonos de la barra apilada de la maqueta, del más fuerte al más claro. */
const TONOS = ['#1559df', '#5d83ce', '#87a6dc', '#bdcdeb', '#e3ebf8']

export function ResumenLite() {
  const [periodo, setPeriodo] = useState<Periodo>('7d')
  const dias = diasDe(periodo)
  const hoy = diaOperativo()
  const rango = { from: sumarDias(hoy, -(dias - 1)), to: hoy }
  const anterior = { from: sumarDias(hoy, -(2 * dias - 1)), to: sumarDias(hoy, -dias) }

  const cuenta = useCuentaDelPanel()
  const nombre = cuenta?.nombreDePila ?? null

  const metricas = useQuery(consultaDeJuanPablo(rango))
  const metricasAntes = useQuery(consultaDeJuanPablo(anterior))
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
  const medicosNuevos = altas.data?.filter((m) => !m.isTest && diaOperativo(new Date(m.createdAt)) >= rango.from).length
  const m = metricas.data
  const a = metricasAntes.data

  return (
    <>
      <section className="lt-escenario">
        <h1 className="lt-bienvenida">
          Bienvenido,<span>{nombre ?? 'equipo de Helios'}</span>
        </h1>
        <div className="lt-escenario-pie">
          <span className="lt-estado">Datos en vivo · día operativo {fechaLarga(hoy)}</span>
          <SelectorDePeriodo periodo={periodo} onCambio={setPeriodo} />
        </div>
      </section>

      <div className="lt-tablero">
        <div className="lt-tablero-cifras">
          <Grupo titulo="Pacientes y consultas">
            <Cifra
              rotulo="Clics a WhatsApp (Ads)"
              a="/admin/directorio"
              valor={clics && ENTERO.format(clics.clics)}
              cambio={clics?.cambio}
              pie={clics?.visitantes != null ? `${ENTERO.format(clics.visitantes)} navegadores distintos` : 'desde el directorio público'}
              fallo={directorio.isError}
              reintentar={() => void directorio.refetch()}
            />
            <Cifra
              rotulo="Consultas en Helios"
              a="/admin/financiamientos"
              valor={m && ENTERO.format(m.ordenes)}
              cambio={m && a ? cambio(m.ordenes, a.ordenes) : undefined}
              pie="consultas confirmadas"
              fallo={metricas.isError}
              reintentar={() => void metricas.refetch()}
            />
          </Grupo>

          <Grupo titulo="Volumen e ingresos">
            <Cifra
              rotulo="GTV · valor de consultas"
              a="/admin/metricas"
              valor={m && formatUsd(m.gtvUsd)}
              cambio={m && a ? cambio(m.gtvUsd, a.gtvUsd) : undefined}
              pie="volumen total de consultas"
              fallo={metricas.isError}
              reintentar={() => void metricas.refetch()}
            />
            <Cifra
              rotulo="Revenue · ingresos Helios"
              a="/admin/metricas"
              valor={m && formatUsd(m.revenueUsd)}
              etiqueta={m?.revenuePct != null ? formatPct(m.revenuePct, 0) : undefined}
              pie="Comisión Helios generada · sin IVA"
              fallo={metricas.isError}
              reintentar={() => void metricas.refetch()}
            />
            <Cifra
              rotulo="Impago de la 1.ª cuota"
              a="/admin/metricas"
              valor={
                impago.estado === 'listo'
                  ? impago.datos.pct === null
                    ? '—'
                    : formatPct(impago.datos.pct)
                  : undefined
              }
              pie={
                impago.estado === 'listo' && impago.datos.mes
                  ? `consumos de ${impago.datos.mes.rotulo} · último mes maduro`
                  : 'último mes maduro'
              }
              fallo={impago.estado === 'error'}
              reintentar={impago.estado === 'error' ? impago.reintentar : undefined}
            />
          </Grupo>

          <Grupo titulo="Red de médicos">
            <Cifra
              rotulo="Médicos live"
              a="/admin/directorio"
              valor={medicosLive === undefined ? undefined : ENTERO.format(medicosLive)}
              pie="perfiles publicados en el directorio"
              fallo={directorio.isError}
              reintentar={() => void directorio.refetch()}
            />
            <Cifra
              rotulo="Médicos sumados"
              a="/admin/clinicas"
              valor={medicosNuevos === undefined ? undefined : ENTERO.format(medicosNuevos)}
              etiqueta={medicosNuevos ? 'Nuevos' : undefined}
              pie="incorporados en el periodo"
              fallo={altas.isError}
              reintentar={() => void altas.refetch()}
            />
            <Cifra
              rotulo="Visitas agendadas"
              a="/admin/agenda"
              valor={citas.data === undefined ? undefined : ENTERO.format(citas.data)}
              pie="capacitaciones anotadas en la Agenda"
              fallo={citas.isError}
              reintentar={() => void citas.refetch()}
            />
          </Grupo>
        </div>

        <div className="lt-tablero-reparto">
          <RepartoPorEspecialidad filas={filas} />
        </div>

        <div className="lt-tablero-atencion">
          <NecesitaAtencion />
        </div>
      </div>

      <ActividadPorMedico filas={filas} cargando={directorio.isPending || metricas.isPending} />
    </>
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

function suma(serie: ReadonlyArray<number>): number {
  return serie.reduce((s, n) => s + n, 0)
}

/**
 * Los clics del periodo, su cambio y, cuando la base los cuenta exactos, los
 * navegadores distintos: hoy y los 30 días. Para 7 días no se pueden sumar los
 * de cada día (el mismo navegador contaría varias veces), así que no se dan.
 */
function clicsDelPeriodo(
  t: TableroDelDirectorio,
  dias: number,
): { clics: number; cambio: number | undefined; visitantes: number | null } {
  const serie = t.porDia.map((d) => d.clics)
  const clics = suma(serie.slice(-dias))
  const antes = dias === 30 ? t.totales.clics30dAnteriores : suma(serie.slice(-2 * dias, -dias))
  const visitantes = dias === 1 ? (t.porDia.at(-1)?.visitantes ?? 0) : dias === 30 ? t.totales.visitantes30d : null
  return { clics, cambio: cambio(clics, antes), visitantes }
}

type FilaDeActividad = {
  id: string
  nombre: string
  especialidad: string | null
  clave: ClaveDeEspecialidad
  clics: number
  ordenes: number
  /** Los clics de los últimos siete días, para las barritas. */
  semana: number[]
  /** Esta semana contra la anterior, en %. */
  tendencia: number | undefined
}

/** Cada médico real con sus clics y sus órdenes del periodo, el que más interés despertó primero. */
function actividadPorMedico(t: TableroDelDirectorio, m: JuanPablo, dias: number): FilaDeActividad[] {
  const ordenes = new Map(m.porMedico.map((p) => [p.merchantId, p.ordenes]))
  return t.medicos
    .filter((d) => !d.esPrueba && d.estado !== 'terminated')
    .map((d) => ({
      id: d.id,
      nombre: d.tarjeta.nombre || d.clinica,
      especialidad: d.tarjeta.especialidad,
      clave: d.tarjeta.clave,
      clics: suma(d.clics.porDia.slice(-dias)),
      ordenes: ordenes.get(d.id) ?? 0,
      semana: d.clics.porDia.slice(-7),
      tendencia: cambio(suma(d.clics.porDia.slice(-7)), suma(d.clics.porDia.slice(-14, -7))),
    }))
    .sort((x, y) => y.clics - x.clics || y.ordenes - x.ordenes || x.nombre.localeCompare(y.nombre, 'es'))
}

function fechaLarga(dia: string): string {
  return new Date(`${dia}T12:00:00Z`).toLocaleDateString('es-VE', { day: 'numeric', month: 'long', timeZone: 'UTC' })
}

// ── Piezas ─────────────────────────────────────────────────────────────────

function Grupo({ titulo, children }: { titulo: string; children: ReactNode }) {
  return (
    <section className="lt-grupo">
      <h2>{titulo}</h2>
      {children}
    </section>
  )
}

function Cifra({
  rotulo,
  valor,
  cambio: delta,
  etiqueta,
  pie,
  a,
  fallo,
  reintentar,
}: {
  rotulo: string
  /** `undefined` (o `null`) mientras llega. */
  valor: string | null | undefined
  cambio?: number
  /** Lo que va delante del pie, en el azul de la subida: «12 %», «Nuevos». */
  etiqueta?: string
  pie: string
  a: string
  fallo: boolean
  reintentar?: () => void
}) {
  return (
    <div className="lt-cifra">
      <Link to={a} className="lt-cifra-rotulo">
        {rotulo} <span aria-hidden>↗</span>
      </Link>
      {fallo ? (
        <button type="button" className="lt-reintentar" onClick={reintentar}>
          No se pudo leer · reintentar
        </button>
      ) : (
        <div className="lt-cifra-valor">{valor ?? <span className="lt-cargando" />}</div>
      )}
      <div className="lt-cifra-pie">
        {delta !== undefined && <b data-baja={delta < 0 || undefined}>{textoDeCambio(delta)}</b>}
        {delta === undefined && etiqueta && <b>{etiqueta}</b>}
        {pie}
      </div>
    </div>
  )
}

/** Las colas de Inicio que tienen trabajo, la más urgente primero, en tres columnas. */
function NecesitaAtencion() {
  const colas = ordenarColas(useColas())
  const conTrabajo = colas.filter((c) => tieneTrabajo(c.lectura))
  const fallidas = colas.filter((c) => c.lectura.estado === 'error')
  const cargando = colas.some((c) => c.lectura.estado === 'cargando')

  return (
    <section className="lt-atencion">
      <div className="lt-panel-cabeza">
        <div>
          <h2>Necesita atención</h2>
          <p>Pendientes de seguimiento</p>
        </div>
        {!cargando && (
          <span className="lt-etiqueta" data-tono={conTrabajo.length ? 'ambar' : 'verde'}>
            {conTrabajo.length ? `${conTrabajo.length} pendientes` : 'Al día'}
          </span>
        )}
      </div>

      <ul className="lt-pendientes">
        {conTrabajo.map((c) => (
          <Pendiente key={c.id} cola={c} />
        ))}
        {cargando && conTrabajo.length === 0 && (
          <li className="lt-pendiente">
            <div>
              <p>Leyendo las colas…</p>
            </div>
          </li>
        )}
        {!cargando && conTrabajo.length === 0 && fallidas.length === 0 && (
          <li className="lt-pendiente">
            <div>
              <p>No hay nada esperando.</p>
            </div>
          </li>
        )}
      </ul>

      {fallidas.length > 0 && (
        <div className="lt-nota">
          No se pudo leer: {fallidas.map((c) => c.nombre).join(', ')}.{' '}
          <button
            type="button"
            className="lt-boton-texto"
            onClick={() => fallidas.forEach((c) => c.lectura.estado === 'error' && c.lectura.reintentar())}
          >
            Reintentar
          </button>
        </div>
      )}
    </section>
  )
}

function Pendiente({ cola }: { cola: ColaDeInicio }) {
  if (cola.lectura.estado !== 'listo') return null
  const { resumen } = cola.lectura
  return (
    <li className="lt-pendiente">
      <Link {...cola.lista}>
        <span className="lt-icono-estado" data-tarde={resumen.plazo === 'pasado' || undefined}>
          {resumen.alTope ? `${resumen.cantidad}+` : resumen.cantidad}
        </span>
        <span>
          <strong>{cola.nombre}</strong>
          {resumen.detalle && <p>{resumen.detalle}</p>}
        </span>
      </Link>
    </li>
  )
}

/** El panel azul de la maqueta: qué parte de los clics y de las consultas se lleva cada especialidad. */
function RepartoPorEspecialidad({ filas }: { filas: FilaDeActividad[] | null }) {
  const juegos: Array<{ titulo: string; valor: (f: FilaDeActividad) => number }> = [
    { titulo: 'Clics a WhatsApp', valor: (f) => f.clics },
    { titulo: 'Consultas', valor: (f) => f.ordenes },
  ]

  return (
    <section className="lt-reparto">
      <h2>Distribución por especialidad</h2>
      <p>Participación de cada especialidad en el periodo</p>
      {!filas ? (
        <div className="lt-reparto-mitad">
          <h3>Leyendo…</h3>
        </div>
      ) : (
        juegos.map((j) => <Reparto key={j.titulo} titulo={j.titulo} partes={partesPorEspecialidad(filas, j.valor)} />)
      )}
    </section>
  )
}

type Parte = { rotulo: string; n: number; pct: number }

/** Las cuatro especialidades con más y el resto junto. */
function partesPorEspecialidad(filas: FilaDeActividad[], valor: (f: FilaDeActividad) => number): Parte[] {
  const porClave = new Map<ClaveDeEspecialidad, number>()
  for (const f of filas) porClave.set(f.clave, (porClave.get(f.clave) ?? 0) + valor(f))
  const total = suma([...porClave.values()])
  if (total === 0) return []
  const orden = [...porClave.entries()].filter(([, n]) => n > 0).sort((x, y) => y[1] - x[1])
  const partes = orden.slice(0, 4).map(([clave, n]) => ({ rotulo: nombreDeEspecialidad(clave), n }))
  const resto = suma(orden.slice(4).map(([, n]) => n))
  if (resto > 0) partes.push({ rotulo: 'Otras', n: resto })
  return partes.map((p) => ({ ...p, pct: (p.n / total) * 100 }))
}

function Reparto({ titulo, partes }: { titulo: string; partes: Parte[] }) {
  return (
    <div className="lt-reparto-mitad">
      <h3>{titulo}</h3>
      {partes.length === 0 ? (
        <p className="lt-cifra-pie" style={{ color: '#edf5ff' }}>
          Sin datos en el periodo.
        </p>
      ) : (
        <>
          <div className="lt-barra-apilada" aria-hidden>
            {partes.map((p, i) => (
              <span key={p.rotulo} style={{ width: `${p.pct}%`, background: TONOS[i] }} />
            ))}
          </div>
          {partes.map((p, i) => (
            <div key={p.rotulo} className="lt-reparto-fila">
              <span>
                <i aria-hidden style={{ background: TONOS[i] }} />
                {p.rotulo}
              </span>
              <strong>{formatPct(p.pct, 0)}</strong>
            </div>
          ))}
        </>
      )}
    </div>
  )
}

/** Las barritas de la maqueta: los clics de cada uno de los últimos siete días. */
function Barritas({ serie }: { serie: number[] }) {
  const tope = Math.max(1, ...serie)
  return (
    <span className="lt-barritas" aria-hidden>
      {serie.map((n, i) => (
        <i key={i} style={{ height: `${Math.max(3, (n / tope) * 22)}px` }} />
      ))}
    </span>
  )
}

/** La tabla de la maqueta: cada médico con sus clics, sus consultas y su tendencia. */
function ActividadPorMedico({ filas, cargando }: { filas: FilaDeActividad[] | null; cargando: boolean }) {
  const primeras = (filas ?? []).slice(0, 8)
  return (
    <section className="lt-panel lt-actividad">
      <div className="lt-panel-cabeza">
        <div>
          <h2>Actividad por médico</h2>
          <p>Clics a WhatsApp y consultas registradas en el periodo</p>
        </div>
        <Link to="/admin/directorio" className="lt-boton-texto">
          Ver todos →
        </Link>
      </div>
      <div className="lt-desliza">
        <table className="lt-tabla">
          <thead>
            <tr>
              <th>Médico</th>
              <th className="lt-num">Clics a WhatsApp (Ads)</th>
              <th className="lt-num">Consultas en Helios</th>
              <th>Tendencia de clics</th>
              <th>
                <span className="sr-only">Ficha</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {cargando && (
              <tr>
                <td colSpan={5} className="lt-vacio">
                  Leyendo…
                </td>
              </tr>
            )}
            {!cargando && primeras.length === 0 && (
              <tr>
                <td colSpan={5} className="lt-vacio">
                  No hay médicos en el directorio.
                </td>
              </tr>
            )}
            {primeras.map((f) => (
              <tr key={f.id}>
                <td>
                  <div className="lt-medico">
                    <span className="lt-medico-avatar" aria-hidden>
                      {inicialesDeMedico(f.nombre)}
                    </span>
                    <div>
                      <strong>{f.nombre}</strong>
                      <small>{f.especialidad ?? nombreDeEspecialidad(f.clave)}</small>
                    </div>
                  </div>
                </td>
                <td className="lt-num">
                  <strong>{ENTERO.format(f.clics)}</strong>
                </td>
                <td className="lt-num">{ENTERO.format(f.ordenes)}</td>
                <td>
                  <Barritas serie={f.semana} />
                  {f.tendencia !== undefined && (
                    <span className="lt-tendencia">
                      {f.tendencia >= 0 ? '+' : '−'}
                      {formatPct(Math.abs(f.tendencia), 0)}
                    </span>
                  )}
                </td>
                <td style={{ textAlign: 'right' }}>
                  <Link to="/admin/clinicas/$id" params={{ id: f.id }} className="lt-boton-texto">
                    Ver médico →
                  </Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="lt-nota">
        Fuente: el botón de WhatsApp de conhelios.com/directorio. Un clic indica intención de contacto; no confirma una
        conversación ni una consulta.
      </div>
    </section>
  )
}
