import { MESES_LARGOS, sumarDias } from '@/components/ui'
import type { ChartSeries, LinePoint } from '@/components/charts'
import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Las cosechas: lo que se financió cada mes y en qué acabó.
//
// Dos lecturas de la misma idea. La tabla (`admin_credit_cohorts`) dice cómo
// va cada cosecha HOY; las curvas (`admin_cohort_curves`) dicen cómo iba a la
// misma edad, que es lo único que permite comparar un mes joven con uno viejo.
//
// Todos los montos son consumo (financed), sin el service fee. La tasa
// de mora es deuda sobre deuda y la de impago, consumo sobre consumo: ninguna
// mezcla clases (20260925121000).
// ═══════════════════════════════════════════════════════════════════════════

/** `2026-09` → `sep 2026`. Sin `Date`: un `YYYY-MM` no tiene huso. */
export function rotuloDeMes(mes: string): string {
  const [anio = '', m = ''] = mes.split('-')
  const nombre = MESES_LARGOS[Number(m) - 1]
  return nombre ? `${nombre.slice(0, 3)} ${anio}` : mes
}

/** El primer y el último día de un mes `YYYY-MM`, para filtrar una lista por él. */
export function rangoDelMes(mes: string): { desde: string; hasta: string } {
  const [anio = 0, m = 1] = mes.split('-').map(Number)
  const siguiente = m === 12 ? `${anio + 1}-01-01` : `${anio}-${String(m + 1).padStart(2, '0')}-01`
  return { desde: `${mes}-01`, hasta: sumarDias(siguiente, -1) }
}

// ── La tabla ───────────────────────────────────────────────────────────────

export type Cosecha = {
  /** `YYYY-MM` del día operativo del consumo. */
  mes: string
  consumos: number
  /** Personas con alguna cuota en la cosecha. `null` si la base aún no lo manda. */
  personas: number | null
  /** Consumo financiado, sin el service fee. `null` si la base aún no lo manda. */
  financiado: number | null
  cobrado: number | null
  /** Vencido y todavía cobrable, en consumo. */
  enMora: number | null
  perdido: number | null
  /** Deuda vencida sobre deuda: la mora de la cosecha. */
  moraPct: number | null
  /** Consumo dado por perdido sobre consumo: el impago. */
  impagoPct: number | null
  /** Ya recorrió la escalera entera: su impago es definitivo. */
  madura: boolean
}

export type Cosechas = {
  businessDate: string
  meses: number
  /** Días que tarda una cosecha en tener su número final. */
  diasDeTemporada: number
  filas: Cosecha[]
}

function leerCosecha(raw: unknown): Cosecha {
  const f = comoFila(raw)
  // La base deja `overdue_pct` en null cuando no hay nada vencido (la suma
  // filtrada no tiene filas), aunque la cosecha sí tenga deuda. Con deuda
  // detrás, eso es un 0 % de verdad; sin deuda, «sin dato».
  const deuda = numeroONulo(f.billed_debt_usd) ?? numeroONulo(f.financed_usd) ?? 0
  const moraPct = numeroONulo(f.overdue_pct) ?? (deuda > 0 ? 0 : null)
  return {
    mes: String(f.month),
    consumos: Number(f.charge_count ?? 0),
    personas: numeroONulo(f.people_count),
    financiado: numeroONulo(f.financed_volume_usd),
    cobrado: numeroONulo(f.paid_financed_usd),
    enMora: numeroONulo(f.overdue_financed_usd),
    perdido: numeroONulo(f.written_off_financed_usd),
    moraPct,
    impagoPct: numeroONulo(f.written_off_financed_pct),
    madura: f.matured === true,
  }
}

/** La respuesta de `admin_credit_cohorts`, ya tipada. */
export function leerCosechas(raw: unknown): Cosechas {
  const f = comoFila(raw)
  return {
    businessDate: textoONulo(f.business_date) ?? '',
    meses: Number(f.months ?? 0),
    diasDeTemporada: Number(f.season_days ?? 0),
    filas: comoLista(f.rows).map(leerCosecha),
  }
}

// ── Las curvas ─────────────────────────────────────────────────────────────

