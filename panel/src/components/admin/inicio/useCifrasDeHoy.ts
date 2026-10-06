import { useQuery } from '@tanstack/react-query'

import { estadoDeConsultas } from '@/components/ui'
import type { PuntoDeMiniBarras } from '@/components/charts'
import { consultaCartera, fetchCollections } from '@/features/admin/cobranza/consultas'
import { payablesTotals } from '@/features/admin/definitions'
import { elegirSemana } from '@/features/admin/semana'
import { umbralImpago, umbralMora } from '@/features/admin/umbrales'
import { useParametros } from '@/features/admin/useParametros'
import { barrasDeLaSemana, deudaVencida, impagoPrimeraCuota } from './cifras'
import type { DeudaVencida, ImpagoPrimeraCuota, LecturaDeCifra } from './cifras'
import {
  consultaCaja,
  consultaDeudaConLocales,
  consultaPrimeraCuotaPorMes,
  consultaSemanas,
  consultaSerieDiaria,
} from './consultas'
import { diasAlCierre, horizonteDelCierre, sumarCartera, veredictoDelCierre } from './numeros'
import type { VeredictoDelCierre } from './numeros'

// ═══════════════════════════════════════════════════════════════════════════
// Las lecturas de «Hoy en cifras» y de la tira de la charla.
//
// Son las MISMAS consultas que usaban los bloques de «Tus números», con sus
// claves: entrar desde Inicio a la pantalla del área no vuelve a consultar.
// Una cifra que sale de varias consultas no se da si falla cualquiera.
// ═══════════════════════════════════════════════════════════════════════════

type Consulta = { isError: boolean; isLoading: boolean; refetch: () => Promise<unknown> }

/** La cifra de unas consultas: el fallo manda sobre la carga, y la carga sobre el dato. */
function leer<T>(consultas: ReadonlyArray<Consulta>, armar: () => T | undefined): LecturaDeCifra<T> {
  const estado = estadoDeConsultas(consultas)
  if (estado === 'error') {
    return {
      estado: 'error',
      reintentar: () => {
        for (const c of consultas) if (c.isError) void c.refetch()
      },
    }
  }
  const datos = estado === 'listo' ? armar() : undefined
  return datos === undefined ? { estado: 'cargando' } : { estado: 'listo', datos }
}

// ── Cobranza ───────────────────────────────────────────────────────────────

export type DeudaDeHoy = DeudaVencida & {
  /**
   * Los usuarios con algo vencido: los de ESE importe, de la misma fila de la
   * semana (sin lo dado por perdido). `null` si la base no los manda.
   */
  usuarios: number | null
}

/**
 * Lo vencido hoy, con su mora y la deuda viva, de la semana en curso del
 * Resumen. `null` si el servidor no devolvió ninguna semana.
 *
 * La gente sale de la misma fila que el importe. Antes salía de la cola de
 * Por cobrar, que cuenta también a quien solo debe deuda dada por perdida: en
 * dev, €777,73 «de 46 personas» cuando eran 44.
 */
export function useDeudaVencida(): LecturaDeCifra<DeudaDeHoy | null> {
  const semanal = useQuery(consultaSemanas())
  const parametros = useParametros()

  return leer([semanal, parametros], () => {
    if (!semanal.data) return undefined
    const eleccion = elegirSemana(semanal.data.rows)
    if (eleccion.tipo !== 'semana') return null
    return {
      ...deudaVencida(eleccion.semana, umbralMora(parametros.data)),
      usuarios: eleccion.semana.overdueUsers ?? null,
    }
  })
}

// ── Caja ───────────────────────────────────────────────────────────────────

export type CierreDeHoy = {
  fechaCierre: string | null
  /** Lo que sale hacia las clínicas en el próximo pago (hoy), atrasados incluidos. */
  salen: number
  /** La caja según el libro. */
  caja: number
  veredicto: VeredictoDelCierre
}

/**
 * El próximo pago a las clínicas: lo que sale, la caja y si alcanza.
 *
 * Desde el 2026-10-06 se les paga a diario (cada liquidación, el día
 * siguiente a su vencimiento) y el próximo pago es hoy: se compara la caja de
 * hoy con lo que sale hoy y cuenta la cartera de la semana. Si el servidor
 * mandara un pago futuro, las cuotas que cuentan serían las que vencen hasta
 * su víspera.
 */
export function useCierreDeHoy(hoy: string): LecturaDeCifra<CierreDeHoy> {
  const locales = useQuery(consultaDeudaConLocales())
  const caja = useQuery(consultaCaja())
  const semana = useQuery(consultaCartera())

  const totales = payablesTotals(locales.data)
  const dias = diasAlCierre(hoy, totales.fechaCierre)
  const horizonte = horizonteDelCierre(dias)

  // Misma clave que la cartera cuando el horizonte coincide: una sola llamada.
  const antesDelCierre = useQuery({
    queryKey: ['admin-collections', horizonte],
    queryFn: () => fetchCollections(horizonte ?? 0),
    enabled: horizonte !== null,
  })
  const cuotas = horizonte !== null ? antesDelCierre : semana

  return leer([locales, caja, cuotas], () => {
    if (!locales.data || !caja.data || !cuotas.data) return undefined
    const salen = totales.saleEsteCierre
    return {
      fechaCierre: totales.fechaCierre,
      salen,
      caja: caja.data.cash,
      veredicto: veredictoDelCierre({
        salen,
        caja: caja.data.cash,
        dias,
        porVencer: sumarCartera(antesDelCierre.data?.rows, 'upcomingUsd'),
        vencido: sumarCartera(cuotas.data.rows, 'overdueUsd'),
      }),
    }
  })
}

// ── Riesgo ─────────────────────────────────────────────────────────────────

/** El impago de la cuota 1 del último mes maduro, como Métricas › Cobros › Impago por cuota partido por mes. */
export function useImpagoPrimeraCuota(): LecturaDeCifra<ImpagoPrimeraCuota> {
  const primeraCuota = useQuery(consultaPrimeraCuotaPorMes())
  const parametros = useParametros()

  return leer([primeraCuota, parametros], () =>
    primeraCuota.data
      ? impagoPrimeraCuota(primeraCuota.data.filas, umbralImpago(parametros.data))
      : undefined,
  )
}

// ── Gerencia ───────────────────────────────────────────────────────────────

export type FinanciadoDeLaSemana = {
  /** Lo facturado en la semana: el consumo en los locales, sin el service fee. */
  financiado: number
  consumos: number
  lunes: string
  /** Los consumos de cada día, de lunes a domingo. `null` si la serie no se pudo leer. */
  barras: PuntoDeMiniBarras[] | null
}

/**
 * Lo facturado esta semana (sin fee), de lunes a hoy por día operativo, con
 * los consumos de cada día. `null` si el servidor no devolvió ninguna semana.
 */
export function useFinanciadoDeLaSemana(): LecturaDeCifra<FinanciadoDeLaSemana | null> {
  const semanal = useQuery(consultaSemanas())
  const serie = useQuery(consultaSerieDiaria())

  return leer([semanal], () => {
    if (!semanal.data) return undefined
    const eleccion = elegirSemana(semanal.data.rows)
    if (eleccion.tipo !== 'semana') return null
    const s = eleccion.semana
    return {
      financiado: s.financedUsd,
      consumos: s.chargeCount,
      lunes: s.weekStart,
      // Sin la serie la cifra sigue valiendo; lo que no se dibuja son barras a cero.
      barras: serie.data ? barrasDeLaSemana(s.weekStart, semanal.data.businessDate, serie.data) : null,
    }
  })
}
