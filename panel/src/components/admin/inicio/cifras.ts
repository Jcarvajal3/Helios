import { formatUsd, formatNumero, formatPct, sumarDias } from '@/components/ui'
import type { SenalDeCifra } from '@/components/ui'
import type { ContenidoDelGlobo, PuntoDeMiniBarras } from '@/components/charts'
import { MESES_CORTOS } from '@/components/kit/rango'
import type { DayPoint } from '@/features/admin/metrics'
import { textoDeDesgloseCorto } from '@/features/admin/metricas/formato'
import type { SemanaResumen } from '@/features/admin/resumen'
import type { FilaPrimeraCuota } from '@/features/admin/riesgo/credito'
import { diaDeLaSemana } from '@/features/admin/semana'
import { senalPorUmbral } from '@/features/admin/umbrales'
import type { Umbral } from '@/features/admin/umbrales'
import { ultimoMesMaduro } from './numeros'
import type { VeredictoDelCierre } from './numeros'

// ═══════════════════════════════════════════════════════════════════════════
// «Hoy en cifras»: lo que enseña cada una de las cuatro tarjetas de área, a
// partir de lo que ya leen sus pantallas. Sin React ni Supabase.
//
// Ninguna cifra nace aquí: se elige cuál se enseña y qué pastilla lleva, y la
// pastilla solo sale cuando la cifra cruza un umbral de `business_parameters`.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Una cifra leída de una o varias consultas: cargando, sin leer (con cómo
 * reintentarlo) o lista. Nunca un cero en lugar de un fallo.
 */
export type LecturaDeCifra<T> =
  | { estado: 'cargando' }
  | { estado: 'error'; reintentar: () => void }
  | { estado: 'listo'; datos: T }

/** Un umbral como se escribe en su pastilla: '7 %', y '7,5 %' si lleva decimales. */
export function porcentajeDeUmbral(n: number): string {
  return `${formatNumero(n, Number.isInteger(n) ? 0 : 1)} %`
}

/** '1 usuario', '3 usuarios'. */
export function contar(n: number, singular: string, plural: string): string {
  return `${n} ${n === 1 ? singular : plural}`
}

// ── Cobranza ───────────────────────────────────────────────────────────────

/** Las dos partes de una deuda: el consumo (sin fee) y el service fee (con su IVA). */
export type Desglose = { financedUsd: number; feeUsd: number }

/**
 * El desglose de una deuda, solo si la base lo manda y suma la cifra que se
 * enseña (a un céntimo): uno que no cuadra es peor que ninguno.
 */
export function desgloseQueSuma(
  financedUsd: number | null | undefined,
  feeUsd: number | null | undefined,
  total: number,
): Desglose | null {
  if (financedUsd == null || feeUsd == null) return null
  return Math.abs(financedUsd + feeUsd - total) < 0.01 ? { financedUsd, feeUsd } : null
}

export type DeudaVencida = {
  /** Lo vencido y sin pagar, con el service fee dentro: lo que se debe. */
  vencido: number
  /** Lo vencido en sus dos partes. `null` si la base no lo manda. */
  desgloseVencido: Desglose | null
  /** La deuda viva: lo que falta por cobrar, vencido o no. */
  porCobrar: number
  desglosePorCobrar: Desglose | null
  /** Qué parte de lo que está por cobrar ya venció. `null` sin deuda viva. */
  moraPct: number | null
  /**
   * «Mora 7,8 %»: la tasa se enseña siempre, y lleva el color de su umbral
   * solo cuando lo cruza. Sin deuda viva no hay tasa, ni pastilla.
   */
  senal: SenalDeCifra | undefined
}

/**
 * La deuda vencida de la semana en curso, con su mora. Son las cifras de «Esta
 * semana» del Resumen: vencido, deuda viva y mora salen de la misma fila y no
 * pueden contradecirse. Las dos van con el service fee dentro: son deuda.
 */
export function deudaVencida(
  semana: Pick<
    SemanaResumen,
    | 'overdueDebtUsd'
    | 'openDebtUsd'
    | 'overduePct'
    | 'overdueFinancedUsd'
    | 'overdueFeeUsd'
    | 'openFinancedUsd'
    | 'openFeeUsd'
  >,
  umbral: Umbral | null,
): DeudaVencida {
  const pct = semana.overduePct
  return {
    vencido: semana.overdueDebtUsd,
    desgloseVencido: desgloseQueSuma(semana.overdueFinancedUsd, semana.overdueFeeUsd, semana.overdueDebtUsd),
    porCobrar: semana.openDebtUsd,
    desglosePorCobrar: desgloseQueSuma(semana.openFinancedUsd, semana.openFeeUsd, semana.openDebtUsd),
    moraPct: pct,
    senal:
      pct === null
        ? undefined
        : {
            tone: senalPorUmbral(pct, umbral, porcentajeDeUmbral)?.tone ?? 'neutral',
            texto: `Mora ${formatPct(pct)}`,
          },
  }
}

/**
 * El pie de la tarjeta: lo vencido partido en consumo y fee, y los usuarios
 * que lo deben («consumo €631,17 · fee €146,56 · 44 usuarios»). Lo que se
 * debe en total no va aquí sin sus dos partes: va en el globo del medidor,
 * con las suyas. `null` si no hay nada que decir.
 */
