import { Link, createFileRoute } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { ArrowLeft, Lock } from 'lucide-react'

import { usePageTitle } from '@/components/layouts/PageAction'
import {
  Badge,
  Card,
  DataLabel,
  Divider,
  EmptyState,
  ErrorBox,
  SectionTitle,
  SkeletonList,
  Table,
  Td,
  Tr,
  formatDay,
  formatUsd,
  formatTime,
} from '@/components/ui'
import { canSee } from '@/features/auth/permissions'
import { useStaff } from '@/features/auth/session'
import { fetchOrderDetail } from '@/features/charges/api'
import type { OrderDetail, OrderPayout } from '@/features/charges/api'
import { describeError } from '@/lib/supabase'

/**
 * LA FICHA DE UNA ORDEN, para el local.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * El historial era una tabla y punto final: el número de orden estaba ahí,
 * pero lo que se vendió —las líneas que tecleó el propio cajero— no se podía
 * consultar una vez cerrada la pantalla del QR, así que «¿qué incluía la orden
 * 1043?» se contestaba abriendo la caja registradora del local.
 *
 *   1. La venta: lo tuyo, el servicio que paga el cliente, y el total.
 *   2. Qué se vendió: las líneas con su precio unitario.
 *   3. Cuándo te pagamos: el lunes de cierre de cada mitad.
 *
 * ---------------------------------------------------------------------------
 * Lo que NO se enseña aquí, y no es un olvido
 * ---------------------------------------------------------------------------
 * **Las cuotas del cliente.** Cómo va esa deuda es asunto entre el cliente y
 * Ronda (docs/05 §3): al local se le paga por fecha de cierre, haya pagado su
 * cliente o no. Un «en mora» en esta pantalla se leería como «esto no me lo
 * van a pagar», que es exactamente lo contrario de lo que pasa. Tampoco quién
 * es el cliente ni cuánto puso cada integrante de una cuenta repartida.
 */
export const Route = createFileRoute('/_comercio/financiamientos_/$id')({
  staticData: { title: 'Financiamiento' },
  component: OrdenRoute,
})

function OrdenRoute() {
  const { id } = Route.useParams()
  const staff = useStaff()

  if (!staff) return null

  if (!canSee(staff.role, 'financiamientos')) {
    return (
      <EmptyState
        icon={<Lock size={48} />}
        title="Esto lo ve el administrador"
        description="Lo que financia la clínica entera es información del administrador. Tu pantalla es Nuevo financiamiento."
      />
    )
  }

  return <Orden chargeId={id} />
}

function Orden({ chargeId }: { chargeId: string }) {
  const query = useQuery({
    queryKey: ['merchant-order', chargeId],
    queryFn: () => fetchOrderDetail(chargeId),
  })

  usePageTitle(query.data ? `Orden #${query.data.orderNumber}` : null)

  return (
    <>
      <Link
        to="/financiamientos"
        className="mb-4 inline-flex items-center gap-1 type-panel-control text-on-surface-variant hover:text-on-surface"
      >
        <ArrowLeft size={14} /> Financiamientos
      </Link>

      {query.isLoading && <SkeletonList rows={3} />}

      {query.isError && (
        <ErrorBox
          title="No pudimos abrir esta orden"
          detail={describeError(query.error)}
        />
      )}

      {query.data && <Detalle orden={query.data} />}
    </>
  )
}

/** Dos decimales, para que las líneas del desglose cierren el total. */
function round2(value: number): number {
  return Math.round(value * 100) / 100
}

const ESTADO: Record<
  OrderDetail['status'],
  { texto: string; tone: 'success' | 'warning' | 'error' | 'neutral' }
> = {
  confirmed: { texto: 'Confirmada', tone: 'success' },
  pending: { texto: 'Esperando al paciente', tone: 'warning' },
  voided: { texto: 'Anulada', tone: 'error' },
  reverted: { texto: 'Revertida', tone: 'neutral' },
}

