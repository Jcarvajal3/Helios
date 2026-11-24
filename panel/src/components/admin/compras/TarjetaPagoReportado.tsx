import { TriangleAlert } from 'lucide-react'

import { VerCaptura } from '@/components/admin/caja/VerCaptura'
import {
  Badge,
  Callout,
  Card,
  formatDateTime,
  formatDay,
  formatPhone,
  formatVes,
} from '@/components/ui'
import { formatTasa } from '@/features/admin/ajustesReglas'
import { etiquetaDeMetodoPago } from '@/features/admin/compras/estados'
import type { PagoCompraReporte } from '@/features/admin/compras/tipos'
import { EstadoPagoCompraBadge } from './EstadoCompraBadge'
import { Dato, InsigniaMonto } from './piezas'

/** Un pago reportado de la solicitud, con lo que el servidor dice del monto. */
export function TarjetaPagoReportado({ pago }: { pago: PagoCompraReporte }) {
  return (
    <Card className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <EstadoPagoCompraBadge valor={pago.status} />
          <span className="type-panel-body font-semibold tabular-nums text-on-surface">
            {pago.amountVes !== null
              ? formatVes(pago.amountVes)
              : 'Monto no declarado'}
          </span>
          <InsigniaMonto pago={pago} />
          {pago.cotizacionVencida && (
            <Badge tone="warning" icono={TriangleAlert}>
              Cotización vencida al reportar
            </Badge>
          )}
        </div>
        <span className="type-panel-caption tabular-nums text-panel-muted">
          Reportado el {formatDateTime(pago.createdAt)}
        </span>
      </div>

      <dl className="grid grid-cols-2 gap-x-4 gap-y-2.5 sm:grid-cols-4">
        <Dato label="Medio" value={etiquetaDeMetodoPago(pago.method)} />
        <Dato label="Banco" value={pago.bank ?? '—'} />
        <Dato label="Referencia" value={pago.reference ?? '—'} mono />
        <Dato label="Fecha del pago" value={formatDay(pago.paidOn)} />
        <Dato label="Teléfono pagador" value={formatPhone(pago.payerPhone)} />
        <Dato
          label="Esperado (Bs)"
          value={pago.expectedVes !== null ? formatVes(pago.expectedVes) : '—'}
        />
        <Dato
          label="Tasa BCV"
          value={pago.fxRate !== null ? formatTasa(pago.fxRate, 'USD') : '—'}
        />
        <Dato
          label="Registrado por"
          value={pago.registeredByName ?? 'Médico / Bot'}
        />
      </dl>

      {pago.referenceCollisions > 0 && (
        <Callout tone="warning" titulo="Referencia repetida en otro reporte">
          Esta referencia aparece en {pago.referenceCollisions}{' '}
          {pago.referenceCollisions === 1
            ? 'reporte adicional'
            : 'reportes adicionales'}
          . Verifica el extracto bancario antes de aprobar.
        </Callout>
      )}

      {(pago.rejectionNote || pago.note) && (
        <p className="rounded-panel-control bg-panel-raised px-3 py-2 type-panel-body text-on-surface-variant">
          {pago.rejectionNote ?? pago.note}
        </p>
      )}

      {pago.reviewedAt && (
        <p className="type-panel-caption text-panel-muted">
          Revisado el {formatDateTime(pago.reviewedAt)}
          {pago.reviewedByName ? ` por ${pago.reviewedByName}` : ''}.
        </p>
      )}

      {pago.receiptPath && (
        <VerCaptura
          ruta={pago.receiptPath}
          rotulo="Ver captura del comprobante"
        />
      )}
    </Card>
  )
}
