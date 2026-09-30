import { useState } from 'react'
import { createFileRoute } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Landmark, Lock } from 'lucide-react'

import {
  EmptyState,
  ErrorBox,
  SectionTitle,
  SkeletonList,
  SkeletonStats,
  Stat,
  StatGrid,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatDay,
  formatUsd,
} from '@/components/ui'
import { canSee } from '@/features/auth/permissions'
import { useStaff } from '@/features/auth/session'
import type { StaffContext } from '@/features/auth/session'
import {
  PAYOUT_METHOD_LABEL,
  SETTLEMENT_REASON_LABEL,
  fetchPayoutDetail,
  fetchPayouts,
  fetchSettlementOutlook,
} from '@/features/merchant/settlements'
import type {
  PendingSettlement,
  SettlementReason,
} from '@/features/merchant/settlements'
import { describeError } from '@/lib/supabase'

export const Route = createFileRoute('/_comercio/pagos')({
  // `wide`: la tabla de transferencias son cinco columnas y una de ellas es
  // una referencia bancaria, que no se puede recortar sin dejar de servir
  // para cotejarla contra el banco.
  staticData: { title: 'Pagos', width: 'wide' },
  component: LiquidacionesRoute,
})

function LiquidacionesRoute() {
  const staff = useStaff()

  if (!staff) return null

  if (!canSee(staff.role, 'pagos')) {
    return (
      <EmptyState
        icon={<Lock size={48} />}
        title="Esto lo ve el administrador"
        description="Lo que Helios le transfiere a la clínica es información del dueño."
      />
    )
  }

  return <Liquidaciones staff={staff} />
}

function Liquidaciones({ staff }: { staff: StaffContext }) {
  const outlook = useQuery({
    queryKey: ['settlement-outlook', staff.merchantId],
    queryFn: fetchSettlementOutlook,
  })

  const payouts = useQuery({
    queryKey: ['payouts', staff.merchantId],
    queryFn: () => fetchPayouts(staff.merchantId),
  })

  const error = outlook.error ?? payouts.error
  const receivedUsd = (payouts.data ?? []).reduce((sum, p) => sum + p.amountUsd, 0)

  // El lunes del cierre, "el lunes" es hoy: el día operativo cambia a las 10 AM,
  // que es la misma hora a la que Ronda cierra la caja.
  const runIsToday = outlook.data?.nextRunDate === outlook.data?.todayDate

  return (
    <>
      {error && (
        <div className="mb-6">
          <ErrorBox
            title="No pudimos cargar tus pagos"
            detail={describeError(error)}
          />
        </div>
      )}

      {/* Tres cifras y una tabla. Las dos primeras responden a las dos únicas
          preguntas que trae el dueño desde el 2026-09-02, cuando el pago pasó a
          ser semanal: **cuánto me entra el lunes** y **cuánto me falta en
          total**. Van separadas porque son cosas distintas — la primera es
          dinero con fecha y la segunda incluye la cuota 2, que todavía no ha
          vencido— y juntarlas en un "pendiente" a secas fue lo que hizo falta
          desmontar. */}
      {outlook.isLoading && <SkeletonStats count={3} />}

      {outlook.data && (
        <StatGrid>
          <Stat
            label={runIsToday ? 'Te llega hoy' : 'Te llega el lunes'}
            value={formatUsd(outlook.data.nextRunUsd)}
            tone="success"
            hint={`Cierre del ${formatDay(outlook.data.nextRunDate)} a las 10:00`}
          />
          <Stat
            label="Total por cobrar"
            value={formatUsd(outlook.data.totalPendingUsd)}
            hint={
              outlook.data.upcomingUsd > 0
                ? `${formatUsd(outlook.data.upcomingUsd)} en cuotas que aún no vencen`
                : 'Todo vencido y a la espera del cierre'
            }
          />
          <Stat
            label="Recibido hasta hoy"
            value={formatUsd(receivedUsd)}
            hint={`${payouts.data?.length ?? 0} ${payouts.data?.length === 1 ? 'pago' : 'pagos'}`}
          />
        </StatGrid>
      )}

      <p className="mt-6 max-w-3xl type-body-medium leading-6 text-on-surface-variant">
        Helios cierra caja <strong>todos los lunes a las 10:00</strong> y ese
        mismo día te transfiere las cuotas que vencieron durante la semana,{' '}
        <strong>haya pagado o no tu paciente</strong>: cobrarle es problema de
        Helios, no tuyo. Cada financiamiento se te paga en dos mitades, una por cuota, así
        que la segunda entra en un cierre posterior.
      </p>

      {/* ── Historial ───────────────────────────────────────────────────── */}

      <div className="mt-8">
        <SectionTitle>Transferencias recibidas</SectionTitle>

        {payouts.data?.length === 0 ? (
          <div className="mt-3">
            <EmptyState
              icon={<Landmark size={48} />}
              title="Todavía no te hemos transferido nada"
              description="Cuando Helios te pague, aquí verás cada transferencia con su referencia y qué liquidaciones cubrió."
            />
          </div>
        ) : (
          <Table
            headers={['Fecha', 'Método', 'Referencia', 'Liquidaciones', 'Monto']}
            className="mt-3"
          >
            {payouts.data?.map((p) => (
              <PayoutRows key={p.id} payout={p} />
            ))}
          </Table>
        )}
      </div>
    </>
  )
}

