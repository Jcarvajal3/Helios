import { useState } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { ArrowRight, CheckCircle2, Inbox, Smartphone, TriangleAlert } from 'lucide-react'

import { DataTable, ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { VerCaptura } from '@/components/admin/caja/VerCaptura'
import {
  Badge,
  EmptyState,
  ErrorBox,
  FilterBar,
  Filtro,
  SearchInput,
  Segmented,
  SkeletonTable,
  claseDeBoton,
  formatDateTime,
  formatDay,
  formatPhone,
  formatUsd,
  formatVes,
  formatWaiting,
  hoyCaracas,
} from '@/components/ui'
import { formatTasa } from '@/features/admin/ajustesReglas'
import { consultaColaPagosCompra } from '@/features/admin/compras/consultas'
import {
  etiquetaDeMetodoPago,
  visualPagoCompra,
} from '@/features/admin/compras/estados'
import type { EstadoPagoCompra, PagoCompraReporte } from '@/features/admin/compras/tipos'
import {
  MARGEN_POR_DEFECTO,
  diferenciaEnBs,
} from '@/features/admin/pagosRegistrados/registrarPago'
import { csvDinero, csvInstante } from '@/lib/csv'
import { describeError } from '@/lib/supabase'
import { EstadoPagoCompraBadge } from './EstadoCompraBadge'

type VistaColaPagos = 'pendientes' | 'aprobados' | 'rechazados'

const ESTADOS_POR_VISTA: Record<VistaColaPagos, EstadoPagoCompra[]> = {
  pendientes: ['reported', 'in_review'],
  aprobados: ['reconciled'],
  rechazados: ['rejected', 'duplicate'],
}

export function ColaPagosCompras() {
  const navigate = useNavigate()
  const [vista, setVista] = useState<VistaColaPagos>('pendientes')
  const [q, setQ] = useState('')

  const query = useQuery(consultaColaPagosCompra(ESTADOS_POR_VISTA[vista]))

  const filtrados = (query.data ?? []).filter((p) => {
    const busq = q.trim().toLowerCase()
    if (!busq) return true
    const texto = [
      p.requestCode,
      p.merchantName,
      p.doctorName,
      p.phone,
      p.bank,
      p.reference,
      p.productTitle,
    ]
      .filter(Boolean)
      .join(' ')
      .toLowerCase()
    return texto.includes(busq)
  })

  const totalUsd = filtrados.reduce((s, p) => s + p.amountUsd, 0)

  return (
    <div className="flex flex-col gap-shell-gap-block">
      <FilterBar className="mb-0">
        <Filtro label="Estado">
          <Segmented
            options={[
              { value: 'pendientes', label: 'Por aprobar' },
              { value: 'aprobados', label: 'Aprobados' },
              { value: 'rechazados', label: 'Rechazados / Duplicados' },
            ]}
            value={vista}
            onChange={setVista}
          />
        </Filtro>
        <SearchInput
          id="compras-pagos-buscar"
          label="Buscar"
          value={q}
          onChange={setQ}
          placeholder="#C-, médico, banco o referencia"
          className="w-full sm:w-80"
        />
      </FilterBar>

      {query.isPending && <SkeletonTable rows={6} columns={7} />}

      {query.isError && (
        <ErrorBox
          title="No se pudo cargar la cola de pagos de compras"
          detail={describeError(query.error)}
        />
      )}

      {query.data && filtrados.length === 0 && (
        <EmptyState
          icon={<Inbox size={44} />}
          title={
            vista === 'pendientes'
              ? 'No hay pagos de compras por aprobar'
              : vista === 'aprobados'
                ? 'Todavía no se ha aprobado ningún pago'
                : 'No hay pagos rechazados ni duplicados'
          }
          description={
            vista === 'pendientes'
              ? 'Cuando un médico reporte un Pago Móvil o transferencia por WhatsApp o desde el Simulador, aparecerá aquí para conciliarlo.'
              : 'Los pagos resueltos quedan archivados en esta vista para consulta y auditoría.'
          }
        />
      )}

      {query.data && filtrados.length > 0 && (
        <DataTable
          rows={filtrados}
          rowKey={(p) => p.id}
          columns={COLUMNAS}
          noun={['pago', 'pagos']}
          summary={`${formatUsd(totalUsd)} en pagos visibles`}
          exportar={{ archivo: `pagos-compras-amazon-${vista}-${hoyCaracas()}` }}
          rowTone={(p) => {
            if (p.status !== 'reported' && p.status !== 'in_review') return undefined
            const diff = diferenciaEnBs(p.amountVes, p.expectedVes, p.fxRate, MARGEN_POR_DEFECTO)
            return diff && !diff.cuadra ? 'warning' : undefined
          }}
          onRowClick={(p) => {
            void navigate({ to: '/admin/compras/$id', params: { id: p.requestId } })
          }}
        />
      )}
    </div>
  )
}

const COLUMNAS: Array<Column<PagoCompraReporte>> = [
  {
    key: 'solicitud',
    header: 'Solicitud y médico',
    identity: true,
    sort: (p) => p.requestNumber ?? 0,
    sortDir: 'desc',
    csv: (p) => p.requestCode ?? p.requestId,
    cell: (p) => (
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-1.5">
          <Link
            to="/admin/compras/$id"
            params={{ id: p.requestId }}
            className={`${ENLACE_EN_CELDA} font-mono`}
          >
            {p.requestCode ?? 'Solicitud'}
          </Link>
          {p.channel === 'simulador' && (
            <Badge tone="neutral" icono={Smartphone}>
              Simulador
            </Badge>
          )}
        </div>
        <p className="mt-0.5 type-panel-caption text-on-surface-variant">
          {p.merchantName ?? 'Clínica'}
          {p.phone ? ` · ${formatPhone(p.phone)}` : ''}
        </p>
      </div>
    ),
  },
  {
    key: 'medio',
    header: 'Medio y referencia',
    sort: (p) => p.reference,
    csv: (p) => `${etiquetaDeMetodoPago(p.method)} · ${p.bank ?? ''} · ${p.reference ?? ''}`,
    cell: (p) => (
      <div>
        <p className="font-mono text-on-surface">{p.reference ?? '—'}</p>
        <p className="mt-0.5 type-panel-caption text-on-surface-variant">
          {etiquetaDeMetodoPago(p.method)} · {p.bank ?? 'Sin banco'}
        </p>
      </div>
    ),
  },
  {
    key: 'fecha',
    header: 'Fecha de pago',
    sort: (p) => p.paidOn,
    sortDir: 'desc',
    csv: (p) => p.paidOn,
    cell: (p) => (
      <div className="whitespace-nowrap">
        <p className="tabular-nums text-on-surface">{formatDay(p.paidOn)}</p>
        <p className="mt-0.5 type-panel-caption text-on-surface-variant">
          {p.status === 'reported' || p.status === 'in_review'
            ? `hace ${formatWaiting(Math.floor((Date.now() - new Date(p.createdAt).getTime()) / 1000))}`
            : formatDateTime(p.createdAt)}
        </p>
      </div>
    ),
  },
  {
    key: 'montos',
    header: 'Reportado vs Esperado (Bs)',
    info: 'Margen operativo de cuadre: −10 Bs a +100 Bs frente al monto esperado a la tasa BCV de la fecha del pago.',
    type: 'number',
    sort: (p) => p.amountVes,
    sortDir: 'desc',
    csv: (p) => csvDinero(p.amountVes),
    cell: (p) => {
      const diff = diferenciaEnBs(p.amountVes, p.expectedVes, p.fxRate, MARGEN_POR_DEFECTO)
      return (
        <div className="flex flex-col items-end">
          <span className="font-semibold text-on-surface">{formatVes(p.amountVes)}</span>
          <span className="mt-0.5 type-panel-caption text-on-surface-variant">
            {p.expectedVes !== null ? `Esp. ${formatVes(p.expectedVes)}` : formatUsd(p.amountUsd)}
            {p.fxRate !== null ? ` · ${formatTasa(p.fxRate, 'USD')}` : ''}
          </span>
          {diff && (
            <span className="mt-1">
              {diff.cuadra ? (
                <Badge tone="success" icono={CheckCircle2}>
                  Cuadra ({diff.bs >= 0 ? '+' : '−'}
                  {formatVes(Math.abs(diff.bs))})
                </Badge>
              ) : (
                <Badge tone="warning" icono={TriangleAlert}>
                  Dif. {diff.bs >= 0 ? '+' : '−'}
                  {formatVes(Math.abs(diff.bs))}
                </Badge>
              )}
            </span>
          )}
        </div>
      )
    },
  },
  {
    key: 'comprobante',
    header: 'Captura',
    cell: (p) =>
      p.receiptPath ? (
        <VerCaptura ruta={p.receiptPath} rotulo="Ver captura" />
      ) : (
        <span className="type-panel-caption text-panel-muted">Sin captura</span>
      ),
  },
  {
    key: 'estado',
    header: 'Estado',
    sort: (p) => p.status,
    csv: (p) => visualPagoCompra(p.status).label,
    cell: (p) => <EstadoPagoCompraBadge valor={p.status} />,
  },
  {
    key: 'reportado',
    header: 'Reportado el',
    hidden: true,
    sort: (p) => p.createdAt,
    sortDir: 'desc',
    csv: (p) => csvInstante(p.createdAt),
    cell: (p) => formatDateTime(p.createdAt),
  },
  {
    key: 'accion',
    header: '',
    cell: (p) => (
      <Link
        to="/admin/compras/$id"
        params={{ id: p.requestId }}
        className={claseDeBoton('tonal', 'sm')}
      >
        Conciliar <ArrowRight size={14} aria-hidden />
      </Link>
    ),
  },
]
