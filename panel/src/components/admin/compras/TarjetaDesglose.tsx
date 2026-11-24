import { ExternalLink, Package, Plane, Ship, TriangleAlert } from 'lucide-react'

import {
  Badge,
  Callout,
  Card,
  DataLabel,
  Seccion,
  claseDeBoton,
  formatBcvRate,
  formatDateTime,
  formatNumero,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { formatTasa } from '@/features/admin/ajustesReglas'
import { etiquetaDeEnvio } from '@/features/admin/compras/estados'
import type { SolicitudCompraResumen } from '@/features/admin/compras/tipos'
import { Dato, FilaFinanciera } from './piezas'

export function TarjetaProducto({
  request,
}: {
  request: SolicitudCompraResumen
}) {
  return (
    <Seccion titulo="Producto cotizado">
      <Card className="flex flex-col gap-4">
        <div className="flex flex-col gap-4 sm:flex-row">
          <div className="flex size-28 shrink-0 items-center justify-center overflow-hidden rounded-panel-control border border-panel-hairline bg-panel-raised">
            {request.imageUrl ? (
              <img
                src={request.imageUrl}
                alt={request.productTitle}
                className="size-full object-cover"
              />
            ) : (
              <Package size={32} className="text-panel-muted" aria-hidden />
            )}
          </div>
          <div className="flex min-w-0 flex-1 flex-col gap-2">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <h3 className="type-panel-body font-semibold text-on-surface">
                {request.productTitle}
              </h3>
              {request.productUrl && (
                <a
                  href={request.productUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                  className={claseDeBoton('tonal', 'sm')}
                >
                  Ver en Amazon <ExternalLink size={14} aria-hidden />
                </a>
              )}
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone="neutral">ASIN: {request.asin}</Badge>
              <Badge
                tone="neutral"
                icono={request.shippingMethod === 'maritimo' ? Ship : Plane}
              >
                Envío {etiquetaDeEnvio(request.shippingMethod)}
              </Badge>
              <Badge tone="neutral">Cantidad: {request.quantity}</Badge>
              {request.variantLabel && (
                <Badge tone="neutral">{request.variantLabel}</Badge>
              )}
              {request.category && (
                <Badge tone="neutral">{request.category}</Badge>
              )}
            </div>

            <dl className="mt-1 grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-4">
              <Dato
                label="Peso real"
                value={
                  request.weightLb !== null
                    ? `${formatNumero(request.weightLb, 2)} lb`
                    : 'Sin listar'
                }
              />
              <Dato
                label="Peso volumétrico"
                value={
                  request.volumetricWeightLb !== null
                    ? `${formatNumero(request.volumetricWeightLb, 2)} lb`
                    : '—'
                }
              />
              <Dato
                label="Volumen"
                value={
                  request.volumeFt3 !== null
                    ? `${formatNumero(request.volumeFt3, 2)} ft³`
                    : '—'
                }
              />
              <Dato
                label="Precio unitario"
                value={formatUsd(request.unitPriceUsd)}
              />
            </dl>
          </div>
        </div>

        {request.weightEstimated && (
          <Callout tone="warning" titulo="Peso estimado en la cotización">
            Amazon no listó el peso exacto de este producto; se utilizó el peso
            de respaldo configurado en Ajustes para calcular el flete.
          </Callout>
        )}

        {(request.amazonOrderId || request.usTrackingNumber) && (
          <div className="grid grid-cols-1 gap-3 border-t border-panel-hairline pt-3 sm:grid-cols-2">
            {request.amazonOrderId && (
              <Dato
                label="ID de orden en Amazon"
                value={request.amazonOrderId}
                mono
              />
            )}
            {request.usTrackingNumber && (
              <Dato
                label="Tracking almacén USA"
                value={request.usTrackingNumber}
                mono
              />
            )}
          </div>
        )}
      </Card>
    </Seccion>
  )
}

/** Desglose congelado: todo sale tal cual lo guardó el servidor. */
export function TarjetaDesglose({
  request,
  bcvRateToday,
  paymentBlock,
}: {
  request: SolicitudCompraResumen
  bcvRateToday: number | null
  paymentBlock: string | null
}) {
  return (
    <Seccion titulo="Desglose financiero congelado">
      <Card className="flex flex-col gap-3">
        <div className="flex flex-col gap-2">
          <FilaFinanciera
            rotulo={`Subtotal Amazon (${request.quantity} × ${formatUsd(request.unitPriceUsd)})`}
            valor={formatUsd(request.subtotalUsd)}
          />
          <FilaFinanciera
            rotulo="Tax USA"
            valor={formatUsd(request.taxUsaUsd)}
          />
          <FilaFinanciera
            rotulo={`Envío internacional (${etiquetaDeEnvio(request.shippingMethod)})`}
            valor={formatUsd(request.shippingUsd)}
          />
          <FilaFinanciera
            rotulo="Tarifa de gestión Helios"
            valor={formatUsd(request.serviceFeeUsd)}
          />
        </div>

        <div className="border-t border-panel-hairline pt-3">
          <FilaFinanciera
            rotulo="Total en dólares"
            valor={formatUsd(request.totalUsd)}
            fuerte
          />
        </div>

        <div className="grid grid-cols-1 gap-3 rounded-panel-control bg-panel-raised p-3.5 sm:grid-cols-2">
          <div>
            <DataLabel>Referencia al cotizar</DataLabel>
            <p className="mt-1 type-panel-body font-semibold tabular-nums text-on-surface">
              {request.totalVesQuote !== null
                ? formatVes(request.totalVesQuote)
                : '—'}
            </p>
            <p className="mt-0.5 type-panel-caption text-on-surface-variant">
              {request.bcvRateQuote !== null
                ? formatTasa(request.bcvRateQuote, 'USD')
                : 'Se liquida a la tasa BCV del día del pago'}
            </p>
          </div>
          <div>
            <DataLabel>Tasa BCV de hoy</DataLabel>
            <p className="mt-1 type-panel-body font-semibold tabular-nums text-on-surface">
              {bcvRateToday !== null
                ? formatBcvRate(bcvRateToday)
                : 'Sin tasa BCV cargada'}
            </p>
            {request.quoteExpiresAt && (
              <p className="mt-0.5 type-panel-caption text-on-surface-variant">
                La cotización {request.vencida ? 'venció' : 'vence'} el{' '}
                {formatDateTime(request.quoteExpiresAt)}
              </p>
            )}
          </div>
        </div>

        {request.vencida && (
          <Callout tone="warning" titulo="Cotización vencida">
            <span className="inline-flex items-center gap-1.5">
              <TriangleAlert size={14} aria-hidden />
              El médico tendrá que recotizar desde WhatsApp. Si registras un
              pago, queda marcado como pago sobre cotización vencida.
            </span>
          </Callout>
        )}

        {paymentBlock && (
          <div>
            <DataLabel>Bloque de pago que ve el médico</DataLabel>
            <p className="mt-1 whitespace-pre-wrap type-panel-body text-on-surface-variant">
              {paymentBlock}
            </p>
          </div>
        )}
      </Card>
    </Seccion>
  )
}
