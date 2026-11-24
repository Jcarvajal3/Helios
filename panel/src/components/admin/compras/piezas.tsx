import { CheckCircle2, TriangleAlert } from 'lucide-react'

import { Badge, formatVes } from '@/components/ui'
import type { PagoCompraReporte } from '@/features/admin/compras/tipos'

/** Una pareja rótulo / valor para las fichas. */
export function Dato({
  label,
  value,
  mono = false,
}: {
  label: string
  value: string
  mono?: boolean
}) {
  return (
    <div className="min-w-0">
      <dt className="type-panel-label text-on-surface-variant">{label}</dt>
      <dd
        className={`mt-0.5 type-panel-body text-on-surface [overflow-wrap:anywhere] ${
          mono ? 'font-mono tracking-wider' : ''
        }`}
      >
        {value}
      </dd>
    </div>
  )
}

/** Una fila de desglose: concepto a la izquierda, monto a la derecha. */
export function FilaFinanciera({
  rotulo,
  valor,
  fuerte = false,
}: {
  rotulo: string
  valor: string
  fuerte?: boolean
}) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <span className="type-panel-body text-on-surface-variant">{rotulo}</span>
      <span
        className={`tabular-nums text-on-surface ${
          fuerte ? 'type-panel-section' : 'type-panel-body font-semibold'
        }`}
      >
        {valor}
      </span>
    </div>
  )
}

function conSigno(bs: number): string {
  return `${bs >= 0 ? '+' : '−'}${formatVes(Math.abs(bs))}`
}

/**
 * Lo que el servidor dice del monto de un pago: nunca se recalcula aquí. Sin monto
 * declarado no hay «Cuadra» posible: hay que mirarlo en el banco.
 */
export function InsigniaMonto({ pago }: { pago: PagoCompraReporte }) {
  if (!pago.montoDeclarado) {
    return (
      <Badge tone="warning" icono={TriangleAlert}>
        Monto no declarado: verifica en el banco
      </Badge>
    )
  }
  if (pago.montoCuadra === null || pago.diferenciaVes === null) return null
  return pago.montoCuadra ? (
    <Badge tone="success" icono={CheckCircle2}>
      Cuadra ({conSigno(pago.diferenciaVes)})
    </Badge>
  ) : (
    <Badge tone="warning" icono={TriangleAlert}>
      Fuera de margen ({conSigno(pago.diferenciaVes)})
    </Badge>
  )
}
