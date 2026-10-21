import { formatDayShort, sumarDias } from '@/components/ui'
import { TRAMOS_VENCIDOS } from '@/features/admin/tramos'
import type { CortesDeTramo, TramoVencido } from '@/features/admin/tramos'
import { unoDe } from '@/lib/busqueda'
import { CANALES } from './gestion'
import type { Canal } from './gestion'
import { comoFila, comoLista, numero, numeroONulo, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que rinde la cobranza, leído de tres funciones de la base:
//
//   admin_collection_recovered    lo cobrado que ya estaba vencido
//   admin_collection_flow         la cura: quién pasó de un tramo a estar al día
//   admin_contact_effectiveness   las gestiones seguidas de un pago en 72 h
//
// Módulo puro. Todo monto es PAYABLE (deuda, con la Comisión Helios dentro) y el
// cargo por atraso va siempre aparte: nunca se suma a lo recuperado.
// ═══════════════════════════════════════════════════════════════════════════

// ── El periodo de la vista ─────────────────────────────────────────────────

/** Los periodos que se ofrecen. Por defecto, la semana. */
export const PERIODOS = [7, 30, 90] as const
export type Periodo = (typeof PERIODOS)[number]

/** Para `validateSearch`: uno de los periodos, o `undefined`. */
export function comoPeriodo(v: unknown): Periodo | undefined {
  const n = typeof v === 'string' && /^\d+$/.test(v) ? Number(v) : v
  return PERIODOS.find((p) => p === n)
}

/** Los `dias` días que acaban en `hasta`, los dos extremos incluidos. */
export function rangoDe(hasta: string, dias: number): { desde: string; hasta: string } {
  return { desde: sumarDias(hasta, -(dias - 1)), hasta }
}

/** Los cortes con los que la base calculó los tramos, para rotularlos igual. */
function leerCortes(raw: unknown): CortesDeTramo | null {
  const t = comoFila(raw)
  const intervalo = numeroONulo(t.interval_days)
  const baja = numeroONulo(t.demotion_days)
  const expulsion = numeroONulo(t.expulsion_days)
  if (intervalo === null || baja === null || expulsion === null) return null
  return { intervalo, baja, expulsion }
}

// ── Recuperado ─────────────────────────────────────────────────────────────

/**
 * Un montón de cuotas. `usd` es PAYABLE (lo pagado, con la Comisión Helios dentro);
 * `financedUsd` y `feeUsd` son su desglose (desde 20260927551000), para
 * enseñarlo como «Consumo € + Comisión Helios €» y nunca como un total suelto.
 */
export type Bolsa = {
  usd: number
  /** `null` si la base no lo manda: entonces no se enseña desglose, no se inventa. */
  financedUsd: number | null
  feeUsd: number | null
  cuotas: number
  personas: number
}

export type Recuperado = {
  desde: string
  hasta: string
  /** Cuotas pagadas en el rango que ya estaban vencidas al pagarse. */
  recuperado: Bolsa & { perdidoUsd: number }
  /** Cargos por atraso cobrados en el rango. Línea aparte. */
  cargosPorAtraso: { usd: number; cuantos: number }
  porTramo: Array<Bolsa & { tramo: TramoVencido }>
  vencidoAlEmpezar: Bolsa & { perdidoUsd: number }
  /** De lo vencido al empezar, lo cobrado dentro del rango. */
  recuperadoDeLoVencido: Bolsa
  /** `null` si no había nada vencido al empezar. */
  pctRecuperacion: number | null
  cortes: CortesDeTramo | null
}

function leerBolsa(raw: unknown): Bolsa {
  const b = comoFila(raw)
  const usd = numero(b.usd)
  const financedUsd = numeroONulo(b.financed_usd)
  return {
    usd,
    financedUsd,
    feeUsd: financedUsd === null ? null : (numeroONulo(b.fee_usd) ?? usd - financedUsd),
    cuotas: numero(b.installments),
    personas: numero(b.people),
  }
}

/** El desglose de una bolsa, o `null` si la base no lo mandó. */
export function desgloseDeBolsa(b: Bolsa): { payableUsd: number; financedUsd: number; feeUsd: number } | null {
  if (b.financedUsd === null || b.feeUsd === null) return null
  return { payableUsd: b.usd, financedUsd: b.financedUsd, feeUsd: b.feeUsd }
}

export function leerRecuperado(raw: unknown): Recuperado {
  const d = comoFila(raw)
  const porTramo = new Map(
    comoLista(d.by_tramo).map((f) => {
      const fila = comoFila(f)
      return [texto(fila.tramo), leerBolsa(fila)] as const
    }),
  )
  const cargos = comoFila(d.late_fees)
  return {
    desde: texto(d.from),
    hasta: texto(d.to),
    recuperado: { ...leerBolsa(d.recovered), perdidoUsd: numero(comoFila(d.recovered).written_off_usd) },
    cargosPorAtraso: { usd: numero(cargos.usd), cuantos: numero(cargos.count) },
    // Siempre los cuatro, en orden: un tramo que no vino es un tramo sin cobros.
    porTramo: TRAMOS_VENCIDOS.map((tramo) => ({
      tramo,
      ...(porTramo.get(tramo) ?? { usd: 0, financedUsd: 0, feeUsd: 0, cuotas: 0, personas: 0 }),
    })),
    vencidoAlEmpezar: {
      ...leerBolsa(d.overdue_at_start),
      perdidoUsd: numero(comoFila(d.overdue_at_start).written_off_usd),
    },
    recuperadoDeLoVencido: leerBolsa(d.recovered_from_start),
    pctRecuperacion: numeroONulo(d.recovery_pct),
    cortes: leerCortes(d.tramos),
  }
}

// ── Cura ───────────────────────────────────────────────────────────────────

/** De los que estaban en un tramo al empezar la semana, cuántos están al día al cerrarla. */
export type CuraDeTramo = { estaban: number; curados: number; pct: number | null }

export type SemanaDeCura = {
  /** El día del corte, 'YYYY-MM-DD': el lunes siguiente a la semana, o hoy si está en curso. */
  corte: string
  /** El lunes en que empieza la semana medida; `null` si la base no lo manda. */
  desde: string | null
  /** El último día operativo de la semana medida (su domingo, o hoy); `null` si no viene. */
  cierre: string | null
  enCurso: boolean
  porTramo: Record<TramoVencido, CuraDeTramo>
}

export type Cura = { semanas: SemanaDeCura[]; cortes: CortesDeTramo | null }

function leerCuraDeTramo(raw: unknown): CuraDeTramo {
  const c = comoFila(raw)
  return { estaban: numero(c.from_people), curados: numero(c.cured), pct: numeroONulo(c.pct) }
}

/** Solo la cura: el flujo completo entre tramos lo pinta Riesgo. */
export function leerCura(raw: unknown): Cura {
  const d = comoFila(raw)
  return {
    semanas: comoLista(d.weeks).map((w) => {
      const semana = comoFila(w)
      const cura = comoFila(semana.cure)
      return {
        corte: texto(semana.cut_date),
        desde: textoONulo(semana.from_date),
        cierre: textoONulo(semana.cierre),
        enCurso: semana.en_curso === true,
        porTramo: {
          t1: leerCuraDeTramo(cura.t1),
          t2: leerCuraDeTramo(cura.t2),
          t3: leerCuraDeTramo(cura.t3),
          t4: leerCuraDeTramo(cura.t4),
        },
      }
    }),
    cortes: leerCortes(d.tramos),
  }
}

/**
 * «Del 14 sep al 20 sep», «Del 21 sep a hoy»: la semana que mide la cura, de
 * su lunes a su cierre. No se rotula con el día del corte: el de una semana
 * pasada es el lunes SIGUIENTE, y diría una semana que no es la elegida.
 */
export function periodoDeLaCura(s: Pick<SemanaDeCura, 'desde' | 'cierre' | 'corte' | 'enCurso'>): string {
  const hasta = s.enCurso ? 'hoy' : formatDayShort(s.cierre ?? s.corte)
  if (!s.desde) return `Hasta ${hasta}`
  return `Del ${formatDayShort(s.desde)} ${s.enCurso ? 'a' : 'al'} ${hasta}`
}

// ── Efectividad ────────────────────────────────────────────────────────────

/**
 * `pct` se calcula solo sobre las gestiones cuya ventana de 72 h ya cerró;
 * `enVentana` son las que todavía pueden acabar con un pago.
 */
export type Efectividad = {
  gestiones: number
  conPago: number
  enVentana: number
  pct: number | null
}

export type EfectividadDeCobranza = {
  desde: string
  hasta: string
  horas: number
  total: Efectividad
  porCanal: Array<Efectividad & { canal: Canal }>
  /** Siempre 24, de 0 a 23, en hora de Caracas. */
  porHora: Array<Efectividad & { hora: number }>
}

function leerEfectividad(raw: unknown): Efectividad {
  const e = comoFila(raw)
  return {
    gestiones: numero(e.contacts),
    conPago: numero(e.with_payment),
    enVentana: numero(e.open_window),
    pct: numeroONulo(e.rate_pct),
  }
}

export function leerEfectividadDeCobranza(raw: unknown): EfectividadDeCobranza {
  const d = comoFila(raw)
  const horas = new Map(
    comoLista(d.by_hour).map((f) => {
      const fila = comoFila(f)
      return [numero(fila.hour), leerEfectividad(fila)] as const
    }),
  )
  return {
    desde: texto(d.from),
    hasta: texto(d.to),
    horas: numero(d.window_hours),
    total: leerEfectividad(d.total),
    porCanal: comoLista(d.by_channel).flatMap((f) => {
      const fila = comoFila(f)
      const canal = unoDe(CANALES, fila.key)
      return canal ? [{ canal, ...leerEfectividad(fila) }] : []
    }),
    porHora: Array.from({ length: 24 }, (_, hora) => ({
      hora,
      ...(horas.get(hora) ?? { gestiones: 0, conPago: 0, enVentana: 0, pct: null }),
    })),
  }
}
