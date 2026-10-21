import { Clock } from 'lucide-react'

import { InfoDot } from '@/components/ui'
import { diaCortoConNombre, horaDeCaracas, hoyOperativo } from './reloj'
import { useAhora } from './useAhora'

/**
 * La tira de contexto de Inicio, en una línea: qué día operativo corre y qué
 * hora es en Caracas, para quien mira el panel desde otro huso.
 *
 * Sin cuenta atrás: existía por el corte de las 10 AM de Ronda, cuando la
 * madrugada era de la noche anterior. En Helios el día cambia a medianoche,
 * como el de todo el mundo.
 */
export function DiaOperativo() {
  const ahora = useAhora()

  return (
    <header className="flex flex-wrap items-center gap-x-4 gap-y-1.5 type-panel-label font-normal text-on-surface-variant">
      <p className="inline-flex flex-wrap items-center gap-x-1.5">
        <Clock size={15} aria-hidden className="shrink-0" />
        <strong className="font-semibold text-on-surface">{diaCortoConNombre(hoyOperativo(ahora))}</strong>
        <span aria-hidden>·</span>
        <span className="inline-flex items-center gap-1">
          día operativo
          <InfoDot
            title="Día operativo"
            what="El día de Helios va de medianoche a medianoche en Caracas. El dinero y las listas se cuentan por día operativo."
          />
        </span>
        <span aria-hidden>·</span>
        <span>{horaDeCaracas(ahora)}</span>
      </p>
    </header>
  )
}
