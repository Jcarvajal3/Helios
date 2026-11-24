import { Badge } from '@/components/ui'
import { visualPagoCompra, visualSolicitudCompra } from '@/features/admin/compras/estados'

/**
 * Insignia de estado de una solicitud de compra Amazon.
 * Siempre incluye su icono para lectura accesible sin depender del color.
 */
export function EstadoSolicitudCompraBadge({
  valor,
  className = '',
}: {
  valor: string
  className?: string
}) {
  const visual = visualSolicitudCompra(valor)
  return (
    <span className="inline-flex" title={visual.que}>
      <Badge tone={visual.tone} icono={visual.icon} className={className}>
        {visual.label}
      </Badge>
    </span>
  )
}

/**
 * Insignia de estado de un pago reportado de compra Amazon.
 * Siempre incluye su icono.
 */
export function EstadoPagoCompraBadge({
  valor,
  className = '',
}: {
  valor: string
  className?: string
}) {
  const visual = visualPagoCompra(valor)
  return (
    <span className="inline-flex" title={visual.que}>
      <Badge tone={visual.tone} icono={visual.icon} className={className}>
        {visual.label}
      </Badge>
    </span>
  )
}
