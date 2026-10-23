import { useMemo, useState } from 'react'
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { CalendarDays, Plus, UserPlus } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import { BuscadorEnUrl } from '@/components/FiltrosDeLista'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { CalendarioDeReuniones } from '@/components/admin/agenda/CalendarioDeReuniones'
import { FichaDelLead } from '@/components/admin/agenda/FichaDelLead'
import { FormularioDeLead } from '@/components/admin/agenda/FormularioDeLead'
import { columnasDeLaAgenda } from '@/components/admin/agenda/columnas'
import {
  Button,
  EmptyState,
  FilterBar,
  Filtro,
  Segmented,
  Select,
  SkeletonTable,
  Stat,
  StatGrid,
  estadoDeConsulta,
  formatPorcentaje,
  hoyCaracas,
} from '@/components/ui'
import { consultaAgenda } from '@/features/admin/agenda/api'
import { useSoloAgenda } from '@/features/admin/role'
import {
  ESTADOS_DEL_LEAD,
  ESTADO_DEL_LEAD,
  VALORES_QUE_SE_VE,
  cifrasDeLaAgenda,
  cuentaPorEstado,
  filtrarAgenda,
  ordenarAgenda,
  pendienteDe,
  tieneVisita,
} from '@/features/admin/agenda/agenda'
import type { EstadoDelLead, Lead, QueSeVe } from '@/features/admin/agenda/agenda'
import { comoBooleano, comoDia, comoId, comoTexto, unoDe } from '@/lib/busqueda'

type Vista = 'lista' | 'calendario'

/** La vista, los filtros, el mes y la ficha abierta: todo en la URL. */
type AgendaSearch = {
  vista?: Vista
  ver?: QueSeVe
  estado?: EstadoDelLead
  q?: string
  /** El médico cuya ficha está abierta. */
  lead?: string
  /** El día 1 del mes del calendario. */
  mes?: string
  /** En el calendario, solo las visitas (sin los días de volver a llamar). */
  soloVisitas?: true
}

export const Route = createFileRoute('/admin/agenda')({
  staticData: { title: 'Agenda', width: 'wide' },
  component: AgendaPage,
  validateSearch: (search: Record<string, unknown>): AgendaSearch => {
    const mes = comoDia(search.mes)
    return {
      vista: unoDe(['lista', 'calendario'] as const, search.vista),
      ver: unoDe(VALORES_QUE_SE_VE, search.ver),
      estado: unoDe(ESTADOS_DEL_LEAD, search.estado),
      q: comoTexto(search.q),
      lead: comoId(search.lead),
      mes: mes ? `${mes.slice(0, 7)}-01` : undefined,
      soloVisitas: comoBooleano(search.soloVisitas),
    }
  },
})

const OPCIONES_VISTA: Array<{ value: Vista; label: string }> = [
  { value: 'lista', label: 'Listado' },
  { value: 'calendario', label: 'Calendario' },
]

const OPCIONES_ESTADO: Array<{ value: EstadoDelLead | 'todos'; label: string }> = [
  { value: 'todos', label: 'Todos los estados' },
  ...ESTADOS_DEL_LEAD.map((value) => ({ value, label: ESTADO_DEL_LEAD[value].label })),
]

const OPCIONES_CALENDARIO: Array<{ value: 'todo' | 'visitas'; label: string }> = [
  { value: 'todo', label: 'Visitas y llamadas' },
  { value: 'visitas', label: 'Solo visitas' },
]

function opcionesVer(leads: ReadonlyArray<Lead>, hoy: string, ahora: Date): Array<{ value: QueSeVe; label: string }> {
  const paraHoy = leads.filter((l) => pendienteDe(l, hoy, ahora) !== null).length
  return [
    { value: 'para_hoy', label: paraHoy > 0 ? `Para hoy (${paraHoy})` : 'Para hoy' },
    { value: 'abiertos', label: 'Abiertos' },
    { value: 'afiliados', label: 'Afiliados' },
    { value: 'descartados', label: 'Descartados' },
    { value: 'todos', label: 'Todos' },
  ]
}

/**
 * Agenda: los médicos que el equipo quiere afiliar.
 *
 * «Listado» es la lista de trabajo: cada médico con su teléfono, su
 * dirección, en qué quedó y su próxima cita, en el orden en que hay que
 * atenderlos (lo atrasado, lo de hoy y los que nadie ha llamado, arriba).
 * «Calendario» es el mes con las visitas y los días de volver a llamar.
 * Las dos abren la misma ficha, donde se anota cada gestión. Cuando un médico
 * llena el formulario de afiliación de la portada, su lead pasa solo a
 * «Afiliado» (migración 20261022200000).
 */
