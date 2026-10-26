import { Link } from '@tanstack/react-router'
import { Store } from 'lucide-react'

import { Badge, Callout, Seccion, formatDay, formatUsd } from '@/components/ui'
import type { QueueItem } from '@/features/admin/api'
import { sumandosDelPago } from '@/features/admin/sumandosDelPago'

/**
 * Qué salda este pago: el consumo, la cuota y el cargo por atraso.
 *
 * Se agrupa por CONSUMO y no por cuota suelta porque la pregunta es «¿de qué
 * es este pago?», y quien llama habla del consumo (el local, la noche, el
 * número de orden), nunca de un identificador de cuota.
 *
 * El consumo no lleva monto en su cabecera: la base solo trae el del cargo con
 * la Comisión Helios dentro, y un consumo se enseña sin la comisión. Lo que se paga
 * está en las cuotas, que es lo que salda este pago.
 */
export function DesgloseDelPago({ item }: { item: QueueItem }) {
  const cuotasUsd = item.purchases.reduce(
    (sum, compra) => sum + compra.installments.reduce((acc, i) => acc + i.quotedUsd, 0),
    0,
  )
  const cargosUsd = item.lateFees.reduce((sum, cargo) => sum + cargo.amountUsd, 0)
  const { facturadoUsd, feeUsd } = sumandosDelPago(item)

  // El servidor cuadra esto antes de aprobar y se niega a saldar a medias: un
  // descuadre aquí no es un redondeo, es que algo cambió después de cotizar y
  // la aprobación va a fallar. Verlo antes ahorra el viaje.
  const cuadra = Math.abs(cuotasUsd + cargosUsd - item.amountUsd) < 0.005

  return (
    <Seccion
      titulo="Qué salda este pago"
      info="Agrupado por financiamiento. Cada cuota es financiado (sin comisión) + Comisión Helios + IVA, congelada al cotizar; los cargos por atraso van aparte."
    >
      {item.purchases.map((compra) => (
        <div
          key={compra.chargeId}
          className="overflow-hidden rounded-panel-card border border-panel-hairline bg-panel-card"
        >
          <div className="flex items-start justify-between gap-4 border-b border-panel-hairline bg-panel-raised px-4 py-3">
            <div>
              <p className="type-panel-body font-semibold text-on-surface">
                <Store size={14} className="mr-1.5 inline-block align-[-2px]" aria-hidden />
                <Link
                  to="/admin/clinicas/$id"
                  params={{ id: compra.merchantId }}
                  className="hover:underline"
                >
                  {compra.merchantName}
                </Link>
              </p>
              <p className="mt-1 type-panel-caption text-on-surface-variant">
                <Link
                  to="/admin/financiamientos/$id"
                  params={{ id: compra.chargeId }}
                  className="hover:text-on-surface hover:underline"
                >
                  {compra.orderNumber !== null ? `Orden #${compra.orderNumber}` : 'Ver el financiamiento'}
                </Link>
                {` · ${formatDay(compra.businessDate)}`}
              </p>
            </div>
            {compra.chargeStatus === 'voided' && (
              <Badge tone="error" icono>
                Financiamiento anulado
              </Badge>
            )}
          </div>

          <ul className="divide-y divide-panel-hairline">
            {compra.installments.map((cuota) => (
              <li
                key={cuota.installmentId}
                // En el teléfono el importe y su desglose bajan a su propio
                // renglón: al lado del vencimiento, con una pastilla, medían
                // más que la pantalla.
                className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 px-4 py-2.5"
              >
                <div className="min-w-0">
                  <p className="type-panel-body text-on-surface">
                    Cuota {cuota.sequence} de {compra.installmentsTotal}
                  </p>
                  <p className="mt-0.5 type-panel-caption text-on-surface-variant">
                    Vence el {formatDay(cuota.dueDate)}
                    {cuota.daysOverdue > 0 &&
                      ` · ${cuota.daysOverdue} ${cuota.daysOverdue === 1 ? 'día' : 'días'} de atraso`}
                  </p>
                </div>

                <div className="ml-auto flex min-w-0 flex-wrap items-center justify-end gap-3">
                  {/* Una cuota ya pagada dentro de un pago pendiente significa
                      que otro reporte la saldó antes: aprobarlo va a fallar. */}
                  {cuota.status === 'paid' && (
                    <Badge tone="error" icono>
                      Ya pagada
                    </Badge>
                  )}
                  {cuota.otherReports > 0 && (
                    <Badge tone="warning" icono>
                      {cuota.otherReports === 1
                        ? 'Un reporte más'
                        : `${cuota.otherReports} reportes más`}
                    </Badge>
                  )}
                  <span className="flex min-w-0 flex-col items-end text-right">
                    <span className="type-panel-body font-semibold tabular-nums text-on-surface">
                      {formatUsd(cuota.quotedUsd)}
                    </span>
                    {cuota.financedUsd != null && cuota.feeUsd != null && (
                      <span className="type-panel-caption tabular-nums text-on-surface-variant">
                        Financiado {formatUsd(cuota.financedUsd)} + Comisión Helios + IVA{' '}
                        {formatUsd(cuota.feeUsd)}
                      </span>
                    )}
                  </span>
                </div>
              </li>
            ))}
          </ul>
        </div>
      ))}

      {item.lateFees.length > 0 && (
        <Callout
          tone="warning"
          titulo={`${
            item.lateFees.length === 1 ? 'Un cargo por atraso' : `${item.lateFees.length} cargos por atraso`
          }: ${formatUsd(cargosUsd)}`}
        >
          <ul className="flex flex-col gap-1">
            {item.lateFees.map((cargo) => (
              <li key={cargo.lateFeeId}>
                {formatUsd(cargo.amountUsd)} por{' '}
                {cargo.sequence !== null && cargo.orderNumber !== null
                  ? `la cuota ${cargo.sequence} de la orden #${cargo.orderNumber}`
                  : 'un atraso anterior sin cuota'}
                , con {cargo.daysLate} {cargo.daysLate === 1 ? 'día' : 'días'} de atraso
                {cargo.orphan && '. Es de una cuota que no va en este pago'}.
              </li>
            ))}
          </ul>
        </Callout>
      )}

      {/* El pago entero son sus cuotas y sus cargos: el service fee ya va
          dentro de cada cuota y no se suma aparte. */}
      <div className="flex items-baseline justify-between gap-4 rounded-panel-card border border-panel-hairline bg-panel-card px-4 py-3">
        <p className="type-panel-body text-on-surface-variant">
          {item.installmentCount} {item.installmentCount === 1 ? 'cuota' : 'cuotas'} (financiado + Comisión Helios + IVA):{' '}
          {facturadoUsd !== null && feeUsd !== null
            ? `${formatUsd(facturadoUsd)} + ${formatUsd(feeUsd)} = ${formatUsd(cuotasUsd)}`
            : formatUsd(cuotasUsd)}
          {cargosUsd > 0 && `, más ${formatUsd(cargosUsd)} en cargos por atraso`}
        </p>
        <p className="type-panel-section tabular-nums text-on-surface">{formatUsd(item.amountUsd)}</p>
      </div>

      {!cuadra && (
        <Callout tone="error" titulo="El desglose no cuadra con el pago">
          Suma {formatUsd(cuotasUsd + cargosUsd)} y el pago reportado es de{' '}
          {formatUsd(item.amountUsd)}: algo cambió después de cotizar, y el servidor no lo va a
          aprobar así.
        </Callout>
      )}
    </Seccion>
  )
}
