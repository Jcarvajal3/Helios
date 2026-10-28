import { useMemo, useState } from 'react'
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { LucideIcon } from 'lucide-react'
import { BadgeCheck, CalendarDays, MessageCircle, Phone, Plus, UserPlus, Users } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { DataTable } from '@/components/DataTable'
import { BuscadorEnUrl } from '@/components/FiltrosDeLista'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { CalendarioDeReuniones } from '@/components/admin/agenda/CalendarioDeReuniones'
import { FichaDelLead } from '@/components/admin/agenda/FichaDelLead'
import { FormularioDeLead } from '@/components/admin/agenda/FormularioDeLead'
import { columnasDeLaAgenda } from '@/components/admin/agenda/columnas'
import {
  Button,
  Chip,
  EmptyState,
  ErrorBox,
  FilterBar,
  Filtro,
  Segmented,
  SkeletonTable,
  Stat,
  StatGrid,
  Table,
  Td,
  Tr,
  estadoDeConsulta,
  formatPorcentaje,
  hoyCaracas,
} from '@/components/ui'
import { asignarmeMedicos, consultaAgenda, refrescarAgenda } from '@/features/admin/agenda/api'
import { useSoloAgenda } from '@/features/admin/role'
import { useSession } from '@/features/auth/session'
import {
  ALCANCES,
  ESTADOS_DEL_LEAD,
  ESTADOS_DE_LA_FASE,
  ESTADO_DEL_LEAD,
  FASES,
  ROTULO_ALCANCE,
  ROTULO_FASE,
  cifrasDeLaAgenda,
  cifrasPorPersona,
  cuentaPorFase,
  delAlcance,
  filtrarAgenda,
  ordenarAgenda,
  pendienteDe,
} from '@/features/admin/agenda/agenda'
import type { Alcance, EstadoDelLead, Fase, Lead } from '@/features/admin/agenda/agenda'
import { describeError } from '@/lib/supabase'
import { comoDia, comoId, comoTexto, unoDe } from '@/lib/busqueda'

/** En Visita: el calendario de las agendadas, o la lista de los afiliados. */
type VerVisitas = 'agendadas' | 'afiliados'

/** La fase, el estado, de quién, la búsqueda, el mes y la ficha abierta: todo en la URL. */
type AgendaSearch = {
  fase?: Fase
  estado?: EstadoDelLead
  de?: Alcance
  q?: string
  /** El médico cuya ficha está abierta. */
  lead?: string
  /** El día 1 del mes del calendario. */
  mes?: string
  visitas?: VerVisitas
}

export const Route = createFileRoute('/admin/agenda')({
  staticData: { title: 'Agenda', width: 'wide' },
  component: AgendaPage,
  validateSearch: (search: Record<string, unknown>): AgendaSearch => {
    const mes = comoDia(search.mes)
    return {
      fase: unoDe(FASES, search.fase),
      estado: unoDe(ESTADOS_DEL_LEAD, search.estado),
      de: unoDe(ALCANCES, search.de),
      q: comoTexto(search.q),
      lead: comoId(search.lead),
      mes: mes ? `${mes.slice(0, 7)}-01` : undefined,
      visitas: unoDe(['agendadas', 'afiliados'] as const, search.visitas),
    }
  },
})

/** Cuántos médicos se toman de una vez con «Asignarme». */
const POR_TANDA = 20

const ICONO_FASE: Record<Fase, LucideIcon> = {
  mensaje: MessageCircle,
  llamada: Phone,
  visita: CalendarDays,
}

/**
 * Agenda: los médicos que el equipo quiere afiliar, en tres fases.
 *
 * Mensaje (escribirle y saber si le interesa) › Llamada (llamar al
 * interesado y agendar la visita) › Visita (visitarlo, capacitarlo y
 * afiliarlo). Las tres pestañas son la navegación; dentro de cada una, los
 * estados de esa fase. Cada persona ve al entrar los médicos que tiene
 * asignados, y con «Asignarme 20 médicos» toma más de los que no tienen a
 * nadie; «Sin asignar» y «Todos» dejan ver el resto. La fase la pone la base
 * a partir del estado (20261028150000).
 */