function AgendaPage() {
  const navigate = useNavigate({ from: '/admin/agenda' })
  const search = Route.useSearch()
  const vista = search.vista ?? 'lista'
  const ver = search.ver ?? 'abiertos'
  const [hoy] = useState(() => hoyCaracas())
  const [ahora] = useState(() => new Date())
  const mes = search.mes ?? `${hoy.slice(0, 7)}-01`

  const [apuntando, setApuntando] = useState(false)
  const [editando, setEditando] = useState<Lead | null>(null)

  const agenda = useQuery(consultaAgenda())
  const todos = agenda.data ?? []

  const filas = useMemo(
    () => ordenarAgenda(filtrarAgenda(todos, { texto: search.q, ver, estado: search.estado }, hoy, ahora), hoy, ahora),
    [todos, search.q, ver, search.estado, hoy, ahora],
  )
  // El calendario no filtra por estado: una visita es una visita. Sí por la búsqueda.
  const delCalendario = useMemo(
    () => filtrarAgenda(todos, { texto: search.q, ver: 'todos' }, hoy, ahora),
    [todos, search.q, hoy, ahora],
  )
  const soloAgenda = useSoloAgenda()
  const columnas = useMemo(() => columnasDeLaAgenda(hoy, ahora, soloAgenda), [hoy, ahora, soloAgenda])

  const abierto = search.lead ? todos.find((l) => l.id === search.lead) : undefined

  /** Un filtro es un paso del historial; una búsqueda que se teclea, no. */
  function cambiar(patch: Partial<AgendaSearch>, replace = false) {
    void navigate({ search: (prev) => ({ ...prev, ...patch }), replace })
  }

  function abrir(l: Lead) {
    cambiar({ lead: l.id })
  }

  return (
    <>
      <CifrasDeArriba
        leads={todos}
        ahora={ahora}
        estado={estadoDeConsulta(agenda)}
        onReintentar={() => void agenda.refetch()}
      />

      <FilterBar>
        <BuscadorEnUrl
          id="buscar-agenda"
          valor={search.q}
          placeholder="Médico, consultorio, ciudad o teléfono"
          onBuscar={(q) => cambiar({ q }, true)}
        />
        <Filtro label="Vista">
          <Segmented
            options={OPCIONES_VISTA}
            value={vista}
            onChange={(v) => cambiar({ vista: v === 'lista' ? undefined : v })}
          />
        </Filtro>
        {vista === 'lista' ? (
          <>
            <Filtro label="Médicos">
              <Segmented
                options={opcionesVer(todos, hoy, ahora)}
                value={ver}
                onChange={(v) => cambiar({ ver: v === 'abiertos' ? undefined : v })}
              />
            </Filtro>
            <Select
              id="agenda-filtro-estado"
              label="Estado"
              value={search.estado ?? 'todos'}
              options={OPCIONES_ESTADO}
              onChange={(v) => cambiar({ estado: v === 'todos' ? undefined : v })}
            />
          </>
        ) : (
          <Filtro label="En el calendario">
            <Segmented
              options={OPCIONES_CALENDARIO}
              value={search.soloVisitas ? 'visitas' : 'todo'}
              onChange={(v) => cambiar({ soloVisitas: v === 'visitas' ? true : undefined })}
            />
          </Filtro>
        )}
        <div className="ml-auto">
          <Button size="sm" onClick={() => setApuntando(true)}>
            <Plus size={14} aria-hidden /> Apuntar un médico
          </Button>
        </div>
      </FilterBar>

      {agenda.isPending && <SkeletonTable rows={6} columns={6} />}

      {agenda.isError && (
        <SeccionSinLeer
          titulo="No se pudo leer la agenda"
          error={agenda.error}
          onReintentar={() => void agenda.refetch()}
        />
      )}

      {agenda.isSuccess && todos.length === 0 && (
        <EmptyState
          icon={<UserPlus size={40} />}
          title="La agenda está vacía"
          description="Apunta a los médicos que quieres afiliar con su teléfono y su dirección, y lleva aquí cada mensaje, cada llamada y cada visita. Cuando uno llene el formulario de afiliación, pasará solo a «Afiliado»."
          action={
            <Button size="sm" onClick={() => setApuntando(true)}>
              <Plus size={14} aria-hidden /> Apuntar el primero
            </Button>
          }
        />
      )}

      {agenda.isSuccess && todos.length > 0 && vista === 'lista' && filas.length === 0 && (
        <EmptyState
          icon={<CalendarDays size={40} />}
          title={ver === 'para_hoy' && !search.q && !search.estado ? 'Nada pendiente para hoy' : 'Nada coincide'}
          description={
            ver === 'para_hoy' && !search.q && !search.estado
              ? 'Ninguna llamada ni visita vence hoy, y todos los médicos de la agenda ya tienen un primer contacto.'
              : 'Prueba con otra parte del nombre o del teléfono, u otro filtro.'
          }
        />
      )}

      {agenda.isSuccess && vista === 'lista' && filas.length > 0 && (
        <DataTable
          rows={filas}
          rowKey={(l) => l.id}
          columns={columnas}
          noun={['médico', 'médicos']}
          summary={<Resumen leads={todos} hoy={hoy} ahora={ahora} />}
          rowTone={(l) => {
            const p = pendienteDe(l, hoy, ahora)
            if (p === 'visita_pasada' || p === 'llamar_atrasado') return 'error'
            if (p === 'visita_hoy' || p === 'llamar_hoy') return 'warning'
            return undefined
          }}
          exportar={{ archivo: 'agenda-medicos' }}
          onRowClick={abrir}
        />
      )}

      {agenda.isSuccess && todos.length > 0 && vista === 'calendario' && (
        <CalendarioDeReuniones
          leads={delCalendario}
          mes={mes}
          hoy={hoy}
          conLlamadas={!search.soloVisitas}
          onMes={(m) => cambiar({ mes: m === `${hoy.slice(0, 7)}-01` ? undefined : m })}
          onAbrir={abrir}
        />
      )}

      {abierto && !editando && (
        <FichaDelLead
          // Otro médico es otra ficha: el borrador no pasa de uno a otro.
          key={abierto.id}
          lead={abierto}
          hoy={hoy}
          ahora={ahora}
          soloAgenda={soloAgenda}
          onEditar={() => setEditando(abierto)}
          onClose={() => cambiar({ lead: undefined })}
        />
      )}

      {(apuntando || editando) && (
        <FormularioDeLead
          lead={editando ?? undefined}
          onGuardado={(g) => {
            setApuntando(false)
            setEditando(null)
            cambiar({ lead: g.id })
          }}
          onClose={() => {
            setApuntando(false)
            setEditando(null)
          }}
        />
      )}
    </>
  )
}

