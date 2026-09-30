import { pendienteDeHoy } from './tarjetasDePendiente'
import type { Pendiente } from './tarjetasDePendiente'
import { useBloqueos } from './useBloqueos'
import { useColas } from './useColas'
import type { ColaDeInicio } from './useColas'

/**
 * Lo pendiente de hoy: los bloqueos y las colas de los cuatro equipos, ya en
 * tarjetas. Lo usan la sección de Inicio y la tira de la charla, así que las
 * dos cuentan lo mismo.
 */
export function usePendiente(): Pendiente<ColaDeInicio> {
  const { bloqueos, sinComprobar, comprobando } = useBloqueos()
  const colas = useColas()
  return pendienteDeHoy({ bloqueos, sinComprobar, comprobando, colas })
}