function AgendaPage() {
  const navigate = useNavigate({ from: '/admin/agenda' })
  const search = Route.useSearch()
  const fase = search.fase ?? 'mensaje'
  const alcance = search.de ?? 'mios'
  const verVisitas = search.visitas ?? 'agendadas'
  const [hoy] = useState(() => hoyCaracas())
  const [ahora] = useState(() => new Date())
  const mes = search.mes ?? `${hoy.slice(0, 7)}-01`
  const yo = useSession()?.user.id ?? null
  const soloAgenda = useSoloAgenda()
  const client = useQueryClient()
  const avisar = useToast()

  const [apuntando, setApuntando] = useState(false)
  const [editando, setEditando] = useState<Lead | null>(null)

  const agenda = useQuery(consultaAgenda())
  const todos = useMemo(() => agenda.data ?? [], [agenda.data])

  /** Un filtro es un paso del historial; una búsqueda que se teclea, no. */
  function cambiar(patch: Partial<AgendaSearch>, replace = false) {
    void navigate({ search: (prev) => ({ ...prev, ...patch }), replace })
  }

  const asignar = useMutation({
    mutationFn: () => asignarmeMedicos(POR_TANDA),
    onSuccess: (n) => {
      refrescarAgenda(client)
      avisar(
        n === 0
          ? 'No quedan médicos sin asignar.'
          : `Te ${n === 1 ? 'tocó 1 médico' : `tocaron ${n} médicos`}: están en Mensaje.`,
      )
      if (n > 0) cambiar({ fase: undefined, estado: undefined, de: undefined })
    },
  })

  // Lo de quién, con la búsqueda: de aquí salen las cifras de las pestañas.
  const delQueMira = useMemo(() => delAlcance(todos, alcance, yo), [todos, alcance, yo])
  const buscados = useMemo(() => filtrarAgenda(delQueMira, { texto: search.q }), [delQueMira, search.q])
  const porFase = useMemo(() => cuentaPorFase(buscados), [buscados])

  const filas = useMemo(
    () => ordenarAgenda(filtrarAgenda(buscados, { fase, estado: search.estado }), hoy, ahora),
    [buscados, fase, search.estado, hoy, ahora],
  )
  const columnas = useMemo(() => columnasDeLaAgenda(hoy, ahora, soloAgenda), [hoy, ahora, soloAgenda])
  const sinAsignar = useMemo(
    () => todos.filter((l) => l.responsableId === null && l.estado !== 'convertido' && l.estado !== 'descartado').length,
    [todos],
  )

  const abierto = search.lead ? todos.find((l) => l.id === search.lead) : undefined

  function abrir(l: Lead) {
    cambiar({ lead: l.id })
  }

  const botonAsignar = (
    <Button
      size="sm"
      variant="tonal"
      disabled={asignar.isPending || sinAsignar === 0}
      title={sinAsignar === 0 ? 'No quedan médicos sin asignar.' : undefined}
      onClick={() => asignar.mutate()}
    >
      <UserPlus size={14} aria-hidden /> {asignar.isPending ? 'Asignando…' : `Asignarme ${POR_TANDA} médicos`}
    </Button>
  )

  return (
    <>
      <CifrasDeArriba
        leads={delQueMira}
        todos={todos}
        alcance={alcance}
        ahora={ahora}
        estado={estadoDeConsulta(agenda)}
        onReintentar={() => void agenda.refetch()}
      />

      <PestanasDeFase
        fase={fase}
        cuentas={porFase}
        onFase={(f) => cambiar({ fase: f === 'mensaje' ? undefined : f, estado: undefined })}
      />

      <FilterBar>
        <BuscadorEnUrl
          id="buscar-agenda"
          valor={search.q}
          placeholder="Médico, consultorio, dirección o teléfono"
          onBuscar={(q) => cambiar({ q }, true)}
        />
        <Filtro label="De quién">
          <Segmented
            options={ALCANCES.map((value) => ({
              value,
              label: value === 'sin_asignar' && sinAsignar > 0 ? `Sin asignar (${sinAsignar})` : ROTULO_ALCANCE[value],
            }))}
            value={alcance}
            onChange={(v) => cambiar({ de: v === 'mios' ? undefined : v })}
          />
        </Filtro>
        <div className="ml-auto flex flex-wrap gap-2">
          {botonAsignar}
          <Button size="sm" onClick={() => setApuntando(true)}>
            <Plus size={14} aria-hidden /> Apuntar un médico
          </Button>
        </div>
      </FilterBar>

      {asignar.isError && <ErrorBox title="No se pudieron asignar" detail={describeError(asignar.error)} />}

      {/* Los estados de la fase, con cuántos hay de cada uno. En Visita, el
          calendario de las agendadas o la lista de los afiliados. */}
      {fase === 'visita' ? (
        <div className="mb-4">
          <Segmented
            etiqueta="Qué visitas"
            options={[
              { value: 'agendadas', label: `Agendadas (${porFase.visita.porEstado.reunion ?? 0})` },
              { value: 'afiliados', label: `Afiliados (${porFase.visita.porEstado.convertido ?? 0})` },
            ]}
            value={verVisitas}
            onChange={(v) => cambiar({ visitas: v === 'agendadas' ? undefined : v })}
          />
        </div>
      ) : (
        <div className="mb-4 flex flex-wrap gap-1.5" role="group" aria-label="Estado">
          <Chip selected={!search.estado} onClick={() => cambiar({ estado: undefined })}>
            Todos ({porFase[fase].total})
          </Chip>
          {ESTADOS_DE_LA_FASE[fase].map((e) => (
            <Chip key={e} selected={search.estado === e} onClick={() => cambiar({ estado: search.estado === e ? undefined : e })}>
              {ESTADO_DEL_LEAD[e].label} ({porFase[fase].porEstado[e] ?? 0})
            </Chip>
          ))}
        </div>
      )}

      {agenda.isPending && <SkeletonTable rows={6} columns={6} />}

      {agenda.isError && (
        <SeccionSinLeer
          titulo="No se pudo leer la agenda"
          error={agenda.error}
          onReintentar={() => void agenda.refetch()}
        />
      )}

      {agenda.isSuccess && alcance === 'mios' && delQueMira.length === 0 && (
        <EmptyState
          icon={<UserPlus size={40} />}
          title="Todavía no tienes médicos asignados"
          description={
            sinAsignar > 0
              ? `Hay ${sinAsignar} sin nadie que los gestione. Toma ${POR_TANDA} y empieza por escribirles.`
              : 'No quedan médicos sin asignar. Apunta uno nuevo o mira los de todo el equipo.'
          }
          action={
            <div className="flex flex-wrap justify-center gap-2">
              {botonAsignar}
              <Button size="sm" variant="text" onClick={() => cambiar({ de: 'todos' })}>
                Ver todos
              </Button>
            </div>
          }
        />
      )}

      {agenda.isSuccess && delQueMira.length > 0 && fase !== 'visita' && filas.length === 0 && (
        <EmptyState
          icon={fase === 'mensaje' ? <MessageCircle size={40} /> : <Phone size={40} />}
          title={search.q || search.estado ? 'Nada coincide' : `Nada en ${ROTULO_FASE[fase].label}`}
          description={
            search.q || search.estado
              ? 'Prueba con otra parte del nombre o del teléfono, u otro estado.'
              : fase === 'mensaje'
                ? 'Todos tus médicos ya pasaron de Mensaje.'
                : 'Cuando un médico diga que le interesa, aparecerá aquí para llamarlo.'
          }
        />
      )}

      {agenda.isSuccess && fase !== 'visita' && filas.length > 0 && (
        <DataTable
          rows={filas}
          rowKey={(l) => l.id}
          columns={columnas}
          noun={['médico', 'médicos']}
          summary={<Resumen leads={filas} hoy={hoy} ahora={ahora} />}
          rowTone={(l) => {
            const p = pendienteDe(l, hoy, ahora)
            if (p === 'visita_pasada' || p === 'llamar_atrasado') return 'error'
            if (p === 'visita_hoy' || p === 'llamar_hoy') return 'warning'
            return undefined
          }}
          exportar={{ archivo: `agenda-${fase}` }}
          onRowClick={abrir}
        />
      )}

      {agenda.isSuccess && delQueMira.length > 0 && fase === 'visita' && verVisitas === 'agendadas' && (
        <CalendarioDeReuniones
          leads={filtrarAgenda(buscados, { fase: 'visita' })}
          mes={mes}
          hoy={hoy}
          conLlamadas={false}
          onMes={(m) => cambiar({ mes: m === `${hoy.slice(0, 7)}-01` ? undefined : m })}
          onAbrir={abrir}
        />
      )}

      {agenda.isSuccess && delQueMira.length > 0 && fase === 'visita' && verVisitas === 'afiliados' && (
        <ListaDeAfiliados
          filas={ordenarAgenda(filtrarAgenda(buscados, { fase: 'visita', estado: 'convertido' }), hoy, ahora)}
          columnas={columnas}
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
          yo={yo}
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

/**
 * Las tres fases como pestañas grandes: la navegación de la Agenda. Cada una
 * con su número de médicos (de quien mira y con la búsqueda puesta).
 */
function PestanasDeFase({
  fase,
  cuentas,
  onFase,
}: {
  fase: Fase
  cuentas: ReturnType<typeof cuentaPorFase>
  onFase: (f: Fase) => void
}) {
  return (
    <div role="tablist" aria-label="Fase" className="mb-5 grid grid-cols-3 gap-2 sm:gap-3">
      {FASES.map((f, i) => {
        const Icono = ICONO_FASE[f]
        const activa = f === fase
        return (
          <button
            key={f}
            type="button"
            role="tab"
            aria-selected={activa}
            onClick={() => onFase(f)}
            className={`relative flex min-w-0 flex-col items-start gap-1 rounded-panel-card border px-3 py-3 text-left transition-colors sm:px-4 ${
              activa
                ? 'border-primary bg-primary/8 ring-1 ring-primary'
                : 'border-panel-hairline bg-panel-card hover:border-panel-hairline-strong hover:bg-panel-raised'
            }`}
          >
            <span className="flex w-full items-center gap-2">
              <span
                className={`flex size-6 shrink-0 items-center justify-center rounded-full type-panel-caption font-semibold ${
                  activa ? 'bg-primary text-on-primary' : 'bg-on-surface/8 text-on-surface-variant'
                }`}
              >
                {i + 1}
              </span>
              <Icono size={16} aria-hidden className={`max-sm:hidden ${activa ? 'text-primary' : 'text-on-surface-variant'}`} />
              <span className="truncate type-panel-control text-on-surface">{ROTULO_FASE[f].label}</span>
              <span className="ml-auto type-panel-section tabular-nums text-on-surface">{cuentas[f].total}</span>
            </span>
            <span className="truncate type-panel-caption text-on-surface-variant max-sm:hidden">
              {ROTULO_FASE[f].ayuda}
            </span>
          </button>
        )
      })}
    </div>
  )
}

function ListaDeAfiliados({
  filas,
  columnas,
  onAbrir,
}: {
  filas: Lead[]
  columnas: ReturnType<typeof columnasDeLaAgenda>
  onAbrir: (l: Lead) => void
}) {
  if (filas.length === 0) {
    return (
      <EmptyState
        icon={<BadgeCheck size={40} />}
        title="Todavía no hay afiliados"
        description="Al anotar «Visita realizada · Afiliado», o cuando su clínica recibe sus accesos, el médico aparece aquí."
      />
    )
  }
  return (
    <DataTable
      rows={filas}
      rowKey={(l) => l.id}
      columns={columnas}
      noun={['afiliado', 'afiliados']}
      exportar={{ archivo: 'agenda-afiliados' }}
      onRowClick={onAbrir}
    />
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

const TITULO_DE_LAS_CIFRAS: Record<Alcance, string> = {
  mios: 'Tus médicos',
  sin_asignar: 'Los médicos sin asignar',
  todos: 'Todo el equipo',
}

/**
 * Las cifras del embudo de quien mira (sus médicos, los sin asignar o los de
 * todo el equipo): contactados, citas agendadas y activados. Debajo, a un
 * clic, las de cada persona.
 */
function CifrasDeArriba({
  leads,
  todos,
  alcance,
  ahora,
  estado,
  onReintentar,
}: {
  leads: ReadonlyArray<Lead>
  todos: ReadonlyArray<Lead>
  alcance: Alcance
  ahora: Date
  estado: ReturnType<typeof estadoDeConsulta>
  onReintentar: () => void
}) {
  const [porPersona, setPorPersona] = useState(false)
  const c = useMemo(() => cifrasDeLaAgenda(leads, ahora), [leads, ahora])

  return (
    <section className="mb-6 flex flex-col gap-3">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="type-panel-label text-on-surface-variant">{TITULO_DE_LAS_CIFRAS[alcance]}</h2>
        <Button size="sm" variant="text" onClick={() => setPorPersona((v) => !v)}>
          <Users size={14} aria-hidden /> {porPersona ? 'Ocultar por persona' : 'Ver por persona'}
        </Button>
      </div>
      <StatGrid cols={3}>
        <Stat
          label="Médicos contactados"
          value={String(c.contactados)}
          hint={pie(`de ${c.apuntados} ${c.apuntados === 1 ? 'médico' : 'médicos'}`, porcentaje(c.contactados, c.apuntados))}
          info="Los que ya no están «Por contactar»: se les escribió, se les llamó o se les visitó, contestaran o no."
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
          hint={pie(
            `${c.conClinica} con su clínica dada de alta`,
            porcentaje(c.activados, c.contactados, ' de los contactados'),
          )}
          info="Los afiliados: se les visitó y capacitó, llenaron el formulario de afiliación o su clínica ya tiene sus accesos."
          estado={estado}
          onReintentar={onReintentar}
        />
      </StatGrid>
      {porPersona && estado === 'listo' && <TablaPorPersona leads={todos} ahora={ahora} />}
    </section>
  )
}

/** Las cifras de cada persona sobre los médicos que tiene asignados. */
function TablaPorPersona({ leads, ahora }: { leads: ReadonlyArray<Lead>; ahora: Date }) {
  const filas = useMemo(() => cifrasPorPersona(leads, ahora), [leads, ahora])
  return (
    <Table
      apilada
      headers={[
        'Persona',
        'Asignados',
        'Contactados',
        { label: 'Interesados', info: 'Los que pasaron a Llamada o más allá.' },
        'Citas agendadas',
        'Activados',
        { label: 'Activación', info: 'Activados sobre contactados.' },
      ]}
    >
      {filas.map((f) => (
        <Tr key={f.userId ?? 'sin-asignar'}>
          <Td className={f.userId === null ? 'text-on-surface-variant' : 'font-medium'}>{f.nombre}</Td>
          <Td className="tabular-nums">{f.apuntados}</Td>
          <Td className="tabular-nums">{f.contactados}</Td>
          <Td className="tabular-nums">{f.interesados}</Td>
          <Td className="tabular-nums">{f.citas}</Td>
          <Td className="tabular-nums">{f.activados}</Td>
          <Td className="tabular-nums">{porcentaje(f.activados, f.contactados) ?? '—'}</Td>
        </Tr>
      ))}
    </Table>
  )
}

/** Lo que hay para hoy en lo que se ve. */
function Resumen({ leads, hoy, ahora }: { leads: ReadonlyArray<Lead>; hoy: string; ahora: Date }) {
  const paraHoy = leads.filter((l) => pendienteDe(l, hoy, ahora) !== null).length
  return <>{paraHoy === 0 ? 'Nada pendiente para hoy' : `${paraHoy} para hoy, arriba`}</>
}
