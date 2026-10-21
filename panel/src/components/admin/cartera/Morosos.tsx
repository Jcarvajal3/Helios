import { useMemo, useState } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { PartyPopper } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { columnasCartera } from '@/components/admin/ColumnasCartera'
import { abrirCasoEnCola } from '@/components/admin/ficha-persona/CobranzaCola'
import { PerfilDeLosMorosos } from '@/components/admin/cartera/PerfilDeLosMorosos'
import { CifrasEnFila } from '@/components/admin/tableros/CifrasEnFila'
import {
  Badge,
  Button,
  Callout,
  Card,
  EmptyState,
  FilterBar,
  Input,
  Select,
  SkeletonBlock,
  SkeletonTable,
  diaOperativo,
  formatDateTime,
  formatDay,
  formatUsd,
  sumarDias,
} from '@/components/ui'
import { HORIZONTE_TODO, desgloseCorto, tramoDeFila, vencidoCobrable } from '@/features/admin/cobranza/cartera'
import type { CollectionRow, PartesDeDeuda } from '@/features/admin/cobranza/cartera'
import { ordenarPorAtraso } from '@/features/admin/cobranza/senales'
import { consultaCartera, consultaTasa } from '@/features/admin/cobranza/consultas'
import { cortesDeTramo, tramosConRotulo } from '@/features/admin/tramos'
import type { TramoVencido } from '@/features/admin/tramos'
import { useParametros } from '@/features/admin/useParametros'
import { describeError } from '@/lib/supabase'
import { csvInstante } from '@/lib/csv'

const TODOS_LOS_LOCALES = 'todos'
const CUALQUIER_TRAMO = 'cualquiera'
type OpcionTramo = TramoVencido | typeof CUALQUIER_TRAMO

/** Las columnas de la cola que se quedan, en este orden. */
const DE_LA_COLA = ['persona', 'estado', 'vencido', 'atraso', 'contacto', 'promesa', 'telefono', 'cuotas', 'acciones'] as const

/**
 * Por cobrar › Morosos: el padrón de quien debe algo vencido. Una fila por
 * persona, de quien más días lleva a quien menos.
 *
 * La Lista es la cola del día (lo vencido y lo que vence, con sus señales y
 * sus grupos); esto es solo la gente con deuda vencida, con su estado de
 * cuenta, desde cuándo debe y cuándo pagó por última vez. Sale de la misma
 * consulta que la Lista (`admin_collections` con la cola entera), así que no
 * cuesta otra llamada y las cifras no pueden discrepar.
 *
 * Es cobranza: lo vencido lleva la comisión dentro, siempre con sus dos partes a
 * la vista. Lo dado por perdido sigue en la lista —se sigue cobrando— y se
 * cuenta aparte.
 */