function Detalle({ orden }: { orden: OrderDetail }) {
  return (
    <div className="flex flex-col gap-6">
      <Venta orden={orden} />

      {orden.items.length > 0 ? (
        <Lineas orden={orden} />
      ) : (
        <p className="type-body-medium text-on-surface-variant">
          Este financiamiento no tiene concepto guardado.
        </p>
      )}

      {orden.payouts.length > 0 && <Cobros orden={orden} />}
    </div>
  )
}

// ── 1. La venta ───────────────────────────────────────────────────────────

/**
 * EL HÉROE ES TU VENTA, no lo que pagó el cliente.
 *
 * `amountUsd` lleva dentro el fee del servicio y su IVA, que son de Ronda:
 * enseñarlo como ingreso del local le infla la caja un 23 %. Las dos cifras
 * están, pero la grande es la que el dueño va a comparar contra su cierre.
 */
function Venta({ orden }: { orden: OrderDetail }) {
  const estado = ESTADO[orden.status]
  const servicio = round2(orden.amountUsd - orden.merchantSaleUsd)
  const fee = orden.consumerFeeUsd
  const iva = orden.consumerFeeVatUsd

  /**
   * El fee y su IVA por separado solo si SUMAN el servicio. Si no cuadran
   * —un cobro anterior al desglose— se dice el servicio en una línea, que es
   * cierto siempre, en vez de tres líneas que no cierran.
   */
  const desglosado =
    fee != null && iva != null && Math.abs(fee + iva - servicio) < 0.005

  const cuando = orden.confirmedAt ?? orden.createdAt

  return (
    <Card tone="brand" className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={estado.tone}>{estado.texto}</Badge>
        {orden.isTest && <Badge tone="neutral">Prueba</Badge>}
        <span className="type-label-medium text-on-surface-variant">
          Orden #{orden.orderNumber}
        </span>
      </div>

      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <DataLabel>Tu financiamiento</DataLabel>
          <p className="mt-1 type-panel-figure text-primary">
            {formatUsd(orden.merchantSaleUsd)}
          </p>
          {/* Quién compró, debajo del importe: las dos cosas juntas son la
              respuesta a «la de €48 de anoche, ¿de quién era?». Solo el
              nombre; la RPC no manda teléfono ni cédula. */}
          <p className="mt-1 type-body-medium text-on-surface">
            {orden.customerName ?? (
              <span className="text-on-surface-variant">
                Sin nombre
              </span>
            )}
          </p>
        </div>

        <div className="text-right">
          <p className="type-body-medium text-on-surface">
            {orden.businessDate ? formatDay(orden.businessDate) : '—'} ·{' '}
            {formatTime(cuando)}
          </p>
          <p className="type-label-medium text-on-surface-variant">
            {orden.branch?.name ?? 'Sin sede'}
            {/* QUIÉN DEL LOCAL LA COBRÓ. Va en este lado y no debajo del
                nombre del cliente: aquí está lo del local —sucursal, hora— y
                enfrente lo de quien compró. Es también la respuesta a «esta
                orden, ¿de quién es la comisión?».

                Null cuando quien mira no puede saberlo (un cajero, en las
                ventas de otros): entonces no se dice nada, en vez de un hueco
                rotulado que solo enseña que hay algo que no se le cuenta. */}
            {orden.staffName && ` · cobró ${orden.staffName}`}
            {/* El día de Ronda va de 10 AM a 10 AM: una venta de las 2 AM
                cuenta para la noche anterior, y si la hora y el día no
                coinciden hay que decir por qué. */}
            {orden.businessDate && cuando.slice(0, 10) !== orden.businessDate
              ? ' · cuenta para el día anterior'
              : ''}
          </p>
        </div>
      </div>

      <Divider />

      <dl className="flex flex-col gap-2 type-body-medium">
        <Linea
          label="Tu financiamiento"
          hint={orden.vatUsd && orden.vatUsd > 0 ? 'IVA incluido' : undefined}
          value={formatUsd(orden.merchantSaleUsd)}
        />
        {desglosado ? (
          <>
            <Linea label="Servicio tecnológico Helios" value={formatUsd(fee)} />
            <Linea label="IVA del servicio tecnológico" value={formatUsd(iva)} />
          </>
        ) : (
          servicio > 0 && (
            <Linea
              label="Servicio tecnológico Helios"
              hint="IVA incluido"
              value={formatUsd(servicio)}
            />
          )
        )}
      </dl>

      {/* El dinero del local es del gerente: lo decide la base, no esta
          pantalla. Un cajero ve la venta y las fechas, no la liquidación. */}
      {orden.isGerente && orden.merchantNetUsd !== null && (
        <>
          {orden.merchantFeeUsd !== null && orden.merchantFeeUsd > 0 && (
            <div className="flex items-baseline justify-between gap-4 type-body-medium">
              <span className="text-on-surface-variant">Comisión Helios</span>
              <span className="tabular-nums text-on-surface">
                −{formatUsd(orden.merchantFeeUsd)}
              </span>
            </div>
          )}
          <Divider />
          <div className="flex items-baseline justify-between gap-4 type-body-medium">
            <span className="text-on-surface">Lo que te pagamos</span>
            <span className="tabular-nums type-body-large-emphasized text-on-surface">
              {formatUsd(orden.merchantNetUsd)}
            </span>
          </div>
        </>
      )}

      {orden.voidReason && (
        <p className="rounded-[var(--radius-panel-control)] bg-shell-control p-3 type-body-medium italic text-on-surface-variant">
          {orden.voidReason}
        </p>
      )}
    </Card>
  )
}

