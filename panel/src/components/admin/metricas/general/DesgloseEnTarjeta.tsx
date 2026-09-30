import { formatUsd } from '@/components/ui'
import type { Desglose } from '@/features/admin/metricas/lectura'

/**
 * Las dos partes de un importe que se paga en cuotas, dentro de su tarjeta:
 * el consumo y el service fee con su IVA.
 *
 * Es la regla del fee: lo que se paga nunca se enseña sin decir de qué está
 * hecho. Va en dos renglones y no en el pie de la tarjeta, que se corta con
 * puntos suspensivos si no cabe: el desglose tiene que leerse siempre entero.
 * El fee dice que lleva su IVA porque en el mismo bloque está el service fee
 * ganado, que va sin él.
 */
export function DesgloseEnTarjeta({ desglose }: { desglose: Desglose }) {
  return (
    <dl className="flex flex-col gap-1 border-t border-panel-hairline pt-2.5">
      <Parte rotulo="Financiado (sin fee)" valor={formatUsd(desglose.financedUsd)} />
      <Parte rotulo="Service fee + IVA" valor={formatUsd(desglose.feeUsd)} />
    </dl>
  )
}

function Parte({ rotulo, valor }: { rotulo: string; valor: string }) {
  return (
    <div className="flex items-baseline justify-between gap-2">
      <dt className="type-panel-caption text-on-surface-variant">{rotulo}</dt>
      <dd className="type-panel-label tabular-nums text-on-surface">{valor}</dd>
    </div>
  )
}