export function Morosos() {
  const navigate = useNavigate()
  const cartera = useQuery(consultaCartera(undefined, HORIZONTE_TODO))
  const parametros = useParametros()
  const tasa = useQuery(consultaTasa())
  const [buscar, setBuscar] = useState('')
  const [local, setLocal] = useState(TODOS_LOS_LOCALES)
  const [tramo, setTramo] = useState<OpcionTramo>(CUALQUIER_TRAMO)

  const cortes = cortesDeTramo(parametros.data)
  const ahora = new Date()
  const hoy = diaOperativo(ahora)

  // Moroso: debe alguna cuota vencida, aunque se haya dado por perdida.
  const morosos = useMemo(
    () => ordenarPorAtraso((cartera.data?.rows ?? []).filter((f) => f.overdueUsd > 0)),
    [cartera.data],
  )
  const locales = useMemo(
    () => [...new Set(morosos.flatMap((f) => f.merchants))].sort((a, b) => a.localeCompare(b, 'es')),
    [morosos],
  )
  const delLocal = useMemo(
    () => morosos.filter((f) => local === TODOS_LOS_LOCALES || f.merchants.includes(local)),
    [morosos, local],
  )
  const filas = useMemo(() => {
    const q = buscar.trim().toLowerCase()
    const digitos = q.replace(/\D/g, '')
    return delLocal.filter(
      (f) =>
        (tramo === CUALQUIER_TRAMO || (cortes !== null && tramoDeFila(f, cortes) === tramo)) &&
        (q === '' ||
          (f.fullName ?? '').toLowerCase().includes(q) ||
          (digitos.length >= 3 && (f.phone ?? '').includes(digitos))),
    )
  }, [delLocal, tramo, cortes, buscar])

  function abrirCaso(fila: CollectionRow, enPantalla: CollectionRow[]) {
    abrirCasoEnCola({ lista: 'morosos' }, enPantalla.map((f) => f.userId))
    void navigate({ to: '/admin/pacientes/$id', params: { id: fila.userId }, search: { tab: 'cobranza' } })
  }

  const columnas = (() => {
    const deLaCola = new Map(
      columnasCartera({
        hoy,
        cortes,
        tasa: tasa.data?.rate ?? null,
        ahora,
        diasBaja: cartera.data?.demotionDays ?? 0,
        horizonteDias: HORIZONTE_TODO,
        alAbrirCaso: (enPantalla) => abrirCasoEnCola({ lista: 'morosos' }, enPantalla.map((f) => f.userId)),
      }).map((c) => [c.key, c]),
    )
    const cols: Array<Column<CollectionRow>> = []
    for (const key of DE_LA_COLA) {
      const c = deLaCola.get(key)
      if (!c) continue
      if (key === 'estado') cols.push({ ...c, hidden: false })
      else if (key === 'vencido') cols.push(conLoPerdido(c))
      else cols.push(c)
      // Desde cuándo y el último pago van junto al atraso: se leen con él.
      if (key === 'atraso') cols.push(columnaDesde(hoy), columnaUltimoPago())
    }
    return cols
  })()

  if (cartera.isPending) {
    return (
      <div className="flex flex-col gap-4">
        <SkeletonBlock className="h-24 w-full rounded-panel-card" />
        <SkeletonTable rows={8} columns={6} />
      </div>
    )
  }

  if (cartera.isError) {
    return (
      <Callout
        tone="error"
        titulo="No se pudo leer la lista de morosos"
        accion={
          <Button size="sm" variant="tonal" onClick={() => void cartera.refetch()}>
            Reintentar
          </Button>
        }
      >
        {describeError(cartera.error)}
      </Callout>
    )
  }

  const opcionesTramo: Array<{ value: OpcionTramo; label: string }> = [
    { value: CUALQUIER_TRAMO, label: `Todos los tramos · ${delLocal.length}` },
    ...(cortes
      ? tramosConRotulo(cortes).map(({ tramo: t, rotulo }) => ({
          value: t,
          label: `${rotulo} · ${delLocal.filter((f) => tramoDeFila(f, cortes) === t).length}`,
        }))
      : []),
  ]
  const acotada = buscar.trim() !== '' || local !== TODOS_LOS_LOCALES || tramo !== CUALQUIER_TRAMO

  return (
    <>
      <CifrasDeMorosos filas={delLocal} />

      <FilterBar>
        <Input
          id="morosos-buscar"
          label="Buscar"
          placeholder="Nombre o teléfono"
          value={buscar}
          onChange={setBuscar}
          className="w-72"
        />
        {cortes && (
          <Select
            id="morosos-tramo"
            label="Atraso"
            value={tramo}
            options={opcionesTramo}
            onChange={setTramo}
            className="w-56"
          />
        )}
        {locales.length > 1 && (
          <Select
            id="morosos-local"
            label="Clínica"
            value={local}
            options={[
              { value: TODOS_LOS_LOCALES, label: 'Todas las clínicas' },
              ...locales.map((l) => ({ value: l, label: l })),
            ]}
            onChange={setLocal}
            className="w-56"
          />
        )}
      </FilterBar>

      {filas.length === 0 ? (
        <EmptyState
          icon={<PartyPopper size={40} />}
          title={acotada ? 'Nadie en esta lista' : 'Nadie debe nada vencido'}
          description={
            acotada
              ? 'Quita la búsqueda, el atraso o la clínica para ver a los demás.'
              : 'Ningún paciente tiene cuotas vencidas sin pagar.'
          }
        />
      ) : (
        <DataTable
          rows={filas}
          rowKey={(f) => f.userId}
          columns={columnas}
          noun={['moroso', 'morosos']}
          summary={<ResumenDeMorosos filas={filas} />}
          exportar={{ archivo: 'morosos' }}
          onRowClick={abrirCaso}
        />
      )}

      {/* De todos los morosos, no de la lista filtrada: el perfil compara a
          quien debe con quien está al día, y un filtro de local o de atraso
          dejaría la comparación a medias. */}
      <div className="mt-10">
        <PerfilDeLosMorosos />
      </div>
    </>
  )
}

/** Lo vencido de unas filas sin lo perdido, con sus dos partes, y lo perdido aparte. */
function sumarVencido(filas: ReadonlyArray<CollectionRow>): {
  cobrable: { usd: number; partes: PartesDeDeuda | null }
  perdido: { usd: number; personas: number }
} {
  let usd = 0
  let financedUsd = 0
  let feeUsd = 0
  let conPartes = true
  for (const f of filas) {
    const v = vencidoCobrable(f)
    usd += v.usd
    if (v.partes) {
      financedUsd += v.partes.financedUsd
      feeUsd += v.partes.feeUsd
    } else if (v.usd > 0) {
      conPartes = false
    }
  }
  return {
    cobrable: { usd, partes: conPartes ? { financedUsd, feeUsd } : null },
    perdido: {
      usd: filas.reduce((a, f) => a + f.lostUsd, 0),
      personas: filas.filter((f) => f.lostUsd > 0).length,
    },
  }
}