/** Una fila rótulo–importe del desglose. Los importes en una sola columna. */
function Linea({ label, hint, value }: { label: string; hint?: string; value: string }) {
  return (
    <div className="flex items-baseline justify-between gap-4">
      <dt className="text-on-surface-variant">
        {label}
        {hint && (
          <span className="ml-2 type-label-medium text-on-surface-variant">{hint}</span>
        )}
      </dt>
      <dd className="tabular-nums text-on-surface">{value}</dd>
    </div>
  )
}

// ── 2. Qué se vendió ──────────────────────────────────────────────────────

/**
 * Las líneas del cobro, con el precio unitario.
 *
 * El unitario no es adorno: con la cantidad y el subtotal a secas, comprobar
 * una línea obliga a dividir de cabeza, que es justo lo que hace el cajero
 * cuando un cliente vuelve a la barra a reclamar.
 */
function Lineas({ orden }: { orden: OrderDetail }) {
  const suma = round2(orden.items.reduce((total, item) => total + item.lineTotalUsd, 0))

  return (
    <section>
      <SectionTitle className="mb-3">Qué se vendió</SectionTitle>
      <Card>
        <ul className="flex flex-col gap-3">
          {/* Las líneas no traen id propio y el nombre puede repetirse: la
              posición dentro del cobro es la única clave estable. */}
          {orden.items.map((item, index) => (
            <li key={`${index}-${item.name}`} className="flex items-baseline gap-3">
              <div className="min-w-0 flex-1">
                <p className="truncate type-body-medium text-on-surface">{item.name}</p>
                <p className="tabular-nums type-label-medium text-on-surface-variant">
                  {item.quantity} × {formatUsd(item.unitPriceUsd)}
                </p>
              </div>
              <span className="tabular-nums type-body-medium-emphasized text-on-surface">
                {formatUsd(item.lineTotalUsd)}
              </span>
            </li>
          ))}
        </ul>

        <Divider className="my-3" />

        <div className="flex items-baseline justify-between gap-4 type-body-medium">
          <span className="text-on-surface-variant">
            Suma de las líneas
            {/* Que no cuadre con la venta quiere decir que se tecleó un monto
                libre encima del carrito. Es un dato, no un detalle. */}
            {Math.abs(suma - orden.merchantSaleUsd) >= 0.01 && (
              <span className="ml-2 type-label-medium text-warning">
                no cuadra con el financiamiento ({formatUsd(orden.merchantSaleUsd)})
              </span>
            )}
          </span>
          <span className="tabular-nums type-body-medium-emphasized text-on-surface">
            {formatUsd(suma)}
          </span>
        </div>
      </Card>
    </section>
  )
}

