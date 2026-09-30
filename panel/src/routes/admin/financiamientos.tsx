import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { ReceiptText } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import { BuscadorEnUrl, FiltroFechas } from '@/components/FiltrosDeLista'
import { COLUMNAS_CONSUMOS } from '@/components/admin/directorio/columnasConsumos'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import {
  EmptyState,
  FilterBar,
  Filtro,
  Segmented,
  Select,
  SkeletonTable,
  diaOperativo,
  formatUsd,
} from '@/components/ui'
import { fetchMerchants } from '@/features/admin/api'
import {
  ESTADOS_CONSUMO,
  VALORES_ESTADO_CONSUMO,
  opcionesDeEstado,
} from '@/features/admin/estados'
import type { EstadoConsumo } from '@/features/admin/estados'
import { fetchCharges } from '@/features/admin/ops'
import type { ChargeRow } from '@/features/admin/ops'
import { comoDia, comoId, comoTexto, unoDe } from '@/lib/busqueda'

type ConsumosSearch = {
  q?: string
  estado?: EstadoConsumo
  local?: string
  desde?: string
  hasta?: string
}

/**
 * Cuántos consumos pide la lista. Con nombre porque la tabla lo necesita para
 * decir que se quedó corta.
 */
const LIMITE = 200

export const Route = createFileRoute('/admin/financiamientos')({
  staticData: { title: 'Financiamientos', width: 'wide' },
  component: ConsumosPage,
  validateSearch: (search: Record<string, unknown>): ConsumosSearch => ({
    q: comoTexto(search.q),
    estado: unoDe(VALORES_ESTADO_CONSUMO, search.estado),
    local: comoId(search.local),
    desde: comoDia(search.desde),
    hasta: comoDia(search.hasta),
  }),
})

const FILTROS_ESTADO = opcionesDeEstado(VALORES_ESTADO_CONSUMO, ESTADOS_CONSUMO)

/**
 * Consumos: todo lo que se vendió.
 *
 * La lista sirve para encontrar un consumo concreto: la llamada que entra es
 * siempre por uno. Las ventas por local y noche, para la conversación con el
 * local, son la tabla de Métricas › Semana › Resumen, y cada noche de allí
 * abre esta lista con ese local y ese día.
 *
 * Las fechas son de **día operativo** (10 a. m. a 10 a. m.), igual que lo ve
 * el local en su panel.
 */
function ConsumosPage() {
  const navigate = useNavigate({ from: '/admin/financiamientos' })
  const search = Route.useSearch()

  const merchants = useQuery({ queryKey: ['merchants'], queryFn: fetchMerchants })

  const opcionesLocal: Array<{ value: string; label: string }> = [
    { value: '', label: 'Todas las clínicas' },
    ...(merchants.data ?? []).map((m) => ({ value: m.id, label: m.name })),
  ]

  /** Un filtro es un paso del historial; una búsqueda que se teclea, no. */
  function cambiar(patch: Partial<ConsumosSearch>, replace = false) {
    void navigate({ search: (prev) => ({ ...prev, ...patch }), replace })
  }

  return (
    <>
      <Lista search={search} opcionesLocal={opcionesLocal} onCambiar={cambiar} />
    </>
  )
}

// ── La lista ───────────────────────────────────────────────────────────────

function Lista({
  search,
  opcionesLocal,
  onCambiar,
}: {
  search: ConsumosSearch
  opcionesLocal: Array<{ value: string; label: string }>
  onCambiar: (patch: Partial<ConsumosSearch>, replace?: boolean) => void
}) {
  const navigate = useNavigate()

  const query = useQuery({
    // El tope va en la clave: el buscador de arriba pide otra cantidad con la
    // misma búsqueda y no puede prestarle su respuesta a esta lista.
    queryKey: [
      'admin-charges',
      'lista',
      search.q ?? '',
      search.estado ?? '',
      search.local ?? '',
      search.desde ?? '',
      search.hasta ?? '',
      LIMITE,
    ],
    queryFn: () =>
      fetchCharges({
        search: search.q,
        status: search.estado ?? null,
        merchantId: search.local ?? null,
        from: search.desde ?? null,
        to: search.hasta ?? null,
        limit: LIMITE,
      }),
  })

  return (
    <>
      <FilterBar>
        <BuscadorEnUrl
          id="buscar-consumo"
          valor={search.q}
          placeholder="Orden, teléfono, nombre, cédula o clínica"
          onBuscar={(q) => onCambiar({ q }, true)}
        />
        <Filtro label="Estado">
          <Segmented
            options={FILTROS_ESTADO}
            value={search.estado ?? ''}
            onChange={(value) => onCambiar({ estado: value || undefined })}
          />
        </Filtro>
        <Select
          id="filtro-local"
          label="Clínica"
          value={search.local ?? ''}
          options={opcionesLocal}
          onChange={(value) => onCambiar({ local: value || undefined })}
          className="w-52"
        />
        <FiltroFechas
          id="consumos-fechas"
          label="Día operativo"
          desde={search.desde}
          hasta={search.hasta}
          max={diaOperativo()}
          onChange={(rango) => onCambiar(rango)}
        />
      </FilterBar>

      {query.isPending && <SkeletonTable rows={8} columns={6} />}

      {query.isError && (
        <SeccionSinLeer
          titulo="No se pudieron leer los financiamientos"
          error={query.error}
          onReintentar={() => void query.refetch()}
        />
      )}

      {query.isSuccess && query.data.length === 0 && (
        <EmptyState
          icon={<ReceiptText size={40} />}
          title="Ningún financiamiento con estos filtros"
          description="Prueba a ampliar el rango de días o a quitar el filtro de clínica."
        />
      )}

      {query.isSuccess && query.data.length > 0 && (
        <DataTable
          rows={query.data}
          rowKey={(c) => c.chargeId}
          columns={COLUMNAS_CONSUMOS}
          noun={['orden', 'órdenes']}
          summary={<ResumenConsumos filas={query.data} alTope={query.data.length >= LIMITE} />}
          limit={LIMITE}
          exportar={{ archivo: 'consumos' }}
          onRowClick={(c) => void navigate({ to: '/admin/financiamientos/$id', params: { id: c.chargeId } })}
        />
      )}
    </>
  )
}

/**
 * Las cifras de lo que se ve, sin el service fee. Las órdenes son las filas
 * en cualquier estado; los consumos, solo las confirmadas. Los consumos de
 * prueba se ven en la tabla con su etiqueta pero no suman: si sumaran, esta
 * pantalla contradiría a Inicio. Con la lista en su tope, las cifras son de
 * esas filas y no del periodo: se dice.
 */
function ResumenConsumos({ filas, alTope }: { filas: Array<ChargeRow>; alTope: boolean }) {
  const confirmados = filas.filter((r) => r.status === 'confirmed' && !r.isTest)
  const consumo = confirmados.reduce((s, r) => s + r.financedUsd, 0)
  const ticket = confirmados.length > 0 ? consumo / confirmados.length : null

  return (
    <>
      {alTope ? `en estas ${filas.length} órdenes: ` : ''}
      {confirmados.length} {confirmados.length === 1 ? 'financiamiento confirmado' : 'financiamientos confirmados'} ·{' '}
      {formatUsd(consumo)} financiado (sin fee)
      {ticket !== null && ` · ticket medio (sin fee) ${formatUsd(ticket)}`}
    </>
  )
}
