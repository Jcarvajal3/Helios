import { useState } from 'react'
import { Link, createFileRoute } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { ChevronRight, Landmark, Lock } from 'lucide-react'

import {
  Card,
  DataLabel,
  EmptyState,
  ErrorBox,
  NoSePudoLeer,
  SectionTitle,
  SkeletonList,
  SkeletonTable,
  Stat,
  StatGrid,
  Table,
  Td,
  Tr,
  estadoDeConsulta,
  estadoDeConsultas,
  formatDateTime,
  formatDay,
  formatUsd,
} from '@/components/ui'
import { canSee } from '@/features/auth/permissions'
import { useStaff } from '@/features/auth/session'
import type { StaffContext } from '@/features/auth/session'
import { CONCEPTO, MEDIO_DE_PAGO, agruparLineas, repartir } from '@/features/merchant/pagos'
import type { Reparto, Transferencia } from '@/features/merchant/pagos'
import { diaDeLaSemana } from '@/features/merchant/registro'
import {
  fetchLineasDeTransferencia,
  fetchPorTransferir,
  fetchPrevision,
  fetchTransferencias,
} from '@/features/merchant/settlements'
import { describeError } from '@/lib/supabase'

export const Route = createFileRoute('/_comercio/pagos')({
  // `wide`: la tabla de transferencias lleva la referencia bancaria, que no
  // se puede recortar sin dejar de servir para cotejarla contra el banco.
  staticData: { title: 'Pagos', width: 'wide' },
  component: PagosRoute,
})

function PagosRoute() {
  const staff = useStaff()
  if (!staff) return null

  // Sin este corte, una secretaria vería CERO y no un error: la RLS de
  // `settlements` le devuelve lista vacía. Es el fallo que parece respuesta.
  if (!canSee(staff.role, 'pagos')) {
    return (
      <EmptyState
        icon={<Lock size={48} />}
        title="Esto lo ve el administrador"
        description="Lo que Helios le transfiere a la clínica es información del administrador. Tus comisiones están en Comisiones."
        action={
          <Link to="/comisiones" className="type-panel-control underline underline-offset-2">
            Ir a Comisiones
          </Link>
        }
      />
    )
  }

  return <Pagos staff={staff} />
}

/**
 * PAGOS: lo que Helios le paga a la clínica (el `/liquidaciones` de Ronda).
 *
 * Helios cierra caja los lunes a las 10:00 y ese día transfiere, en UNA
 * transferencia, dos cosas distintas que aquí se enseñan siempre partidas:
 *
 *   · Consultas: la mitad de cada financiamiento al vencer cada cuota del
 *     paciente, haya pagado o no.
 *   · Comisiones del personal: la de quien registró cada financiamiento, en
 *     el lunes siguiente a la semana del alta. La clínica se las entrega.
 */