/**
 * Lo que cubrió una transferencia, junto por la venta que lo originó.
 *
 * El detalle dice de qué se compone el día — "12 adelantos al vender" — porque
 * el motivo cambia lo que significa: un adelanto ya está devengado por una
 * venta hecha, y una cuota por fecha se debe aunque el cliente todavía no haya
 * pagado.
 */
function groupByBusinessDate(
  settlements: PendingSettlement[],
): Array<{ businessDate: string; amountUsd: number; detail: string }> {
  const byDate = new Map<string, PendingSettlement[]>()

  for (const s of settlements) {
    const list = byDate.get(s.businessDate)
    if (list) list.push(s)
    else byDate.set(s.businessDate, [s])
  }

  return [...byDate.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([businessDate, list]) => ({
      businessDate,
      amountUsd: list.reduce((sum, s) => sum + s.amountUsd, 0),
      detail: describeReasons(list),
    }))
}

function describeReasons(settlements: PendingSettlement[]): string {
  const counts = new Map<SettlementReason, number>()
  for (const s of settlements) {
    counts.set(s.reason, (counts.get(s.reason) ?? 0) + 1)
  }

  return [...counts.entries()]
    .map(([reason, n]) => `${n} × ${SETTLEMENT_REASON_LABEL[reason].toLowerCase()}`)
    .join(' · ')
}

function PayoutRows({
  payout,
}: {
  payout: {
    id: string
    amountUsd: number
    method: string
    reference: string | null
    note: string | null
    createdAt: string
    itemCount: number
  }
}) {
  const [open, setOpen] = useState(false)

  const detail = useQuery({
    queryKey: ['payout-detail', payout.id],
    queryFn: () => fetchPayoutDetail(payout.id),
    enabled: open,
  })

  return (
    <>
      <Tr onClick={() => setOpen(!open)}>
        <Td className="whitespace-nowrap">{formatDateTime(payout.createdAt)}</Td>
        <Td className="font-semibold">
          {PAYOUT_METHOD_LABEL[payout.method] ?? payout.method}
        </Td>
        <Td className="text-on-surface-variant">{payout.reference ?? '—'}</Td>
        <Td>
          {payout.itemCount} {payout.itemCount === 1 ? 'liquidación' : 'pagos'}
        </Td>
        <Td className="font-semibold tabular-nums text-primary">
          {formatUsd(payout.amountUsd)}
        </Td>
      </Tr>

      {open && (
        <tr>
          <Td colSpan={5} className="border-b border-outline-variant/50 bg-shell-control/50 px-6 pb-4 pt-2">
            {detail.isLoading && <SkeletonList rows={3} />}

            {/* Agrupado por la venta que lo originó, no fila a fila: una
                transferencia normal cubre varias decenas de liquidaciones. */}
            {detail.data &&
              groupByBusinessDate(detail.data).map((group) => (
                <div
                  key={group.businessDate}
                  className="flex items-center justify-between gap-4 py-2 type-body-medium"
                >
                  <span className="text-on-surface-variant">
                    Financiamientos del {formatDay(group.businessDate)} · {group.detail}
                  </span>
                  <span className="tabular-nums">{formatUsd(group.amountUsd)}</span>
                </div>
              ))}
            {payout.note && (
              <p className="mt-2 type-label-medium text-on-surface-variant">Nota: {payout.note}</p>
            )}
          </Td>
        </tr>
      )}
    </>
  )
}
