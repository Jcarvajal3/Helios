import { Clock } from 'lucide-react'

import { Badge, InfoDot } from '@/components/ui'
import {
  HORA_DEL_CORTE_ESCRITA,
  diaCortoConNombre,
  duracionCorta,
  horaDeCaracas,
  hoyOperativo,
  minutosHastaElCorte,
} from './reloj'
import { useAhora } from './useAhora'

/** Desde cuántos minutos antes del corte el aviso pasa a ámbar. */
const ULTIMA_HORA = 60

/**
 * La tira de contexto de Inicio, en una línea: qué día operativo corre, qué
 * hora es en Caracas y cuánto le queda al día.
 *
 * Quien mira el panel desde otro huso, o a las 11:40 de la noche, necesita
 * las tres cosas para leer bien cualquier lista. En la última hora antes del
 * corte la cuenta atrás pasa a aviso: lo que no se haga ya cae en otro día.
 */
export function DiaOperativo() {
  const ahora = useAhora()
  const faltan = minutosHastaElCorte(ahora)
  const cierra = `El día cierra a ${HORA_DEL_CORTE_ESCRITA}`

  return (
    <header className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1.5 type-panel-label font-normal text-on-surface-variant">
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

      {faltan <= ULTIMA_HORA ? (
        <Badge tone="warning" icono={Clock}>
          {cierra} · faltan {duracionCorta(faltan)}
        </Badge>
      ) : (
        <p className="text-panel-muted">
          {cierra} · faltan {duracionCorta(faltan)}
        </p>
      )}
    </header>
  )
}