/** «12 % de los contactados», o nada si no hay de dónde sacarlo. */
function porcentaje(parte: number, total: number, de = ''): string | null {
  return total > 0 ? `${formatPorcentaje((parte / total) * 100)}${de}` : null
}

/** Las partes de un pie, separadas por « · ». */
function pie(...partes: Array<string | null>): string {
  return partes.filter(Boolean).join(' · ')
}

/**
 * Las tres cifras del embudo, arriba del todo y sobre toda la agenda (no
 * sobre lo filtrado): médicos contactados, citas agendadas y médicos
 * activados. Cada pie dice de cuántos sale.
 */
function CifrasDeArriba({
  leads,
  ahora,
  estado,
  onReintentar,
}: {
  leads: ReadonlyArray<Lead>
  ahora: Date
  estado: ReturnType<typeof estadoDeConsulta>
  onReintentar: () => void
}) {
  const c = useMemo(() => cifrasDeLaAgenda(leads, ahora), [leads, ahora])
  return (
    <StatGrid cols={3} className="mb-6">
      <Stat
        label="Médicos contactados"
        value={String(c.contactados)}
        hint={pie(`de ${c.apuntados} en la agenda`, porcentaje(c.contactados, c.apuntados))}
        info="Los médicos de la agenda que ya no están «Sin contactar»: se les escribió, se les llamó o se les visitó, contestaran o no."
        estado={estado}
        onReintentar={onReintentar}
      />
      <Stat
        label="Citas agendadas"
        value={String(c.citas)}
        hint={pie(`${c.citasPorVenir} por venir`, porcentaje(c.citas, c.contactados, ' de los contactados'))}
        info="Los médicos con una visita agendada o ya realizada. Una visita cancelada deja de contar."
        estado={estado}
        onReintentar={onReintentar}
      />
      <Stat
        label="Médicos activados"
        value={String(c.activados)}
        hint={pie(`${c.conClinica} con su clínica dada de alta`, porcentaje(c.activados, c.contactados, ' de los contactados'))}
        info="Los médicos de la agenda que se afiliaron: llenaron el formulario de afiliación, se dio de alta su clínica o se marcaron a mano como afiliados."
        estado={estado}
        onReintentar={onReintentar}
      />
    </StatGrid>
  )
}

/** Lo que hay que hacer hoy, lo agendado y cuántos se afiliaron. */
function Resumen({ leads, hoy, ahora }: { leads: ReadonlyArray<Lead>; hoy: string; ahora: Date }) {
  const paraHoy = leads.filter((l) => pendienteDe(l, hoy, ahora) !== null).length
  const proximas = leads.filter((l) => tieneVisita(l) && l.reunion !== null && new Date(l.reunion) >= ahora).length
  const cuenta = cuentaPorEstado(leads)
  const trabajados = leads.length - cuenta.nuevo
  return (
    <>
      {paraHoy} para hoy · {proximas} {proximas === 1 ? 'visita agendada' : 'visitas agendadas'} ·{' '}
      {cuenta.convertido} {cuenta.convertido === 1 ? 'afiliado' : 'afiliados'} de {leads.length}
      {trabajados > 0 && ` (${Math.round((cuenta.convertido / leads.length) * 100)} %)`}
    </>
  )
}