function Pagos({ staff }: { staff: StaffContext }) {
  const prevision = useQuery({
    queryKey: ['settlement-outlook', staff.merchantId],
    queryFn: fetchPrevision,
  })

  const porTransferir = useQuery({
    queryKey: ['settlements-pending', staff.merchantId],
    queryFn: () => fetchPorTransferir(staff.merchantId),
  })

  const transferencias = useQuery({
    queryKey: ['payouts', staff.merchantId],
    queryFn: () => fetchTransferencias(staff.merchantId),
  })

  const p = prevision.data
  const esHoy = p !== undefined && p.nextRunDate === p.todayDate
  const recibido = (transferencias.data ?? []).reduce((s, t) => s + t.amountUsd, 0)
  const devengado: Reparto | null = porTransferir.data ? repartir(porTransferir.data) : null

  return (
    <>
      <StatGrid>
        <Stat
          label={esHoy ? 'Te llega hoy' : 'Te llega el lunes'}
          value={formatUsd(p?.nextRunUsd ?? 0)}
          hint={
            p
              ? p.nextRun
                ? `${CONCEPTO.consultas} ${formatUsd(p.nextRun.consultasUsd)} · comisiones ${formatUsd(p.nextRun.comisionesUsd)}`
                : `Cierre del ${diaDeLaSemana(p.nextRunDate)} ${formatDay(p.nextRunDate)} a las 10:00`
              : undefined
          }
          estado={estadoDeConsulta(prevision)}
          onReintentar={() => void prevision.refetch()}
        />
        <Stat
          label="Total por cobrar"
          value={formatUsd(p?.totalPendingUsd ?? 0)}
          hint={
            p && p.upcomingUsd > 0
              ? `${formatUsd(p.upcomingUsd)} en cuotas que aún no vencen`
              : 'Todo vencido y a la espera del cierre'
          }
          estado={estadoDeConsulta(prevision)}
          onReintentar={() => void prevision.refetch()}
        />
        <Stat
          label="Recibido hasta hoy"
          value={formatUsd(recibido)}
          hint={
            transferencias.data
              ? `${transferencias.data.length} ${transferencias.data.length === 1 ? 'transferencia' : 'transferencias'}`
              : undefined
          }
          estado={estadoDeConsultas([transferencias])}
          onReintentar={() => void transferencias.refetch()}
        />
      </StatGrid>

      {/* Lo devengado y sin transferir, partido. Son filas reales de
          `settlements`: se suman, no se estima nada. */}
      <Card className="mt-4 flex flex-col gap-3">
        <DataLabel>Devengado y sin transferir todavía</DataLabel>
        {porTransferir.isPending && <SkeletonList rows={2} />}
        {porTransferir.isError && (
          <NoSePudoLeer onReintentar={() => void porTransferir.refetch()} />
        )}
        {devengado && (
          <dl className="grid gap-3 sm:grid-cols-2">
            <div className="rounded-panel-card bg-panel-raised px-4 py-3">
              <dt className="type-panel-caption text-panel-muted">{CONCEPTO.consultas}</dt>
              <dd className="type-panel-section tabular-nums text-on-surface">
                {formatUsd(devengado.consultasUsd)}
              </dd>
            </div>
            <div className="rounded-panel-card bg-panel-raised px-4 py-3">
              <dt className="type-panel-caption text-panel-muted">
                {CONCEPTO.comisiones} ·{' '}
                <Link to="/comisiones" className="underline underline-offset-2 hover:text-on-surface">
                  ver por persona
                </Link>
              </dt>
              <dd className="type-panel-section tabular-nums text-on-surface">
                {formatUsd(devengado.comisionesUsd)}
              </dd>
            </div>
          </dl>
        )}
      </Card>

      <p className="mt-6 max-w-3xl type-panel-body leading-6 text-on-surface-variant">
        Helios cierra caja <strong>todos los lunes a las 10:00</strong> y ese mismo día te
        transfiere las cuotas que vencieron durante la semana,{' '}
        <strong>haya pagado o no tu paciente</strong>: cobrarle es cosa de Helios. Cada
        financiamiento se te paga en dos mitades, una por cuota. En la misma transferencia van
        las <strong>comisiones de tu personal</strong> de la semana anterior, para que se las
        entregues.
      </p>

      {/* ── Historial ─────────────────────────────────────────────────── */}
      <div className="mt-8">
        <SectionTitle>Transferencias recibidas</SectionTitle>

        {transferencias.isLoading && (
          <div className="mt-3">
            <SkeletonTable rows={4} columns={6} />
          </div>
        )}

        {transferencias.isError && (
          <div className="mt-3">
            <ErrorBox
              title="No pudimos cargar las transferencias"
              detail={describeError(transferencias.error)}
            />
          </div>
        )}

        {transferencias.data?.length === 0 && (
          <div className="mt-3">
            <EmptyState
              icon={<Landmark size={48} />}
              title="Todavía no te hemos transferido nada"
              description="Cuando Helios te pague, aquí verás cada transferencia con su referencia, partida en consultas y comisiones del personal."
            />
          </div>
        )}

        {transferencias.data && transferencias.data.length > 0 && (
          <>
            <Table
              headers={[
                'Fecha',
                'Método',
                'Referencia',
                CONCEPTO.consultas,
                CONCEPTO.comisiones,
                'Monto',
              ]}
              className="mt-3"
            >
              {transferencias.data.map((t) => (
                <FilaDeTransferencia key={t.id} t={t} />
              ))}
            </Table>
            <p className="mt-3 type-panel-caption text-panel-muted">
              Pulsa una transferencia para ver qué cubrió.
            </p>
          </>
        )}
      </div>
    </>
  )
}