export function pieDeDeudaVencida(d: Pick<DeudaVencida, 'desgloseVencido'>, usuarios: number | null): string | null {
  const partes = [
    d.desgloseVencido ? textoDeDesgloseCorto(d.desgloseVencido) : null,
    usuarios === null ? null : contar(usuarios, 'paciente', 'pacientes'),
  ].filter((p): p is string => p !== null)
  return partes.length > 0 ? partes.join(' · ') : null
}

/**
 * El globo del medidor: lo vencido frente a lo que queda por cobrar, cada uno
 * con sus dos partes. `color` es el del relleno del medidor.
 */
export function globoDeDeudaVencida(
  d: Pick<DeudaVencida, 'vencido' | 'desgloseVencido' | 'porCobrar' | 'desglosePorCobrar'>,
  color: string,
): ContenidoDelGlobo {
  const partes = (x: Desglose | null) => (x ? ` · ${textoDeDesgloseCorto(x)}` : '')
  return {
    titulo: 'Vencido frente a la deuda viva, financiamiento + comisión',
    filas: [
      { key: 'vencido', rotulo: `vencido${partes(d.desgloseVencido)}`, valor: formatUsd(d.vencido), color, forma: 'punto' },
      {
        key: 'por-cobrar',
        rotulo: `vencido + por vencer${partes(d.desglosePorCobrar)}`,
        valor: formatUsd(d.porCobrar),
        color: 'var(--color-panel-muted)',
        forma: 'punto',
      },
    ],
  }
}

// ── Caja ───────────────────────────────────────────────────────────────────

/**
 * La pastilla del pago a las clínicas. Solo es roja cuando hay que hacer algo:
 * «en camino» no es un aviso. Con el pago diario casi no sale: el pago que
 * viene es siempre hoy.
 */
export function senalDelCierre(veredicto: VeredictoDelCierre): SenalDeCifra {
  switch (veredicto) {
    case 'cubre':
      return { tone: 'success', texto: 'Cubre' }
    case 'en_camino':
      return { tone: 'neutral', texto: 'En camino' }
    case 'urgente':
      return { tone: 'error', texto: 'No cubre' }
  }
}

/** El día del pago, con su nombre: '2026-09-28' → 'lunes 28'. */
export function diaDelCierre(fecha: string): string {
  return `${diaDeLaSemana(fecha)} ${Number(fecha.slice(8, 10))}`
}

/**
 * El medidor de lo que sale frente a la caja: cuánto de la caja se va en el
 * pago de hoy. Si sale más de lo que hay, la barra se llena entera; con la caja en
 * cero o negativa también, porque todo lo que sale falta.
 */
export function medidorDelCierre(salen: number, caja: number): { valor: number; max: number } {
  if (salen <= 0) return { valor: 0, max: 1 }
  return caja <= 0 ? { valor: 1, max: 1 } : { valor: Math.min(salen, caja), max: caja }
}

// ── Riesgo ─────────────────────────────────────────────────────────────────

export type ImpagoPrimeraCuota = {
  /** El último mes de consumo con todas sus cuotas 1 fuera de la gracia, o `null`. */
  mes: FilaPrimeraCuota | null
  /** De 0 a 100, sobre cuotas. `null` sin mes maduro. */
  pct: number | null
  senal: SenalDeCifra | undefined
}

/** El impago de la cuota 1 del último mes maduro, con su pastilla. */
export function impagoPrimeraCuota(
  filas: ReadonlyArray<FilaPrimeraCuota>,
  umbral: Umbral | null,
): ImpagoPrimeraCuota {
  const mes = ultimoMesMaduro(filas)
  const pct = mes?.impagoPct ?? null
  return { mes, pct, senal: senalPorUmbral(pct, umbral, porcentajeDeUmbral) }
}

// ── Gerencia ───────────────────────────────────────────────────────────────

const INICIALES = ['L', 'M', 'X', 'J', 'V', 'S', 'D']

/**
 * La semana de lunes a domingo en barras: los consumos de cada día. Un día que
 * todavía no llegó va en `null` (una marca tenue), y uno pasado sin consumos,
 * en 0: no son lo mismo.
 */
export function barrasDeLaSemana(
  lunes: string,
  hoy: string,
  serie: ReadonlyArray<Pick<DayPoint, 'businessDate' | 'chargeCount'>>,
): PuntoDeMiniBarras[] {
  return INICIALES.map((rotulo, i) => {
    const dia = sumarDias(lunes, i)
    const punto = serie.find((p) => p.businessDate.slice(0, 10) === dia)
    return {
      rotulo,
      // El nombre entero va en el globo: «X» sola no dice qué día es.
      titulo: `${diaDeLaSemana(dia)} ${Number(dia.slice(8, 10))}`,
      valor: dia > hoy ? null : (punto?.chargeCount ?? 0),
      destacado: dia === hoy,
    }
  })
}

/** 'Semana del 21 al 27 sep', o 'Semana del 28 sep al 4 oct' si cambia de mes. */
export function semanaCorta(lunes: string): string {
  const domingo = sumarDias(lunes, 6)
  const mes = (dia: string) => MESES_CORTOS[Number(dia.slice(5, 7)) - 1] ?? dia.slice(5, 7)
  const numero = (dia: string) => Number(dia.slice(8, 10))
  return mes(lunes) === mes(domingo)
    ? `Semana del ${numero(lunes)} al ${numero(domingo)} ${mes(domingo)}`
    : `Semana del ${numero(lunes)} ${mes(lunes)} al ${numero(domingo)} ${mes(domingo)}`
}
