import { formatUsd } from '@/components/ui'
import type { Desglose } from '@/features/admin/metricas/lectura'

/**
 * Un importe que se paga en cuotas (lo vencido, lo vivo), con sus dos partes
 * debajo: «$108,20» y «consumo $87,82 + Comisión Helios $20,38».
 *
 * Es la regla de la comisión: una cifra con la Comisión Helios dentro no se enseña nunca
 * sin sus sumandos. En una celda de tabla va alineado a la derecha.
 */
export function ImporteConDesglose({ desglose, className = '' }: { desglose: Desglose; className?: string }) {
  if (desglose.payableUsd <= 0) return <span className={className}>{formatUsd(0)}</span>

  return (
    <span className={`inline-flex flex-col items-end gap-0.5 ${className}`}>
      <span className="font-semibold">{formatUsd(desglose.payableUsd)}</span>
      <span className="whitespace-nowrap type-panel-caption text-on-surface-variant">
        financiamiento {formatUsd(desglose.financedUsd)} + Comisión Helios {formatUsd(desglose.feeUsd)}
      </span>
    </span>
  )
}
