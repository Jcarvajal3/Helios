import { Link, useNavigate } from '@tanstack/react-router'

import { EstadoDeLaOrdenBadge } from '@/components/admin/EstadoBadge'
import {
  Badge,
  Card,
  Seccion,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatDay,
  formatMoneda,
  formatTime,
  formatUsd,
} from '@/components/ui'
import type { ConsumoDePersona } from '@/features/admin/directorio/consumosDePersona'
import { textoDeDesgloseCorto } from '@/features/admin/metricas/formato'
import { cuotasDelPlan, esLaInicial, rotuloDeCuota } from '@/features/admin/rotuloDeCuota'
import type { UserDetail } from '@/features/admin/users'
import { CargosPorAtraso } from './CargosPorAtraso'

/** La pestaña Consumos y cuotas, con los cargos por atraso debajo. */
export function PestanaConsumos({
  user,
  userId,
  onDone,
}: {
  user: UserDetail
  userId: string
  onDone: () => void
}) {
  // Los consumos vienen en la misma lectura que la ficha
  // (`admin_user_detail.consumos`): lo que la refresca los refresca.
  return (
    <>
      <SusConsumos consumos={user.consumos} />
      <SusCuotas user={user} consumos={user.consumos} />
      <CargosPorAtraso userId={userId} onDone={onDone} />
    </>
  )
}

// ── Consumos ───────────────────────────────────────────────────────────────

/**
 * Los consumos en los que está esta persona: los que puso y los de grupo en
 * los que le tocó una parte.
 *
 * El importe es el consumo sin la Comisión Helios, que es lo que ocupó de su
 * cupo. La comisión va repartido en las cuotas, en la tabla de abajo. Cada
 * fila abre la factura del consumo, y el local abre su ficha.
 */
function SusConsumos({ consumos }: { consumos: Array<ConsumoDePersona> }) {
  const navigate = useNavigate()

  return (
    <Seccion
      titulo="Sus financiamientos"
      info="Sus órdenes, de todas las clínicas. Cada fila abre la orden."
    >
      {consumos.length === 0 && (
        <Card>
          <p className="type-panel-body text-on-surface-variant">Todavía no se ha financiado nada.</p>
        </Card>
      )}

      {consumos.length > 0 && (
        <Table
          headers={[
            '# Orden',
            'Día operativo',
            'Clínica',
            {
              label: 'Financiamiento (sin comisión)',
              info: 'Sin la Comisión Helios: el monto de la consulta.',
            },
            'Estado',
          ]}
        >
          {consumos.map((c) => (
            <Tr
              key={c.chargeId}
              onClick={() => void navigate({ to: '/admin/financiamientos/$id', params: { id: c.chargeId } })}
            >
              <Td className="whitespace-nowrap font-semibold text-on-surface">
                {c.orderNumber === null ? '—' : `#${c.orderNumber}`}
              </Td>
              <Td className="whitespace-nowrap">{formatDay(c.businessDate)}</Td>
              <Td>
                <Link
                  to="/admin/clinicas/$id"
                  params={{ id: c.merchantId }}
                  onClick={(e) => e.stopPropagation()}
                  className="text-on-surface hover:underline"
                >
                  {c.merchantName ?? 'Clínica sin nombre'}
                </Link>
              </Td>
              <Td className="tabular-nums">
                <ImporteDelConsumo consumo={c} />
              </Td>
              <Td>
                <EstadoDeLaOrdenBadge orden={c} />
                {/* La que espera la inicial dice hasta cuándo: luego se anula sola. */}
                {c.status === 'awaiting_down_payment' && c.downPaymentDueAt && (
                  <span className="mt-1 block type-panel-caption text-on-surface-variant">
                    Hasta las {formatTime(c.downPaymentDueAt)}
                  </span>
                )}
                {c.voidReason && (
                  <span className="mt-1 block max-w-48 type-panel-caption text-on-surface-variant">
                    {c.voidReason}
                  </span>
                )}
              </Td>
            </Tr>
          ))}
        </Table>
      )}
    </Seccion>
  )
}

/**
 * Su parte si la tiene; si no, el consumo entero (un pendiente, un anulado).
 * En un grupo se dice de cuánto era el consumo, que es lo primero que se
 * pregunta cuando dos personas del mismo grupo deben cosas distintas.
 */
function ImporteDelConsumo({ consumo: c }: { consumo: ConsumoDePersona }) {
  const importe = c.parteUsd ?? c.cuentaUsd

  return (
    <>
      {formatUsd(importe)}
    </>
  )
}

// ── Cuotas ─────────────────────────────────────────────────────────────────