export type PuntoDeCurva = {
  /** Semanas de edad, desde 1. */
  semana: number
  /** Consumo que ya cumplió esa edad: el denominador. */
  alcanzado: number
  vencidoPct: number | null
  perdidoPct: number | null
  /** Todos los consumos de la cosecha cumplieron esa edad. */
  completa: boolean
}

export type CurvaDeCosecha = {
  mes: string
  financiado: number
  consumos: number
  ultimoDia: string
  puntos: PuntoDeCurva[]
}

export type CurvasDeCosecha = {
  businessDate: string
  /** El mes más reciente primero. */
  cosechas: CurvaDeCosecha[]
}

function leerPunto(raw: unknown): PuntoDeCurva {
  const f = comoFila(raw)
  return {
    semana: Number(f.week),
    alcanzado: Number(f.reached_financed_usd ?? 0),
    vencidoPct: numeroONulo(f.overdue_pct),
    perdidoPct: numeroONulo(f.written_off_pct),
    completa: f.complete === true,
  }
}

/** La respuesta de `admin_cohort_curves`, ya tipada. */
export function leerCurvas(raw: unknown): CurvasDeCosecha {
  const f = comoFila(raw)
  return {
    businessDate: textoONulo(f.business_date) ?? '',
    cosechas: comoLista(f.rows).map((r) => {
      const c = comoFila(r)
      return {
        mes: String(c.month),
        financiado: Number(c.financed_usd ?? 0),
        consumos: Number(c.charge_count ?? 0),
        ultimoDia: String(c.last_day),
        puntos: comoLista(c.curve).map(leerPunto),
      }
    }),
  }
}

export type MedidaDeCurva = 'vencido' | 'perdido'

/**
 * Si la cosecha todavía puede cambiar: su último consumo no ha recorrido la
 * temporada entera. Sin la temporada, se mira si su última semana está a medias.
 */
export function cosechaEnCurso(
  c: CurvaDeCosecha,
  hoy: string,
  diasDeTemporada: number | null,
): boolean {
  if (diasDeTemporada !== null && diasDeTemporada > 0) {
    return sumarDias(c.ultimoDia, diasDeTemporada) > hoy
  }
  const ultimo = c.puntos.at(-1)
  return !ultimo || !ultimo.completa
}

/**
 * Las curvas listas para `LineChart`: una serie por cosecha y la edad en
 * semanas en el eje.
 *
 * Solo entran los puntos COMPLETOS: una semana que no han cumplido todos los
 * consumos da el porcentaje de una parte de la cosecha, y dibujado junto a
 * los demás parece una mejora que no es. La línea se corta ahí.
 *
 * Como mucho `tope` cosechas, las más recientes con algún punto; la más
 * nueva va la última, que es la protagonista del gráfico.
 */
export function seriesDeCurvas(
  curvas: CurvasDeCosecha,
  medida: MedidaDeCurva,
  opciones: { tope?: number; diasDeTemporada?: number | null } = {},
): { series: ChartSeries[]; points: LinePoint[]; enCurso: string[] } {
  const tope = opciones.tope ?? 4
  const elegidas = curvas.cosechas
    .filter((c) => c.puntos.some((p) => p.completa))
    .slice(0, tope)
    .reverse()

  const ultimaSemana = Math.max(
    0,
    ...elegidas.flatMap((c) => c.puntos.filter((p) => p.completa).map((p) => p.semana)),
  )

  const enCurso = elegidas
    .filter((c) => cosechaEnCurso(c, curvas.businessDate, opciones.diasDeTemporada ?? null))
    .map((c) => c.mes)

  const series: ChartSeries[] = elegidas.map((c) => ({
    key: c.mes,
    label: enCurso.includes(c.mes) ? `${rotuloDeMes(c.mes)} (en curso)` : rotuloDeMes(c.mes),
  }))

  const points: LinePoint[] = []
  for (let semana = 1; semana <= ultimaSemana; semana++) {
    points.push({
      key: `s${semana}`,
      label: `Semana ${semana}`,
      values: elegidas.map((c) => {
        const p = c.puntos.find((x) => x.semana === semana)
        if (!p || !p.completa) return null
        return medida === 'vencido' ? p.vencidoPct : p.perdidoPct
      }),
    })
  }

  return { series, points, enCurso }
}
