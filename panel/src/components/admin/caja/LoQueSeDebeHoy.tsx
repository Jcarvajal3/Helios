import type { ReactNode } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { CircleAlert, Landmark } from 'lucide-react'

import { ArchivoDelBanco } from '@/components/admin/caja/ArchivoDelBanco'
import { AvisoDeLotePendiente, RegistrarPagoMasivo } from '@/components/admin/caja/RegistrarPagoMasivo'
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
  formatMoneda,
  formatUsd,
} from '@/components/ui'
import { fetchMerchantPayables } from '@/features/admin/api'
import type { MerchantPayable } from '@/features/admin/api'
import { comprometidoFuturoDe, payablesTotals } from '@/features/admin/definitions'
import { describeError } from '@/lib/supabase'

/**
 * Qué clínicas se ven: las que cobran hoy, las que tienen algo atrasado o
 * todas. Sin elegir, todas: con su próximo pago a la vista el equipo se
 * organiza antes de que toque (2026-10-22). Antes era «Cobran hoy», y un día
 * sin pagos dejaba la lista vacía.
 */
export type SoloLocales = 'atrasados' | 'este-cierre' | 'todos'

export const OPCIONES_SOLO: ReadonlyArray<{ value: SoloLocales; label: string }> = [
  { value: 'todos', label: 'Todas' },
  { value: 'este-cierre', label: 'Cobran hoy' },
  { value: 'atrasados', label: 'Con atraso' },
]

function futuroDe(m: MerchantPayable): number {
  return comprometidoFuturoDe(m)
}

/**
 * Lo que se le debe hoy a cada local, con las tres cifras que hay que
 * distinguir: lo que toca pagar hoy, lo atrasado de días anteriores y lo
 * comprometido a futuro. Mezclarlas era lo que hacía pagar de más.
 *
 * Se paga a diario: cada liquidación, el día siguiente a su vencimiento.
 *
 * Las cifras de arriba son puertas: pulsar «atrasado» deja solo los locales
 * con atraso. Los locales de prueba salen, con su etiqueta, y no suman.
 *
 * Cada fila es un médico titular (la clínica va debajo, en pequeño) con lo que
 * sale hoy y su próximo pago: el siguiente día con algo que transferirle, con
 * las mitades de la consulta y las comisiones de ese día sumadas.
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
        description="Cuando haya financiamientos, aquí aparece lo que hay que transferirle a cada clínica y qué día le toca."
      />
    )
  }

  // `payablesTotals` deja fuera los locales de prueba; lo suyo se dice aparte.
  const totals = payablesTotals(todos)
  const prueba = todos.filter((m) => m.isTest).reduce((sum, m) => sum + m.totalPendingUsd, 0)

  // Sin elegir: todas, con lo de hoy delante y luego el próximo pago más cercano.
  const vista: SoloLocales = solo ?? 'todos'

  const rows = todos
    .filter((m) =>
      vista === 'atrasados' ? m.overdueUsd > 0.005 : vista === 'este-cierre' ? m.nextRunUsd > 0.005 : true,
    )
    .sort(
      (a, b) =>
        b.nextRunUsd - a.nextRunUsd ||
        (a.proximoPago?.fecha ?? '9999').localeCompare(b.proximoPago?.fecha ?? '9999') ||
        (a.doctorName ?? a.merchantName).localeCompare(b.doctorName ?? b.merchantName, 'es'),
    )

  const resumen = (
    <>
      <Puerta activa={vista === 'este-cierre'} onClick={() => onSolo('este-cierre')}>
        {formatUsd(totals.saleEsteCierre - totals.atrasado)} que toca pagar hoy
      </Puerta>
      {' · '}
      <Puerta activa={vista === 'atrasados'} onClick={() => onSolo('atrasados')} alerta={totals.atrasado > 0}>
        {formatUsd(totals.atrasado)} atrasados de días anteriores
      </Puerta>
      {' · '}
      <Puerta activa={vista === 'todos'} onClick={() => onSolo('todos')}>
        {formatUsd(totals.comprometidoFuturo)} por pagar en los próximos días
      </Puerta>
      {prueba > 0 && ` · ${formatUsd(prueba)} en clínicas de prueba, aparte`}{' '}
      <InfoDot
        title="Lo que se debe hoy"
        what="Lo que se le transfiere a cada clínica: sus consultas enteras (sin la Comisión Helios, que paga el paciente) más las comisiones de su personal. Se paga a diario: cada liquidación, el día siguiente a su vencimiento (la consulta, a los 8 y a los 15 días; la comisión de la secretaria, junto con la primera mitad). El panel no mueve dinero: la transferencia se hace en el banco y aquí se registra."
      />
    </>
  )

  return (
    <>
      <AvisoDeLotePendiente />
      {rows.length === 0 ? (
        <EmptyState
          icon={<Landmark size={40} />}
          title={vista === 'atrasados' ? 'Ninguna clínica tiene pagos atrasados' : 'Ninguna clínica cobra hoy'}
          action={
            <Button size="md" variant="tonal" onClick={() => onSolo('todos')}>
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
          // El archivo del pago masivo del banco sustituye al CSV: es lo que
          // se carga para pagarles (2026-10-14). Cuando el banco lo procesa,
          // se registra de una vez.
          acciones={
            <>
              <ArchivoDelBanco />
              <RegistrarPagoMasivo />
            </>
          }
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

/** El médico titular, o la clínica si no tiene. */
function medicoDe(m: MerchantPayable): string {
  return m.doctorName ?? m.merchantName
}