/**
 * Sus cuotas, con el service fee dentro: es lo que tiene que transferir. Cada
 * fila abre la factura de su consumo, porque la pregunta que sigue a «la
 * cuota 2 de la orden 1043» es siempre qué había en esa orden.
 */
function SusCuotas({
  user,
  consumos,
}: {
  user: UserDetail
  consumos: Array<ConsumoDePersona>
}) {
  const navigate = useNavigate()
  if (user.installments.length === 0) return null

  // El local de cada cuota sale de sus consumos, que traen el id.
  const localDe = new Map(consumos.map((c) => [c.chargeId, c.merchantId]))
  // El «de 2» de cada orden: sus cuotas sin la inicial.
  const delPlan = new Map<string, number>()
  for (const i of user.installments) {
    if (!delPlan.has(i.chargeId)) {
      delPlan.set(i.chargeId, cuotasDelPlan(user.installments.filter((x) => x.chargeId === i.chargeId)))
    }
  }

  return (
    <Seccion titulo="Sus cuotas" info="Cada cuota es financiamiento + Comisión Helios: es lo que tiene que transferir. En las órdenes desde el 2026-11-12, la primera es la inicial (el 50% del total, el día del «Sí»), que nunca cuenta como vencida. Cada fila abre la factura de su financiamiento.">
      <Table
        headers={[
          '# Orden',
          'Vence',
          'Clínica',
          'Cuota',
          { label: 'Cuota (financiamiento + comisión)', info: 'Lo que se paga en esa cuota: financiamiento + Comisión Helios (IVA incluido). Debajo, sus dos partes.' },
          'Estado',
        ]}
      >
        {user.installments.map((i) => {
          const localId = localDe.get(i.chargeId)
          return (
            <Tr
              key={i.id}
              onClick={() => void navigate({ to: '/admin/financiamientos/$id', params: { id: i.chargeId } })}
            >
              <Td className="whitespace-nowrap font-semibold text-on-surface">
                {i.orderNumber === null ? '—' : `#${i.orderNumber}`}
              </Td>
              <Td className="whitespace-nowrap">{formatDay(i.dueDate)}</Td>
              <Td>
                {localId ? (
                  <Link
                    to="/admin/clinicas/$id"
                    params={{ id: localId }}
                    onClick={(e) => e.stopPropagation()}
                    className="text-on-surface hover:underline"
                  >
                    {i.merchantName}
                  </Link>
                ) : (
                  <span className="text-on-surface-variant">{i.merchantName}</span>
                )}
              </Td>
              <Td className="whitespace-nowrap text-on-surface-variant">
                {rotuloDeCuota(i.sequence, delPlan.get(i.chargeId) || 2)}
              </Td>
              <Td className="tabular-nums">
                {formatUsd(i.amountUsd)}
                <span className="block type-panel-caption text-on-surface-variant">
                  {textoDeDesgloseCorto({ financedUsd: i.financedUsd, feeUsd: i.amountUsd - i.financedUsd })}
                </span>
                {/* La cifra sigue en dólares; si la orden se cobró en euros, lo
                    que paga el paciente es esto, a la tasa del euro. */}
                {i.currency === 'EUR' && (
                  <span
                    className="block type-panel-caption text-on-surface-variant"
                    title="Orden cobrada en euros: el paciente paga esta cuota en bolívares a la tasa BCV del euro del día en que paga."
                  >
                    cobrada en {formatMoneda(i.amountCur, 'EUR')}
                  </span>
                )}
              </Td>
              <Td>
                {/* Una cuota pagada dice CUÁNDO: es el dato que se coteja
                    contra el banco cuando alguien reclama que pagó. */}
                {i.status === 'paid' ? (
                  <>
                    <Badge tone="success" icono>
                      Pagada
                    </Badge>
                    {i.paidAt && (
                      <span className="mt-1 block whitespace-nowrap type-panel-caption text-on-surface-variant">
                        {formatDateTime(i.paidAt)}
                      </span>
                    )}
                  </>
                ) : i.writtenOffAt ? (
                  <Badge tone="error" icono>
                    Perdida
                  </Badge>
                ) : esLaInicial(i.sequence) ? (
                  <Badge tone="warning">Por pagar</Badge>
                ) : i.daysOverdue > 0 ? (
                  <Badge tone="error" icono>
                    Vencida hace {i.daysOverdue} {i.daysOverdue === 1 ? 'día' : 'días'}
                  </Badge>
                ) : (
                  <Badge>Por vencer</Badge>
                )}
              </Td>
            </Tr>
          )
        })}
      </Table>
    </Seccion>
  )
}
