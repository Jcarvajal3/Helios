import { useQuery } from '@tanstack/react-query'
import type { UseQueryResult } from '@tanstack/react-query'

import { consultaCuentasDeCobro, consultaTasa, consultaTasaEuro } from '@/features/admin/cobranza/consultas'
import { bloqueoDeCuenta, bloqueoDeExtracto, bloqueoDeTasa } from './bloqueos'
import type { Bloqueo } from './bloqueos'
import { consultaUltimoExtracto } from './consultas'
import type { SinComprobar } from './tarjetasDePendiente'

export type Bloqueos = {
  bloqueos: Bloqueo[]
  /** Las comprobaciones que fallaron: callarse sería dar por buena una tasa que nadie miró. */
  sinComprobar: SinComprobar[]
  /** Alguna sigue leyéndose. */
  comprobando: boolean
}

/**
 * «Bloquea la operación»: las comprobaciones de lo que, si está mal,
 * impide que la gente pague o que el equipo apruebe lo que paga. Cada
 * bloqueo lleva el sitio donde se arregla.
 */
export function useBloqueos(): Bloqueos {
  const tasa = useQuery(consultaTasa())
  const tasaEuro = useQuery(consultaTasaEuro())
  const cuentas = useQuery(consultaCuentasDeCobro())
  const extracto = useQuery(consultaUltimoExtracto())

  const bloqueos: Bloqueo[] = []
  const sinComprobar: SinComprobar[] = []

  function mirar<T>(q: UseQueryResult<T>, que: string, regla: (datos: T) => Bloqueo | null) {
    if (q.isError) sinComprobar.push({ que, reintentar: () => void q.refetch() })
    else if (q.data !== undefined) {
      const bloqueo = regla(q.data)
      if (bloqueo) bloqueos.push(bloqueo)
    }
  }

  mirar(tasa, 'La tasa BCV', (fx) => bloqueoDeTasa(fx, 'USD'))
  mirar(tasaEuro, 'La tasa BCV del euro', (fx) => bloqueoDeTasa(fx, 'EUR'))
  mirar(cuentas, 'La cuenta de cobro', bloqueoDeCuenta)
  mirar(extracto, 'La última importación del extracto', (d) => bloqueoDeExtracto(d.daysSinceLast))

  const comprobando = [tasa, tasaEuro, cuentas, extracto].some((q) => q.isPending)

  return { bloqueos, sinComprobar, comprobando }
}