/** «consultas $X + comisiones $Y», o nada si no hay comisiones que separar. */
function Partido({ consultasUsd, comisionesUsd }: { consultasUsd: number; comisionesUsd: number }) {
  if (comisionesUsd <= 0.005) return null
  return (
    <span className="block whitespace-nowrap type-panel-caption font-normal text-on-surface-variant">
      consultas {formatUsd(consultasUsd)} + comisiones {formatUsd(comisionesUsd)}
    </span>
  )
}

const COLUMNAS: Array<Column<MerchantPayable>> = [
  {
    // El médico es el dato principal; la clínica, debajo (2026-10-22).
    key: 'local',
    header: 'Médico',
    identity: true,
    sort: medicoDe,
    cell: (m) => (
      <span className="block">
        <span className="flex items-center gap-2">
          <Link
            to="/admin/clinicas/$id"
            params={{ id: m.merchantId }}
            className={ENLACE_EN_CELDA}
          >
            {medicoDe(m)}
          </Link>
          {m.isTest && <Badge tone="neutral">Prueba</Badge>}
        </span>
        <span className="type-panel-caption text-on-surface-variant">
          {medicoDe(m) !== m.merchantName ? `${m.merchantName} · ` : ''}
          {m.taxId ?? 'Sin RIF'}
        </span>
      </span>
    ),
  },
  {
    key: 'clinica',
    header: 'Clínica',
    hidden: true,
    sort: (m) => m.merchantName,
    cell: (m) => m.merchantName,
  },
  {
    key: 'rif',
    header: 'RIF',
    hidden: true,
    cell: (m) => m.taxId ?? '—',
  },
  {
    key: 'este-lunes',
    header: 'Sale hoy (con lo atrasado)',
    type: 'number',
    info: 'Lo que hay que transferirle hoy: lo que venció ayer más lo atrasado de días anteriores. Arriba, «que toca pagar hoy» no lleva lo atrasado. Son sus consultas (financiado sin comisión, menos su comisión) más las comisiones de su personal; debajo, partido.',
    sort: (m) => m.nextRunUsd,
    sortDir: 'desc',
    cell: (m) =>
      m.nextRunUsd > 0.005 ? (
        <>
          <span className="font-semibold">{formatUsd(m.nextRunUsd)}</span>
          {m.desglose && <Partido {...m.desglose} />}
          {(m.nextRunEur ?? 0) > 0.005 && (
            <span className="block whitespace-nowrap type-panel-caption font-normal text-on-surface-variant">
              de eso, {formatMoneda(m.nextRunEur ?? 0, 'EUR')} a la tasa del euro
            </span>
          )}
        </>
      ) : (
        <span className="text-on-surface-variant">—</span>
      ),
  },
  {
    // Javier (2026-10-26): a qué tasa se le paga a cada médico. Lo de una
    // orden en euros va a la del euro; lo demás, a la del dólar.
    key: 'tasa',
    header: 'Tasa de pago',
    info: 'A qué tasa BCV se le pasa a bolívares lo que se le debe: la del euro para lo que viene de órdenes en euros (el paciente también pagó esas cuotas a la tasa del euro), la del dólar para lo demás. Si tiene de las dos, cada parte va a la suya. En su página, cada liquidación dice a qué tasa pagó el paciente.',
    sort: (m) => (m.monedas ?? []).join(','),
    csv: (m) => (m.monedas ?? []).map((x) => (x === 'EUR' ? 'Euro' : 'Dólar')).join(' y ') || null,
    cell: (m) =>
      m.monedas && m.monedas.length > 0 ? (
        <span className="flex flex-wrap gap-1">
          {m.monedas.map((x) => (
            <Badge key={x} tone={x === 'EUR' ? 'brand' : 'neutral'}>
              {x === 'EUR' ? 'Euro' : 'Dólar'}
            </Badge>
          ))}
        </span>
      ) : (
        <span className="text-on-surface-variant">—</span>
      ),
  },
  {
    key: 'proximo',
    header: 'Próximo pago',
    type: 'number',
    info: 'El siguiente día, después de hoy, con algo que transferirle: las mitades de la consulta que vencen (aunque todavía no sean liquidaciones) y las comisiones de su personal de ese día, sumadas. Para tenerlo listo antes de que toque.',
    sort: (m) => m.proximoPago?.fecha ?? null,
    cell: (m) =>
      m.proximoPago ? (
        <>
          <span className="font-semibold">{formatUsd(m.proximoPago.usd)}</span>
          <span className="block whitespace-nowrap type-panel-caption font-normal text-on-surface-variant">
            el {formatDay(m.proximoPago.fecha)}
          </span>
          <Partido {...m.proximoPago} />
        </>
      ) : (
        <span className="text-on-surface-variant">—</span>
      ),
  },
  {
    key: 'proximo-fecha',
    header: 'Próximo pago: día',
    hidden: true,
    sort: (m) => m.proximoPago?.fecha ?? null,
    cell: (m) => (m.proximoPago ? formatDay(m.proximoPago.fecha) : '—'),
  },
  {
    key: 'consultas',
    header: 'Hoy: consultas',
    type: 'number',
    hidden: true,
    sort: (m) => m.desglose?.consultasUsd ?? null,
    cell: (m) => (m.desglose ? formatUsd(m.desglose.consultasUsd) : '—'),
  },
  {
    key: 'comisiones',
    header: 'Hoy: comisiones del personal',
    type: 'number',
    hidden: true,
    sort: (m) => m.desglose?.comisionesUsd ?? null,
    cell: (m) => (m.desglose ? formatUsd(m.desglose.comisionesUsd) : '—'),
  },
  {
    key: 'atrasado',
    header: 'De eso, atrasado',
    type: 'number',
    info: 'Lo que tocaba pagar ayer o antes y sigue sin transferirse. Ya va dentro de «Sale hoy».',
    sort: (m) => m.overdueUsd,
    sortDir: 'desc',
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
    header: 'Por pagar en los próximos días',
    type: 'number',
    info: 'Lo que se le deberá después del pago de hoy: lo que vence hoy (sale mañana) y, sobre todo, cuotas de sus pacientes que todavía no vencen y aún no son liquidaciones. Hoy no toca pagarlo.',
    sort: futuroDe,
    sortDir: 'desc',
    cell: (m) => <span className="text-on-surface-variant">{formatUsd(futuroDe(m))}</span>,
  },
  {
    key: 'total',
    header: 'Total por pagar',
    type: 'number',
    info: '«Sale hoy» más «Por pagar en los próximos días».',
    hidden: true,
    sort: (m) => m.totalPendingUsd,
    cell: (m) => formatUsd(m.totalPendingUsd),
  },
  {
    // La primera pregunta del gerente que llama es «¿cuándo me pagaron?».
    key: 'ultima',
    header: 'Última transferencia',
    sort: (m) => m.lastPayoutOn,
    sortDir: 'desc',
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
