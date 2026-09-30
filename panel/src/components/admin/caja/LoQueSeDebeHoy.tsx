import type { ReactNode } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { CircleAlert, Landmark } from 'lucide-react'

import { DataTable, ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import {
  Badge,
  Button,
  EmptyState,
  ErrorBox,
  InfoDot,
  SkeletonTable,
  formatDay,
  formatUsd,
  hoyCaracas,
} from '@/components/ui'
import { fetchMerchantPayables } from '@/features/admin/api'
import type { MerchantPayable } from '@/features/admin/api'
import { comprometidoFuturoDe, payablesTotals } from '@/features/admin/definitions'
import { csvDinero } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

/** Qué locales se ven: todos, los que tienen algo atrasado o los que cobran este lunes. */
export type SoloLocales = 'atrasados' | 'este-cierre'

export const OPCIONES_SOLO: ReadonlyArray<{ value: SoloLocales | ''; label: string }> = [
  { value: '', label: 'Todos' },
  { value: 'atrasados', label: 'Con atraso' },
  { value: 'este-cierre', label: 'Cobran este lunes' },
]

function futuroDe(m: MerchantPayable): number {
  return comprometidoFuturoDe(m)
}

/**
 * Lo que se le debe hoy a cada local, con las tres cifras que hay que
 * distinguir: lo de este lunes, lo atrasado de cierres anteriores y lo
 * comprometido a futuro. Mezclarlas era lo que hacía pagar de más.
 *
 * Las cifras de arriba son puertas: pulsar «atrasado» deja solo los locales
 * con atraso. Los locales de prueba salen, con su etiqueta, y no suman.
 */
export function LoQueSeDebeHoy({
  solo,
  onSolo,
}: {
  solo: SoloLocales | undefined
  onSolo: (solo: SoloLocales | undefined) => void
}) {
  const navigate = useNavigate()

  const payables = useQuery({
    queryKey: ['merchant-payables'],
    queryFn: fetchMerchantPayables,
    refetchInterval: 60_000,
  })

  if (payables.isPending) return <SkeletonTable rows={5} columns={5} />

  if (payables.isError) {
    return (
      <ErrorBox title="No se pudo cargar lo que se debe" detail={describeError(payables.error)} />
    )
  }

  const todos = payables.data

  if (todos.length === 0) {
    return (
      <EmptyState
        icon={<Landmark size={40} />}
        title="No se le debe nada a ninguna clínica"
        description="Cuando haya financiamientos, aquí aparece lo que hay que transferirle a cada uno y en qué cierre le toca."
      />
    )
  }

  // `payablesTotals` deja fuera los locales de prueba; lo suyo se dice aparte.
  const totals = payablesTotals(todos)
  const prueba = todos.filter((m) => m.isTest).reduce((sum, m) => sum + m.totalPendingUsd, 0)

  const rows = todos.filter((m) =>
    solo === 'atrasados' ? m.overdueUsd > 0.005 : solo === 'este-cierre' ? m.nextRunUsd > 0.005 : true,
  )

  const resumen = (
    <>
      <Puerta activa={solo === 'este-cierre'} onClick={() => onSolo('este-cierre')}>
        {formatUsd(totals.saleEsteCierre - totals.atrasado)} de la semana que cierra el{' '}
        {totals.fechaCierre ? formatDay(totals.fechaCierre) : 'próximo lunes'}
      </Puerta>
      {' · '}
      <Puerta activa={solo === 'atrasados'} onClick={() => onSolo('atrasados')} alerta={totals.atrasado > 0}>
        {formatUsd(totals.atrasado)} atrasados de cierres anteriores
      </Puerta>
      {' · '}
      {formatUsd(totals.comprometidoFuturo)} por vencer en cierres posteriores
      {prueba > 0 && ` · ${formatUsd(prueba)} en clínicas de prueba, aparte`}{' '}
      <InfoDot
        title="Lo que se debe hoy"
        what="Lo que se le transfiere a cada clínica: el financiado (sin fee) de sus pacientes menos la comisión de la clínica. El cierre es cada lunes a las 10:00; el panel no mueve dinero: la transferencia se hace en el banco y aquí se registra."
      />
    </>
  )

  return (
    <>
      {rows.length === 0 ? (
        <EmptyState
          icon={<Landmark size={40} />}
          title={solo === 'atrasados' ? 'Ninguna clínica tiene pagos atrasados' : 'Ninguna clínica cobra este lunes'}
          action={
            <Button size="md" variant="tonal" onClick={() => onSolo(undefined)}>
              Ver todas las clínicas
            </Button>
          }
        />
      ) : (
        <DataTable
          rows={rows}
          rowKey={(m) => m.merchantId}
          columns={COLUMNAS}
          noun={['clínica', 'clínicas']}
          summary={resumen}
          exportar={{ archivo: `por-pagar-a-locales-${hoyCaracas()}` }}
          rowTone={(m) => (m.overdueUsd > 0.005 && !m.isTest ? 'error' : undefined)}
          onRowClick={(m) =>
            void navigate({ to: '/admin/pagos-clinicas/$id', params: { id: m.merchantId }, search: {} })
          }
        />
      )}
    </>
  )
}

/** Una cifra del resumen que filtra la lista. */
function Puerta({
  activa,
  alerta = false,
  onClick,
  children,
}: {
  activa: boolean
  alerta?: boolean
  onClick: () => void
  children: ReactNode
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={activa}
      className={`inline-flex items-center gap-1 text-on-surface underline decoration-panel-muted underline-offset-2 transition-colors hover:decoration-on-surface ${
        activa ? 'font-semibold' : ''
      }`}
    >
      {/* Lo atrasado es un estado: va con su icono, no solo con color. */}
      {alerta && <CircleAlert size={13} aria-label="Atrasado" className="shrink-0 text-error" />}
      {children}
    </button>
  )
}

const COLUMNAS: Array<Column<MerchantPayable>> = [
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
        <span className="type-panel-caption text-on-surface-variant">{m.taxId ?? 'Sin RIF'}</span>
      </span>
    ),
  },
  {
    key: 'rif',
    header: 'RIF',
    hidden: true,
    csv: (m) => m.taxId,
    cell: (m) => m.taxId ?? '—',
  },
  {
    key: 'este-lunes',
    header: 'Sale este lunes (con lo atrasado)',
    type: 'number',
    info: 'Lo que hay que transferirle en el próximo cierre: lo de la semana más lo atrasado de cierres anteriores. Arriba, «de la semana que cierra» no lleva lo atrasado. Son sus consultas (financiado sin fee, menos su comisión) más las comisiones de su personal; debajo, partido.',
    sort: (m) => m.nextRunUsd,
    sortDir: 'desc',
    csv: (m) => csvDinero(m.nextRunUsd),
    cell: (m) => (
      <>
        <span className="font-semibold">{formatUsd(m.nextRunUsd)}</span>
        {m.desglose && m.desglose.comisionesUsd > 0 && (
          <span className="block whitespace-nowrap type-panel-caption font-normal text-on-surface-variant">
            consultas {formatUsd(m.desglose.consultasUsd)} + comisiones {formatUsd(m.desglose.comisionesUsd)}
          </span>
        )}
      </>
    ),
  },
  {
    key: 'consultas',
    header: 'Este lunes: consultas',
    type: 'number',
    hidden: true,
    sort: (m) => m.desglose?.consultasUsd ?? null,
    csv: (m) => (m.desglose ? csvDinero(m.desglose.consultasUsd) : null),
    cell: (m) => (m.desglose ? formatUsd(m.desglose.consultasUsd) : '—'),
  },
  {
    key: 'comisiones',
    header: 'Este lunes: comisiones del personal',
    type: 'number',
    hidden: true,
    sort: (m) => m.desglose?.comisionesUsd ?? null,
    csv: (m) => (m.desglose ? csvDinero(m.desglose.comisionesUsd) : null),
    cell: (m) => (m.desglose ? formatUsd(m.desglose.comisionesUsd) : '—'),
  },
  {
    key: 'atrasado',
    header: 'De eso, atrasado',
    type: 'number',
    info: 'Lo de cierres que ya pasaron y sigue sin transferirse. Ya va dentro de «Sale este lunes».',
    sort: (m) => m.overdueUsd,
    sortDir: 'desc',
    csv: (m) => csvDinero(m.overdueUsd),
    cell: (m) =>
      m.overdueUsd > 0 ? (
        <span className="font-semibold">
          {formatUsd(m.overdueUsd)}
          {m.oldestDueDate && (
            <span className="block type-panel-caption font-normal text-on-surface-variant">
              desde el {formatDay(m.oldestDueDate)}
            </span>
          )}
        </span>
      ) : (
        <span className="text-on-surface-variant">—</span>
      ),
  },
  {
    key: 'futuro',
    header: 'Por vencer en cierres posteriores',
    type: 'number',
    info: 'Lo que se le deberá después del próximo cierre, sobre todo por cuotas de sus pacientes que todavía no vencen y aún no son liquidaciones. No toca pagarlo.',
    sort: futuroDe,
    sortDir: 'desc',
    csv: (m) => csvDinero(futuroDe(m)),
    cell: (m) => <span className="text-on-surface-variant">{formatUsd(futuroDe(m))}</span>,
  },
  {
    key: 'total',
    header: 'Total por pagar',
    type: 'number',
    info: '«Sale este lunes» más «Por vencer en cierres posteriores».',
    hidden: true,
    sort: (m) => m.totalPendingUsd,
    csv: (m) => csvDinero(m.totalPendingUsd),
    cell: (m) => formatUsd(m.totalPendingUsd),
  },
  {
    // La primera pregunta del gerente que llama es «¿cuándo me pagaron?».
    key: 'ultima',
    header: 'Última transferencia',
    sort: (m) => m.lastPayoutOn,
    sortDir: 'desc',
    csv: (m) => m.lastPayoutOn,
    cell: (m) =>
      m.lastPayoutOn ? (
        <span className="block whitespace-nowrap text-on-surface-variant">
          {formatDay(m.lastPayoutOn)}
          {m.lastPayoutUsd !== null && (
            <span className="block type-panel-caption tabular-nums">{formatUsd(m.lastPayoutUsd)}</span>
          )}
        </span>
      ) : (
        <span className="text-on-surface-variant">Nunca</span>
      ),
  },
]
