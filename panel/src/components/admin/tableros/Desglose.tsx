import { InfoDot } from '@/components/ui'

/** Una línea de un desglose: el rótulo con su explicación y la cifra ya formateada. */
export type LineaDeDesglose = {
  rotulo: string
  valor: string
  info?: string
  /** La línea que cierra el desglose: más grande y con una raya encima. */
  total?: boolean
}

/**
 * Un desglose: líneas una debajo de otra, cada una con su explicación.
 *
 * Es la forma de lo que no se suma en una cifra (lo devengado y lo cobrado del
 * mes) o de lo que sí cierra con su suma (lo que deja cada €100). Solo lleva
 * total cuando quien llama lo pide: sumar la Comisión Helios con el consumo en una
 * línea final es justo lo que no se hace.
 */
export function Desglose({ lineas }: { lineas: ReadonlyArray<LineaDeDesglose> }) {
  return (
    <dl className="flex flex-col divide-y divide-panel-hairline">
      {lineas.map((l) => (
        <div
          key={l.rotulo}
          className={`flex items-baseline justify-between gap-4 py-2.5 first:pt-0 last:pb-0 ${
            l.total ? 'pt-3.5' : ''
          }`}
        >
          <dt
            className={`flex items-center gap-1.5 type-panel-body ${
              l.total ? 'font-semibold text-on-surface' : 'text-on-surface-variant'
            }`}
          >
            {l.rotulo}
            {l.info && <InfoDot title={l.rotulo} what={l.info} />}
          </dt>
          <dd
            className={`tabular-nums text-on-surface ${
              l.total ? 'type-panel-figure' : 'type-panel-body font-semibold'
            }`}
          >
            {l.valor}
          </dd>
        </div>
      ))}
    </dl>
  )
}