/** Una transferencia, y al pulsarla lo que cubrió. */
function FilaDeTransferencia({ t }: { t: Transferencia }) {
  const [abierta, setAbierta] = useState(false)

  const lineas = useQuery({
    queryKey: ['payout-detail', t.id],
    queryFn: () => fetchLineasDeTransferencia(t.id),
    enabled: abierta,
  })

  return (
    <>
      <Tr onClick={() => setAbierta(!abierta)}>
        <Td className="whitespace-nowrap">
          <ChevronRight
            size={14}
            aria-hidden
            className={`mr-1 inline align-[-2px] text-panel-muted transition-transform ${abierta ? 'rotate-90' : ''}`}
          />
          {formatDateTime(t.createdAt)}
        </Td>
        <Td className="font-semibold">{MEDIO_DE_PAGO[t.method] ?? t.method}</Td>
        <Td className="text-on-surface-variant">{t.reference ?? '—'}</Td>
        <Td className="tabular-nums">
          {t.reparto ? formatUsd(t.reparto.consultasUsd) : <span className="text-on-surface-variant">—</span>}
        </Td>
        <Td className="tabular-nums">
          {t.reparto ? formatUsd(t.reparto.comisionesUsd) : <span className="text-on-surface-variant">—</span>}
        </Td>
        <Td className="font-semibold tabular-nums">{formatUsd(t.amountUsd)}</Td>
      </Tr>

      {abierta && (
        <tr>
          <Td colSpan={6} className="border-b border-panel-hairline bg-panel-raised/50 px-6 pt-2 pb-4">
            {lineas.isLoading && <SkeletonList rows={3} />}
            {lineas.isError && (
              <ErrorBox title="No pudimos abrir esta transferencia" detail={describeError(lineas.error)} />
            )}
            {lineas.data?.length === 0 && (
              <p className="py-2 type-panel-body text-on-surface-variant">
                Esta transferencia no tiene líneas asociadas.
              </p>
            )}
            {lineas.data &&
              agruparLineas(lineas.data).map((g) => (
                <div
                  key={`${g.concepto}-${g.businessDate ?? ''}`}
                  className="flex items-center justify-between gap-4 py-1.5 type-panel-body"
                >
                  <span className="text-on-surface-variant">
                    {g.concepto === 'consultas' ? (
                      <>
                        {CONCEPTO.consultas} · financiamientos del {formatDay(g.businessDate)} ·{' '}
                        {g.count} {g.count === 1 ? 'mitad' : 'mitades'}
                      </>
                    ) : (
                      <>
                        {CONCEPTO.comisiones} · {g.count}{' '}
                        {g.count === 1 ? 'financiamiento' : 'financiamientos'} ·{' '}
                        <Link to="/comisiones" className="underline underline-offset-2 hover:text-on-surface">
                          ver por persona
                        </Link>
                      </>
                    )}
                  </span>
                  <span className="tabular-nums">{formatUsd(g.amountUsd)}</span>
                </div>
              ))}
            {t.note && (
              <p className="mt-2 type-panel-caption text-panel-muted">Nota: {t.note}</p>
            )}
          </Td>
        </tr>
      )}
    </>
  )
}
