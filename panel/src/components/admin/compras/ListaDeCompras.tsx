import { Link, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Package, Plane, ShieldAlert, Ship, Smartphone } from 'lucide-react'

import { DataTable, ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { BuscadorEnUrl } from '@/components/FiltrosDeLista'
import {
  Badge,
  Button,
  EmptyState,
  ErrorBox,
  FilterBar,
  Filtro,
  Segmented,
  Select,
  SkeletonTable,
  Stat,
  StatGrid,
  estadoDeConsulta,
  formatDateTime,
  formatPhone,
  formatUsd,
  formatVes,
  hoyCaracas,
} from '@/components/ui'
import {
  consultaConteosCompras,
  consultaSolicitudesCompra,
} from '@/features/admin/compras/consultas'
import {
  ESTADOS_SOLICITUD_COMPRA,
  VALORES_ESTADO_SOLICITUD,
  etiquetaDeCanal,
  etiquetaDeEnvio,
  visualSolicitudCompra,
} from '@/features/admin/compras/estados'
import type {
  CanalCompra,
  EstadoSolicitudCompra,
  SolicitudCompraResumen,
} from '@/features/admin/compras/tipos'
import { csvDinero, csvInstante } from '@/lib/csv'
import { describeError } from '@/lib/supabase'
import { EstadoSolicitudCompraBadge } from './EstadoCompraBadge'

/** Sin `canal` se ven las operativas (WhatsApp): el simulador solo entra si se pide. */
export type FiltroCanalCompra = CanalCompra | 'todos'

export type FiltrosListaCompras = {
  q?: string
  estado?: EstadoSolicitudCompra
  canal?: FiltroCanalCompra
}

export function ListaDeCompras({
  filtros,
  onCambiar,
}: {
  filtros: FiltrosListaCompras
  onCambiar: (patch: Partial<FiltrosListaCompras>, reemplazar?: boolean) => void
}) {
  const navigate = useNavigate()
  const conteos = useQuery(consultaConteosCompras())
  const canal: FiltroCanalCompra = filtros.canal ?? 'whatsapp'
  const solicitudes = useQuery(
    consultaSolicitudesCompra({
      statuses: filtros.estado ? [filtros.estado] : null,
      channel: canal === 'todos' ? null : canal,
      search: filtros.q ?? null,
      limit: 150,
    }),
  )

  const hayFiltros = Boolean(filtros.q || filtros.estado || filtros.canal)
  const deSimulador = conteos.data?.simulador ?? 0
  const filas = solicitudes.data ?? []
  const totalUsd = filas.reduce((s, r) => s + r.totalUsd, 0)

  const opcionesEstado: Array<{
    value: EstadoSolicitudCompra | ''
    label: string
  }> = [
    { value: '', label: 'Todos los estados' },
    ...VALORES_ESTADO_SOLICITUD.map((e) => ({
      value: e,
      label: ESTADOS_SOLICITUD_COMPRA[e].plural,
    })),
  ]

  return (
    <div className="flex flex-col gap-shell-gap-block">
      <StatGrid cols={4}>
        <Stat
          label="Revisión aduanal"
          value={String(conteos.data?.revisionAduanal ?? 0)}
          estado={estadoDeConsulta(conteos)}
          onReintentar={() => void conteos.refetch()}
          senal={
            (conteos.data?.revisionAduanal ?? 0) > 0
              ? { tone: 'warning', texto: 'Requiere permiso' }
              : undefined
          }
          hint="Insumos restringidos antes del pago (sin simulador)"
        />
        <Stat
          label="Pagos por aprobar"
          value={String(conteos.data?.pagosPendientes ?? 0)}
          estado={estadoDeConsulta(conteos)}
          onReintentar={() => void conteos.refetch()}
          senal={
            (conteos.data?.pagosPendientes ?? 0) > 0
              ? { tone: 'warning', texto: 'Por conciliar' }
              : undefined
          }
          hint="Comprobantes en bolívares reportados"
        />
        <Stat
          label="Esperando pago"
          value={String(conteos.data?.esperandoPago ?? 0)}
          estado={estadoDeConsulta(conteos)}
          onReintentar={() => void conteos.refetch()}
          hint="Cotizaciones aprobadas sin pago"
        />
        <Stat
          label="En procura / tránsito"
          value={String(
            (conteos.data?.enProcura ?? 0) + (conteos.data?.enTransito ?? 0),
          )}
          estado={estadoDeConsulta(conteos)}
          onReintentar={() => void conteos.refetch()}
          hint={
            conteos.data && conteos.data.listoEntrega > 0
              ? `${conteos.data.listoEntrega} listo${conteos.data.listoEntrega === 1 ? '' : 's'} para entrega`
              : 'Pagados, comprados y en ruta a Venezuela'
          }
        />
      </StatGrid>

      <FilterBar className="mb-0">
        <BuscadorEnUrl
          id="compras-buscar"
          valor={filtros.q}
          onBuscar={(q) => onCambiar({ q }, true)}
          placeholder="#C-0001, médico, producto o ASIN"
          className="w-full sm:w-80"
        />
        <Select
          id="compras-estado"
          label="Estado"
          value={filtros.estado ?? ''}
          options={opcionesEstado}
          onChange={(v) => onCambiar({ estado: v === '' ? undefined : v })}
          className="w-56"
        />
        <Filtro label="Canal">
          <Segmented
            options={[
              { value: 'whatsapp', label: 'WhatsApp (operativas)' },
              {
                value: 'simulador',
                label: `Solo simulador${deSimulador > 0 ? ` (${deSimulador})` : ''}`,
              },
              { value: 'todos', label: 'Incluir simulador' },
            ]}
            value={canal}
            onChange={(v) =>
              onCambiar({ canal: v === 'whatsapp' ? undefined : v })
            }
          />
        </Filtro>
      </FilterBar>

      {canal !== 'whatsapp' && (
        <p className="type-panel-caption text-on-surface-variant">
          Las solicitudes del simulador son pruebas: no entran en los números de
          arriba ni en las colas.
        </p>
      )}

      {solicitudes.isPending && <SkeletonTable rows={6} columns={7} />}

      {solicitudes.isError && (
        <ErrorBox
          title="No se pudo cargar la lista de compras Amazon"
          detail={describeError(solicitudes.error)}
        />
      )}

      {solicitudes.data && filas.length === 0 && (
        <EmptyState
          icon={<Package size={44} />}
          title={
            hayFiltros
              ? 'Ninguna solicitud con estos filtros'
              : 'Todavía no hay solicitudes de compra'
          }
          description={
            hayFiltros
              ? 'Prueba quitando el filtro de estado, canal o búsqueda.'
              : 'Cuando un médico cotice un insumo por WhatsApp o desde el Simulador, aparecerá aquí.'
          }
          action={
            hayFiltros ? (
              <Button
                size="md"
                variant="tonal"
                onClick={() =>
                  onCambiar({
                    q: undefined,
                    estado: undefined,
                    canal: undefined,
                  })
                }
              >
                Quitar los filtros
              </Button>
            ) : undefined
          }
        />
      )}

      {solicitudes.data && filas.length > 0 && (
        <DataTable
          rows={filas}
          rowKey={(r) => r.id}
          columns={COLUMNAS}
          limit={150}
          noun={['solicitud', 'solicitudes']}
          summary={`${formatUsd(totalUsd)} en cotizaciones visibles`}
          exportar={{ archivo: `compras-amazon-${hoyCaracas()}` }}
          rowTone={(r) =>
            r.status === 'revision_aduanal' || r.status === 'pago_reportado'
              ? 'warning'
              : undefined
          }
          onRowClick={(r) => {
            void navigate({ to: '/admin/compras/$id', params: { id: r.id } })
          }}
        />
      )}
    </div>
  )
}

const COLUMNAS: Array<Column<SolicitudCompraResumen>> = [
  {
    key: 'codigo',
    header: '#Solicitud',
    identity: true,
    sort: (r) => r.requestNumber,
    sortDir: 'desc',
    csv: (r) => r.code,
    cell: (r) => (
      <div className="min-w-0">
        <Link
          to="/admin/compras/$id"
          params={{ id: r.id }}
          className={`${ENLACE_EN_CELDA} font-mono`}
        >
          {r.code}
        </Link>
        <div className="mt-1 flex flex-wrap gap-1">
          {r.channel === 'simulador' && (
            <Badge tone="neutral" icono={Smartphone}>
              Simulador
            </Badge>
          )}
          {r.restrictedFlag && (
            <Badge tone="warning" icono={ShieldAlert}>
              Aduana
            </Badge>
          )}
        </div>
      </div>
    ),
  },
  {
    key: 'medico',
    header: 'Médico',
    sort: (r) => r.merchantName,
    csv: (r) =>
      r.doctorName ? `${r.merchantName} (${r.doctorName})` : r.merchantName,
    cell: (r) => (
      <div className="min-w-0">
        <p className="font-medium text-on-surface">{r.merchantName}</p>
        <p className="mt-0.5 type-panel-caption tabular-nums text-on-surface-variant">
          {r.doctorName ? `${r.doctorName} · ` : ''}
          {formatPhone(r.phone)}
        </p>
      </div>
    ),
  },
  {
    key: 'producto',
    header: 'Producto / ASIN',
    sort: (r) => r.productTitle,
    csv: (r) => `${r.productTitle} (${r.asin})`,
    cell: (r) => (
      <div className="max-w-xs min-w-0">
        <p className="line-clamp-2 text-on-surface">{r.productTitle}</p>
        <p className="mt-0.5 type-panel-caption text-on-surface-variant">
          <span className="font-mono">{r.asin}</span>
          {r.quantity > 1 && ` · ×${r.quantity}`}
          {r.variantLabel && ` · ${r.variantLabel}`}
        </p>
      </div>
    ),
  },
  {
    key: 'envio',
    header: 'Envío',
    sort: (r) => r.shippingMethod,
    csv: (r) => etiquetaDeEnvio(r.shippingMethod),
    cell: (r) => (
      <Badge
        tone="neutral"
        icono={r.shippingMethod === 'maritimo' ? Ship : Plane}
      >
        {etiquetaDeEnvio(r.shippingMethod)}
      </Badge>
    ),
  },
  {
    key: 'total',
    header: 'Total USD / Bs',
    type: 'number',
    sort: (r) => r.totalUsd,
    sortDir: 'desc',
    csv: (r) => csvDinero(r.totalUsd),
    cell: (r) => (
      <>
        <span className="font-semibold text-on-surface">
          {formatUsd(r.totalUsd)}
        </span>
        <span className="mt-0.5 block type-panel-caption font-normal text-on-surface-variant">
          {r.totalVesQuote !== null
            ? formatVes(r.totalVesQuote)
            : 'Sin total en Bs'}
        </span>
      </>
    ),
  },
  {
    key: 'estado',
    header: 'Estado',
    sort: (r) => r.status,
    csv: (r) => visualSolicitudCompra(r.status).label,
    cell: (r) => <EstadoSolicitudCompraBadge valor={r.status} />,
  },
  {
    key: 'canal',
    header: 'Canal',
    hidden: true,
    sort: (r) => r.channel,
    csv: (r) => etiquetaDeCanal(r.channel),
    cell: (r) => etiquetaDeCanal(r.channel),
  },
  {
    key: 'fecha',
    header: 'Fecha',
    sort: (r) => r.createdAt,
    sortDir: 'desc',
    csv: (r) => csvInstante(r.createdAt),
    cell: (r) => (
      <span className="whitespace-nowrap text-on-surface-variant">
        {formatDateTime(r.createdAt)}
      </span>
    ),
  },
]
