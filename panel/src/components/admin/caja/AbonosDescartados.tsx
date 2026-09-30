import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Archive, Link2 } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import {
  Button,
  EmptyState,
  ErrorBox,
  SkeletonList,
  formatDateTime,
  formatDay,
  formatUsd,
  formatVes,
  hoyCaracas,
} from '@/components/ui'
import { LigarDesdeElAbono } from '@/components/admin/caja/LigarMovimiento'
import { fetchDiscardedDeposits } from '@/features/admin/deposits'
import type { DiscardedDeposit } from '@/features/admin/deposits'
import { csvDinero, csvInstante } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

const LIMITE = 200

/**
 * Los abonos que alguien sacó de la lista porque no eran de un usuario.
 *
 * Descartar no escribe asiento. Si un motivo resulta estar mal (era el pago de
 * alguien, no un depósito propio), aquí se ve qué se descartó, quién y por qué,
 * y el que era de un pago ya aprobado se recupera ligándolo a él.
 */
export function AbonosDescartados() {
  const query = useQuery({
    queryKey: ['discarded-deposits', LIMITE],
    queryFn: () => fetchDiscardedDeposits(LIMITE),
  })
  const [ligando, setLigando] = useState<DiscardedDeposit | null>(null)

  if (query.isPending) return <SkeletonList rows={4} />

  if (query.isError) {
    return (
      <ErrorBox
        title="No se pudieron cargar los abonos descartados"
        detail={describeError(query.error)}
      />
    )
  }

  if (query.data.length === 0) {
    return (
      <EmptyState
        icon={<Archive size={40} />}
        title="No se ha descartado ningún abono"
        description="Un abono que no es de un paciente se descarta con su motivo y aparece aquí."
      />
    )
  }

  return (
    <>
      <DataTable
        rows={query.data}
        rowKey={(d) => d.id}
        columns={[...COLUMNAS, columnaLigar(setLigando)]}
        noun={['abono descartado', 'abonos descartados']}
        limit={LIMITE}
        exportar={{ archivo: `abonos-descartados-${hoyCaracas()}` }}
      />

      {ligando && (
        <LigarDesdeElAbono abono={{ ...ligando, descartado: true }} onClose={() => setLigando(null)} />
      )}
    </>
  )
}

function columnaLigar(onLigar: (d: DiscardedDeposit) => void): Column<DiscardedDeposit> {
  return {
    key: 'acciones',
    header: '',
    cell: (d) => (
      <Button size="sm" variant="tonal" onClick={() => onLigar(d)}>
        <Link2 size={14} aria-hidden /> Es de un pago aprobado
      </Button>
    ),
  }
}

const COLUMNAS: Array<Column<DiscardedDeposit>> = [
  {
    key: 'fecha',
    header: 'Fecha',
    identity: true,
    sort: (d) => d.movedOn,
    sortDir: 'desc',
    csv: (d) => d.movedOn,
    cell: (d) => <span className="whitespace-nowrap">{formatDay(d.movedOn)}</span>,
  },
  {
    key: 'referencia',
    header: 'Referencia',
    sort: (d) => d.reference,
    csv: (d) => d.reference,
    cell: (d) => (
      <span className="block">
        <span className="font-mono type-panel-caption">{d.reference}</span>
        <span className="block type-panel-caption text-on-surface-variant">{d.bank}</span>
      </span>
    ),
  },
  {
    key: 'monto',
    header: 'Monto',
    type: 'number',
    sort: (d) => d.amountUsd,
    sortDir: 'desc',
    csv: (d) => (d.amountUsd === null ? null : csvDinero(d.amountUsd)),
    cell: (d) =>
      d.amountUsd === null ? (
        <span className="text-on-surface-variant">{formatVes(d.amountVes)}</span>
      ) : (
        <>
          <span className="font-semibold">{formatUsd(d.amountUsd)}</span>
          <span className="mt-0.5 block type-panel-caption font-normal text-on-surface-variant">
            {formatVes(d.amountVes)}
          </span>
        </>
      ),
  },
  {
    key: 'monto-ves',
    header: 'Monto en bolívares',
    type: 'number',
    hidden: true,
    csv: (d) => csvDinero(d.amountVes),
    cell: (d) => formatVes(d.amountVes),
  },
  {
    key: 'motivo',
    header: 'Motivo',
    csv: (d) => d.reason,
    cell: (d) => <span className="block max-w-xs text-on-surface">{d.reason}</span>,
  },
  {
    key: 'descartado',
    header: 'Descartado',
    sort: (d) => d.discardedAt,
    sortDir: 'desc',
    csv: (d) => `${csvInstante(d.discardedAt)} ${d.discardedByName}`,
    cell: (d) => (
      <span className="block whitespace-nowrap text-on-surface-variant">
        {d.discardedByName}
        <span className="block type-panel-caption">{formatDateTime(d.discardedAt)}</span>
      </span>
    ),
  },
  {
    key: 'descripcion',
    header: 'Descripción',
    hidden: true,
    csv: (d) => d.description,
    cell: (d) => (
      <span className="block max-w-64 type-panel-caption text-on-surface-variant">
        {d.description ?? '—'}
      </span>
    ),
  },
]
