import { Link, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Landmark } from 'lucide-react'

import { DataTable, ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import {
  Badge,
  EmptyState,
  ErrorBox,
  InfoDot,
  SectionTitle,
  SkeletonTable,
  formatDay,
  formatUsd,
} from '@/components/ui'
import { fetchRunPayables } from '@/features/admin/api'
import type { RunPayable, SettlementRun } from '@/features/admin/api'
import { csvDinero } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

/** Por debajo de medio céntimo, un cierre está saldado. */
const SALDADO = 0.005

/** Cómo se llama un cierre en el desplegable, sin tener que abrirlo. */
export function estadoDelCierre(run: SettlementRun): string {
  if (run.isNext) return 'en curso'
  if (!run.isPast) return 'por llegar'
  return run.pendienteUsd > SALDADO ? `quedan ${formatUsd(run.pendienteUsd)}` : 'saldado'
}

/**
 * Un cierre de caja, local a local.
 *
 * Aquí no hay proyección: un cierre es lo que fue. Las tres cifras son las de
 * esa semana (se generó, se transfirió, quedó a deber) y cada fila abre el
 * local con ESE cierre, incluidas sus líneas ya pagadas.
 */
export function UnCierreDeCaja({ run }: { run: SettlementRun }) {
  const navigate = useNavigate()

  const rows = useQuery({
    queryKey: ['run-payables', run.runDate],
    queryFn: () => fetchRunPayables(run.runDate),
  })

  const saldado = run.pendienteUsd <= SALDADO

  return (
    <>
      <div className="mb-1 flex flex-wrap items-center gap-2">
        <SectionTitle>Cierre del {formatDay(run.runDate)}</SectionTitle>
        <InfoDot
          title={`Cierre del ${formatDay(run.runDate)}`}
          what="Lo que quede sin transferir sigue contando como atrasado en «Lo que se debe hoy»."
        />
        {run.isNext ? (
          <Badge tone="neutral">En curso</Badge>
        ) : !run.isPast ? (
          <Badge tone="neutral">Por llegar</Badge>
        ) : saldado ? (
          <Badge tone="success" icono>
            Saldado
          </Badge>
        ) : (
          <Badge tone="error" icono>
            Sin pagar
          </Badge>
        )}
      </div>

      <p className="mb-4 type-panel-caption text-on-surface-variant">
        Liquidaciones con vencimiento del {formatDay(run.primerVencimiento)} al{' '}
        {formatDay(run.ultimoVencimiento)}.
      </p>

      {rows.isPending && <SkeletonTable rows={4} columns={4} />}

      {rows.isError && (
        <ErrorBox title="No se pudo cargar el cierre" detail={describeError(rows.error)} />
      )}

      {rows.data?.length === 0 && (
        <EmptyState
          icon={<Landmark size={40} />}
          title="Este cierre no tiene nada"
          description="No hay ninguna liquidación con vencimiento en esa semana."
        />
      )}

      {rows.data && rows.data.length > 0 && (
        <DataTable
          rows={rows.data}
          rowKey={(m) => m.merchantId}
          columns={COLUMNAS}
          noun={['clínica', 'clínicas']}
          summary={
            <>
              se generaron {formatUsd(run.generadoUsd)} · se transfirieron{' '}
              {formatUsd(run.transferidoUsd)} ·{' '}
              {formatUsd(run.pendienteUsd)} {run.isPast ? 'sin pagar' : 'por transferir'}
              {run.pendientePruebaUsd > 0 &&
                ` · ${formatUsd(run.pendientePruebaUsd)} en clínicas de prueba, aparte`}
            </>
          }
          exportar={{ archivo: `cierre-${run.runDate}` }}
          rowTone={(m) => (m.pendienteUsd > SALDADO && run.isPast && !m.isTest ? 'error' : undefined)}
          // El cierre viaja con el enlace: quien entra desde la semana del 14
          // quiere ver esa semana, no todo lo que se le debe al local.
          onRowClick={(m) =>
            void navigate({
              to: '/admin/pagos-clinicas/$id',
              params: { id: m.merchantId },
              search: { cierre: run.runDate },
            })
          }
        />
      )}
    </>
  )
}

const COLUMNAS: Array<Column<RunPayable>> = [
  {
    key: 'local',
    header: 'Clínica',
    identity: true,
    sort: (m) => m.merchantName,
    csv: (m) => m.merchantName,
    cell: (m) => (
      <span className="block">
        <span className="flex items-center gap-2">
          <Link
            to="/admin/clinicas/$id"
            params={{ id: m.merchantId }}
            className={ENLACE_EN_CELDA}
          >
            {m.merchantName}
          </Link>
          {m.isTest && <Badge tone="neutral">Prueba</Badge>}
        </span>
        <span className="type-panel-caption text-on-surface-variant">
          {m.lineas} {m.lineas === 1 ? 'liquidación' : 'liquidaciones'}
        </span>
      </span>
    ),
  },
  {
    key: 'generado',
    header: 'Se generó',
    type: 'number',
    info: 'Liquidaciones con vencimiento en esa semana: la parte de la clínica (financiado sin fee) menos su comisión.',
    sort: (m) => m.generadoUsd,
    sortDir: 'desc',
    csv: (m) => csvDinero(m.generadoUsd),
    cell: (m) => formatUsd(m.generadoUsd),
  },
  {
    key: 'transferido',
    header: 'Transferido',
    type: 'number',
    sort: (m) => m.transferidoUsd,
    sortDir: 'desc',
    csv: (m) => csvDinero(m.transferidoUsd),
    cell: (m) => <span className="text-on-surface-variant">{formatUsd(m.transferidoUsd)}</span>,
  },
  {
    key: 'pendiente',
    header: 'Por transferir',
    type: 'number',
    sort: (m) => m.pendienteUsd,
    sortDir: 'desc',
    csv: (m) => csvDinero(m.pendienteUsd),
    cell: (m) =>
      m.pendienteUsd > SALDADO ? (
        <span className="font-semibold">{formatUsd(m.pendienteUsd)}</span>
      ) : (
        <span className="text-on-surface-variant">—</span>
      ),
  },
]