/**
 * Arriba de la tabla: cuánta gente debe algo vencido, cuánto (sin lo
 * perdido, con su desglose), lo perdido aparte y a cuántos nadie ha
 * contactado desde que se les venció.
 */
function CifrasDeMorosos({ filas }: { filas: ReadonlyArray<CollectionRow> }) {
  const { cobrable, perdido } = sumarVencido(filas)
  const sinContactar = filas.filter((f) => !f.contactedSinceDue).length
  return (
    <Card as="section" className="mb-5">
      <CifrasEnFila
        cifras={[
          {
            rotulo: 'Morosos',
            valor: String(filas.length),
            pie: filas.length === 1 ? 'paciente con deuda vencida' : 'pacientes con deuda vencida',
            info: 'Pacientes con alguna cuota vencida y sin pagar, incluidos los que tienen deuda dada por perdida.',
          },
          {
            rotulo: 'Vencido por cobrar',
            valor: formatUsd(cobrable.usd),
            pie: cobrable.partes && cobrable.usd > 0 ? desgloseCorto(cobrable.partes) : undefined,
            info: 'Las cuotas vencidas sin pagar, sin lo dado por perdido: lo que hay que transferir, financiamiento + Comisión Helios.',
          },
          {
            rotulo: 'Dado por perdido',
            valor: formatUsd(perdido.usd),
            pie: `${perdido.personas} ${perdido.personas === 1 ? 'paciente' : 'pacientes'}`,
            info: 'La deuda vencida que se dio por perdida. Se sigue cobrando, pero no cuenta como por cobrar.',
          },
          {
            rotulo: 'Sin contactar',
            valor: String(sinContactar),
            pie: 'desde que se les venció',
            info: 'Morosos sin ninguna gestión anotada desde el vencimiento de su cuota pendiente más antigua.',
          },
        ]}
      />
    </Card>
  )
}

/** Junto al recuento de la tabla: lo que suman las filas que se ven. */
function ResumenDeMorosos({ filas }: { filas: ReadonlyArray<CollectionRow> }) {
  const { cobrable, perdido } = sumarVencido(filas)
  return (
    <span>
      {formatUsd(cobrable.usd)} vencido
      {cobrable.partes && cobrable.usd > 0 && ` (${desgloseCorto(cobrable.partes)})`}
      {perdido.usd > 0 && ` · ${formatUsd(perdido.usd)} dado por perdido`}
    </span>
  )
}

/** La columna de lo vencido de la cola, con lo dado por perdido dicho debajo. */
function conLoPerdido(c: Column<CollectionRow>): Column<CollectionRow> {
  return {
    ...c,
    cell: (r, enPantalla) => (
      <>
        {c.cell(r, enPantalla)}
        {r.lostUsd > 0 && (
          <span className="mt-1 block">
            <Badge>
              {r.lostUsd >= r.overdueUsd ? 'Todo dado por perdido' : `${formatUsd(r.lostUsd)} dado por perdido`}
            </Badge>
          </span>
        )}
      </>
    ),
  }
}

/** El día en que venció su cuota sin pagar más antigua: `hoy - días de atraso`. */
function columnaDesde(hoy: string): Column<CollectionRow> {
  const desde = (r: CollectionRow) => sumarDias(hoy, -r.daysOverdue)
  return {
    key: 'desde',
    header: 'Debe desde',
    info: 'El día en que venció su cuota sin pagar más antigua.',
    sort: (r) => desde(r),
    csv: (r) => desde(r),
    cell: (r) => <span className="tabular-nums">{formatDay(desde(r))}</span>,
  }
}

function columnaUltimoPago(): Column<CollectionRow> {
  return {
    key: 'ultimoPago',
    header: 'Último pago',
    sortDir: 'desc',
    info: 'Cuándo reportó su último pago aprobado, de cualquier cuota. «Nunca ha pagado»: no tiene ningún pago aprobado.',
    sort: (r) => r.lastPaymentAt,
    csv: (r) => (r.lastPaymentAt ? csvInstante(r.lastPaymentAt) : null),
    cell: (r) =>
      r.lastPaymentAt ? (
        <span className="type-panel-caption tabular-nums text-on-surface-variant">
          {formatDateTime(r.lastPaymentAt)}
        </span>
      ) : (
        <Badge tone="warning">Nunca ha pagado</Badge>
      ),
  }
}