// ── 3. Cuándo te pagamos ──────────────────────────────────────────────────

const CONCEPTO: Record<OrderPayout['kind'], string> = {
  advance: 'Adelanto al vender',
  installment: 'Mitad del financiamiento',
}

const ESTADO_COBRO: Record<
  string,
  { texto: string; tone: 'success' | 'warning' | 'neutral' | 'error' }
> = {
  pending: { texto: 'Por transferir', tone: 'warning' },
  partial: { texto: 'Transferida en parte', tone: 'warning' },
  paid: { texto: 'Transferida', tone: 'success' },
  cancelled: { texto: 'Cancelada', tone: 'neutral' },
}

/**
 * El calendario de cobro de ESTA orden.
 *
 * La fecha es el lunes de cierre que paga esa mitad y la calcula la base: si
 * el cierre se mueve, esta pantalla no puede quedarse con el de antes.
 *
 * El importe aparece cuando la cuota vence y nace la liquidación; hasta
 * entonces se dice «al vencer» en vez de estimarlo, porque el reparto por
 * tramos lo decide el cierre y una estimación aquí sería una promesa que
 * ninguna otra pantalla repite.
 */
function Cobros({ orden }: { orden: OrderDetail }) {
  return (
    <section>
      <SectionTitle className="mb-3">Cuándo te pagamos</SectionTitle>

      <Table
        headers={
          orden.isGerente
            ? ['Concepto', 'Cierre', 'Importe', 'Estado']
            : ['Concepto', 'Cierre']
        }
      >
        {orden.payouts.map((pago) => {
          const estado = pago.status ? ESTADO_COBRO[pago.status] : undefined

          return (
            <Tr key={`${pago.kind}-${pago.sequence ?? 0}-${pago.dueDate}`}>
              <Td className="whitespace-nowrap">
                {CONCEPTO[pago.kind]}
                {pago.sequence !== null && ` ${pago.sequence} de 2`}
              </Td>
              <Td className="whitespace-nowrap">
                {formatDay(pago.runDate)}
                <span className="block type-label-medium text-on-surface-variant">
                  vence el {formatDay(pago.dueDate)}
                </span>
              </Td>

              {orden.isGerente && (
                <>
                  <Td className="whitespace-nowrap tabular-nums">
                    {pago.amountUsd === null ? (
                      <span className="text-on-surface-variant">Se calcula al vencer</span>
                    ) : (
                      <>
                        {formatUsd(pago.amountUsd)}
                        {pago.status === 'partial' && pago.paidUsd !== null && (
                          <span className="block type-label-medium text-on-surface-variant">
                            {formatUsd(pago.paidUsd)} transferidos
                          </span>
                        )}
                      </>
                    )}
                  </Td>
                  <Td>
                    {estado ? (
                      <Badge tone={estado.tone}>{estado.texto}</Badge>
                    ) : (
                      <span className="type-body-medium text-on-surface-variant">—</span>
                    )}
                  </Td>
                </>
              )}
            </Tr>
          )
        })}
      </Table>

      <p className="mt-4 type-label-medium leading-5 text-on-surface-variant">
        Cerramos caja los lunes a las 10:00 y transferimos ese mismo día lo que
        venció durante la semana, <strong>haya pagado o no tu paciente</strong>.
      </p>

    </section>
  )
}
