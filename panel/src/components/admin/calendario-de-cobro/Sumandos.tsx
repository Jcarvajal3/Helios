import { InfoDot, formatUsd } from '@/components/ui'
import type { CifrasPorCobrar } from '@/features/admin/porCobrar'

/**
 * Los rótulos de los tres sumandos. La clave `comision` es el nombre de la
 * base (`comisionUsd`); en pantalla es el service fee + IVA. No
 * es la comisión del local, que Ronda cobra al local y aquí no sale.
 */
export const ROTULOS = {
  consumo: 'Financiado (sin fee)',
  comision: 'Service fee + IVA',
  cargos: 'Cargos por atraso',
} as const

export const QUE_ES = {
  consumo: 'Lo financiado en la clínica, sin el service fee: la suma del financiado de esas cuotas. Es lo que descuenta cupo y lo que se pierde entero si la cuota no se paga.',
  comision:
    'El service fee de Helios con el IVA que lo grava. El IVA no es de Helios: se cobra al paciente y se remite.',
  cargos:
    'Los cargos por atraso de esas mismas cuotas. Van siempre aparte: no son financiamiento ni service fee.',
} as const

/**
 * Las partes de una cifra de Por cobrar, dentro de su tarjeta: el consumo, el
 * service fee y, si hay, los cargos por atraso. Es lo que deja enseñar el
 * total encima: una cifra con el fee dentro solo se pinta con sus sumandos a
 * la vista.
 *
 * Va por encima del enlace de la tarjeta (`relative z-10`), para que los
 * `InfoDot` se puedan pulsar.
 */
export function Sumandos({
  cifras,
  grande = false,
}: {
  cifras: CifrasPorCobrar
  /** La de la cifra titular: a la medida del cuerpo y no del pie. */
  grande?: boolean
}) {
  const lineas: Array<{ clave: keyof typeof ROTULOS; valor: number }> = [
    { clave: 'consumo', valor: cifras.consumoUsd },
    { clave: 'comision', valor: cifras.comisionUsd },
  ]
  // Los cargos solo cuando los hay: un «€0,00 de cargos» en cada tarjeta
  // sería una línea que no dice nada.
  if (cifras.cargosUsd > 0) lineas.push({ clave: 'cargos', valor: cifras.cargosUsd })

  return (
    <dl
      className={`relative z-10 flex flex-col border-t border-panel-hairline ${
        grande ? 'gap-2 pt-4' : 'gap-1.5 pt-3'
      }`}
    >
      {lineas.map(({ clave, valor }) => (
        <div key={clave} className="flex items-baseline justify-between gap-2">
          <dt
            className={`flex items-center gap-1.5 text-on-surface-variant ${
              grande ? 'type-panel-body' : 'type-panel-caption'
            }`}
          >
            {ROTULOS[clave]}
            <InfoDot title={ROTULOS[clave]} what={QUE_ES[clave]} />
          </dt>
          <dd
            className={`tabular-nums text-on-surface ${
              grande ? 'type-panel-body font-semibold' : 'type-panel-label'
            }`}
          >
            {formatUsd(valor)}
          </dd>
        </div>
      ))}
    </dl>
  )
}
