import { formatDayShort, formatUsd, formatPorcentaje, sumarDias } from '@/components/ui'
import type { ParteDeFrase } from '@/components/admin/metricas/kit'
import { leerDesglose, leerHoyUsado, leerSemanaUsada } from '@/features/admin/metricas/lectura'
import type { Desglose, SemanaUsada } from '@/features/admin/metricas/lectura'
import type { FilaPrimeraCuota, PrimeraCuota } from '@/features/admin/riesgo/credito'
import { TRAMOS, sentidoDelPaso } from '@/features/admin/riesgo/flujo'
import type { SemanaDeFlujo } from '@/features/admin/riesgo/flujo'
import { TRAMOS_VENCIDOS } from '@/features/admin/tramos'
import type { CortesDeTramo, TramoVencido } from '@/features/admin/tramos'
import { comoFila, comoLista, numero, numeroONulo, texto } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// La semana de Cobranza y riesgo: lo que devuelven las RPC, leído, y las
// cuentas y frases que se pintan con ello.
//
//   admin_metricas_cobranza   la cartera al corte, la mora por tramo, el impago
//   admin_due_vs_collected    lo que vencía cada día y lo que entró de eso
//   admin_on_time_collection  el cobro a tiempo de las cuotas de la semana
//   admin_first_payment_default (por semana)  el impago de la cuota 1 y de la 2
//   admin_collection_flow     el paso entre tramos (su lectura es de Riesgo)
//
// El CORTE de la semana es el día al cierre del cual se mira la cartera: el
// domingo si la semana ya pasó, hoy si está en curso. Lo vencido y la mora de
// una semana pasada son los de su cierre, no los de hoy.
//
// Dinero: lo vencido y lo que vencía son PAYABLE (cuotas, con la Comisión Helios
// dentro) y siempre van con su desglose. Puro: se prueba en `semana.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

const CERO: Desglose = { payableUsd: 0, financedUsd: 0, feeUsd: 0 }

function desglose(v: unknown): Desglose {
  return leerDesglose(v) ?? CERO
}

/** Suma dos desgloses parte a parte (lo que vencía de dos días). */
export function sumarDesgloses(a: Desglose, b: Desglose): Desglose {
  return {
    payableUsd: a.payableUsd + b.payableUsd,
    financedUsd: a.financedUsd + b.financedUsd,
    feeUsd: a.feeUsd + b.feeUsd,
  }
}

/**
 * «Facturado $28,01 (sin comisión) · Comisión Helios + IVA $6,49»: la línea que
 * acompaña SIEMPRE a una suma de cuotas (la regla de la comisión), con las palabras
 * del vocabulario de Métricas (las mismas que Cobros y Semana › Resumen). El
 * comisión es payable − financed: lleva su IVA dentro.
 */
export function textoDelDesglose({ financedUsd, feeUsd }: Pick<Desglose, 'financedUsd' | 'feeUsd'>): string {
  return `Financiado ${formatUsd(financedUsd)} (sin comisión) · Comisión Helios + IVA ${formatUsd(feeUsd)}`
}

/** «facturado $28,01 + service fee + IVA $6,49»: el desglose dentro de una frase o entre paréntesis. */
export function desgloseEnLinea({ financedUsd, feeUsd }: Pick<Desglose, 'financedUsd' | 'feeUsd'>): string {
  return `financiado ${formatUsd(financedUsd)} + Comisión Helios + IVA ${formatUsd(feeUsd)}`
}

/** El día al cierre del cual se mira la semana: su domingo, o hoy si aún no llegó. */
export function corteDeLaSemana(domingo: string, hoy: string): string {
  return domingo < hoy ? domingo : hoy
}

// ── admin_metricas_cobranza ────────────────────────────────────────────────

export type CarteraAlCorte = {
  vencido: Desglose
  porVencer: Desglose
  perdido: Desglose
  /** Vencido ÷ (vencido + por vencer). `null` si no queda nada vivo. */
  moraPct: number | null
  cuotasVencidas: number
  personasVencidas: number
}

export type TramoAlCorte = {
  tramo: TramoVencido
  personas: number
  cuotas: number
  vencido: Desglose
  diasAtrasoMedio: number | null
}

export type ResumenDeCobranza = {
  semana: SemanaUsada | null
  hoy: string | null
  /** El día al cierre del cual se miró. */
  corte: string
  cartera: CarteraAlCorte
  /** La semana anterior a la misma altura (el mismo día de la semana). */
  anterior: { corte: string; vencido: Desglose; moraPct: number | null; personasVencidas: number }
  /** Los cortes con que la base clasificó los tramos; `null` si no vinieron. */
  cortes: CortesDeTramo | null
  /** Siempre los cuatro tramos, en orden. */
  tramos: TramoAlCorte[]
  /** Desde el primer día: no es de la semana. */
  impago: {
    perdido: Desglose
    personasPerdidas: number
    financiadoUsd: number
    pct: number | null
    empatePct: number | null
  }
  /** Lo vencido hoy, para «Para actuar»: la cola se trabaja hoy. */
  hoyVencido: { personas: number; vencido: Desglose }
}

function leerCortes(v: unknown): CortesDeTramo | null {
  const t = comoFila(v)
  const intervalo = numeroONulo(t.interval_days)
  const baja = numeroONulo(t.demotion_days)
  const expulsion = numeroONulo(t.expulsion_days)
  if (intervalo === null || baja === null || expulsion === null) return null
  return { intervalo, baja, expulsion }
}

/** La respuesta de `admin_metricas_cobranza`. */
export function leerResumenDeCobranza(raw: unknown): ResumenDeCobranza {
  const d = comoFila(raw)
  const c = comoFila(d.cartera)
  const a = comoFila(d.cartera_anterior)
  const t = comoFila(d.tramos)
  const i = comoFila(d.impago)
  const h = comoFila(d.hoy_vencido)
  const porTramo = new Map(
    comoLista(t.filas).map((v) => {
      const f = comoFila(v)
      return [texto(f.tramo), f] as const
    }),
  )
  return {
    semana: leerSemanaUsada(d.semana),
    hoy: leerHoyUsado(d.hoy),
    corte: texto(d.corte),
    cartera: {
      vencido: desglose(c.vencido),
      porVencer: desglose(c.por_vencer),
      perdido: desglose(c.perdido),
      moraPct: numeroONulo(c.mora_pct),
      cuotasVencidas: numero(c.cuotas_vencidas),
      personasVencidas: numero(c.personas_vencidas),
    },
    anterior: {
      corte: texto(a.corte),
      vencido: desglose(a.vencido),
      moraPct: numeroONulo(a.mora_pct),
      personasVencidas: numero(a.personas_vencidas),
    },
    cortes: leerCortes(t.cortes),
    // Un tramo que no vino es un tramo sin nadie: se pinta con su cero.
    tramos: TRAMOS_VENCIDOS.map((tramo) => {
      const f = comoFila(porTramo.get(tramo))
      return {
        tramo,
        personas: numero(f.personas),
        cuotas: numero(f.cuotas),
        vencido: {
          payableUsd: numero(f.payable_usd),
          financedUsd: numero(f.financed_usd),
          feeUsd: numero(f.fee_usd),
        },
        diasAtrasoMedio: numeroONulo(f.dias_atraso_medio),
      }
    }),
    impago: {
      perdido: desglose(i.perdido),
      personasPerdidas: numero(i.personas_perdidas),
      financiadoUsd: numero(i.financiado_usd),
      pct: numeroONulo(i.impago_pct),
      empatePct: numeroONulo(i.empate_pct),
    },
    hoyVencido: {
      personas: numero(h.personas),
      vencido: {
        payableUsd: numero(h.payable_usd),
        financedUsd: numero(h.financed_usd),
        feeUsd: numero(h.fee_usd),
      },
    },
  }
}

/** Las personas y lo vencido de todos los tramos juntos: lo mismo que la cartera al corte. */
export function totalDeLosTramos(tramos: ReadonlyArray<TramoAlCorte>): { personas: number; vencido: Desglose } {
  return tramos.reduce(
    (s, t) => ({ personas: s.personas + t.personas, vencido: sumarDesgloses(s.vencido, t.vencido) }),
    { personas: 0, vencido: CERO },
  )
}

// ── admin_due_vs_collected ─────────────────────────────────────────────────

export type DiaDeCobro = {
  dia: string
  /** Lo que vencía ese día (sin lo dado por perdido). */
  vencia: Desglose
  cuotas: number
  /** De lo que vencía ese día, lo que ya se pagó (antes, ese día o después). */
  entroDeEso: Desglose
  pagadas: number
  /** Lo que entró ese día, de cualquier cuota. */
  entroEseDia: Desglose
  /** El día todavía no ha llegado. */
  futuro: boolean
}

export function leerDiasDeCobro(raw: unknown): DiaDeCobro[] {
  return comoLista(raw)
    .map((v) => {
      const f = comoFila(v)
      return {
        dia: texto(f.business_date),
        vencia: { payableUsd: numero(f.due_usd), financedUsd: numero(f.due_financed_usd), feeUsd: numero(f.due_fee_usd) },
        cuotas: numero(f.due_count),
        entroDeEso: {
          payableUsd: numero(f.due_paid_usd),
          financedUsd: numero(f.due_paid_financed_usd),
          feeUsd: numero(f.due_paid_fee_usd),
        },
        pagadas: numero(f.due_paid_count),
        entroEseDia: {
          payableUsd: numero(f.collected_usd),
          financedUsd: numero(f.collected_financed_usd),
          feeUsd: numero(f.collected_fee_usd),
        },
        futuro: f.is_future === true,
      }
    })
    .sort((a, b) => a.dia.localeCompare(b.dia))
}

/** Lo que vencía en la semana hasta hoy (lo que ya pudo pagarse) y cuánto entró de eso. */
export function resumenDeLosDias(dias: ReadonlyArray<DiaDeCobro>): {
  vencia: Desglose
  entroDeEso: Desglose
  cuotas: number
  pagadas: number
  /** Sobre lo que vencía; `null` si no vencía nada. */
  pct: number | null
  /** Días de la semana que todavía no han llegado y en los que vence algo. */
  diasPorVenir: number
} {
  const pasados = dias.filter((d) => !d.futuro)
  const vencia = pasados.reduce((s, d) => sumarDesgloses(s, d.vencia), CERO)
  const entroDeEso = pasados.reduce((s, d) => sumarDesgloses(s, d.entroDeEso), CERO)
  return {
    vencia,
    entroDeEso,
    cuotas: pasados.reduce((s, d) => s + d.cuotas, 0),
    pagadas: pasados.reduce((s, d) => s + d.pagadas, 0),
    pct: vencia.payableUsd > 0 ? (entroDeEso.payableUsd / vencia.payableUsd) * 100 : null,
    diasPorVenir: dias.filter((d) => d.futuro && d.cuotas > 0).length,
  }
}

/**
 * La frase del gráfico. Lo que vencía es una suma de cuotas: va con su
 * desglose, y lo cobrado de ello como la parte que es, sin otro total. Lo
 * cobrado se mide HOY: en una semana pasada incluye lo que se pagó después.
 *
 *   «Hasta hoy vencían $342,28 en cuotas (facturado $278,00 (sin fee) ·
 *   service fee + IVA $64,28) y ya se ha cobrado el 72 %. Lo de hoy aún
 *   puede pagarse.»
 */
export function fraseDeLosDias(dias: ReadonlyArray<DiaDeCobro>, enCurso: boolean, hoy: string): ParteDeFrase[] {
  const r = resumenDeLosDias(dias)
  if (r.cuotas === 0) {
    return [
      enCurso
        ? 'Hasta hoy no vencía ninguna cuota esta semana.'
        : 'Esta semana no vencía ninguna cuota.',
    ]
  }
  const partes: ParteDeFrase[] = [
    enCurso ? 'Hasta hoy vencían ' : 'Esta semana vencían ',
    { cifra: `${formatUsd(r.vencia.payableUsd)} en cuotas` },
    ` (${desgloseEnLinea(r.vencia)}) y `,
    enCurso ? 'ya se ha cobrado ' : 'hasta hoy se ha cobrado ',
    { cifra: `el ${formatPorcentaje(r.pct ?? 0)}` },
    '.',
  ]
  const deHoy = dias.find((d) => d.dia === hoy)
  if (enCurso && deHoy && deHoy.cuotas > deHoy.pagadas) partes.push(' Lo de hoy aún puede pagarse.')
  else if (enCurso && r.diasPorVenir > 0) partes.push(' Lo que vence de aquí al domingo aún puede pagarse.')
  return partes
}

/**
 * La nota de cada día en la tabla del gráfico, con el desglose de las dos
 * cifras (las dos son sumas de cuotas): «4 de 6 cuotas pagadas · vencía
 * facturado … · cobrado facturado …».
 */
export function notaDelDia(d: DiaDeCobro): string {
  if (d.cuotas === 0) return 'No vencía nada'
  const cuotas = `${d.pagadas} de ${d.cuotas} ${d.cuotas === 1 ? 'cuota pagada' : 'cuotas pagadas'}`
  const vencia = `vencía ${desgloseEnLinea(d.vencia)}`
  if (d.pagadas === 0) return `${cuotas} · ${vencia}`
  return `${cuotas} · ${vencia} · cobrado ${desgloseEnLinea(d.entroDeEso)}`
}

// ── admin_on_time_collection ───────────────────────────────────────────────

export type CobroDeCuotas = {
  vencian: number
  aTiempo: number
  tarde: number
  sinPagar: number
  /** `null` sin cuotas que juzgar: no es un 0 %. */
  pct: number | null
}

export type CobroATiempo = {
  /** Los vencimientos que se juzgaron: puede no ser la semana entera. */
  desde: string
  hasta: string
  gracia: number
  total: CobroDeCuotas
  /** Por número de cuota, en orden. */
  cuotas: Array<CobroDeCuotas & { numero: number }>
}

function leerCobroDeCuotas(v: unknown): CobroDeCuotas {
  const f = comoFila(v)
  return {
    vencian: numero(f.due_count),
    aTiempo: numero(f.on_time_count),
    tarde: numero(f.late_count),
    sinPagar: numero(f.unpaid_count),
    pct: numeroONulo(f.rate_pct),
  }
}

export function leerCobroATiempo(raw: unknown): CobroATiempo {
  const d = comoFila(raw)
  return {
    desde: texto(d.from),
    hasta: texto(d.to),
    gracia: numero(d.grace_days),
    total: leerCobroDeCuotas(d.total),
    cuotas: Object.values(comoFila(d.installments))
      .map((v) => ({ numero: numero(comoFila(v).sequence), ...leerCobroDeCuotas(v) }))
      .sort((a, b) => a.numero - b.numero),
  }
}

/** «Cuota 1: 79 % · cuota 2: 83 %». Una cuota sin nada que juzgar no sale. */
export function pieDeCobroATiempo(c: CobroATiempo): string {
  const partes = c.cuotas
    .filter((q) => q.pct !== null)
    .map((q, i) => `${i === 0 ? 'Cuota' : 'cuota'} ${q.numero}: ${formatPorcentaje(q.pct ?? 0)}`)
  return partes.length > 0 ? partes.join(' · ') : 'Ninguna cuota ha cerrado su plazo todavía'
}

/**
 * Si lo juzgado no es la semana elegida (sus cuotas siguen en el plazo de
 * gracia), de qué días es: «Vencían del 14 al 20 sep».
 */
export function tramoJuzgado(c: CobroATiempo, lunes: string, domingo: string): string | null {
  if (c.desde === lunes && c.hasta === domingo) return null
  return `Vencían del ${formatDayShort(c.desde)} al ${formatDayShort(c.hasta)}`
}

// ── admin_first_payment_default por semana: la cuota 1 y la 2 ──────────────

/**
 * La semana de consumo cuya cuota (la 1 o la 2) ya se puede juzgar entera:
 * la más reciente que no pasa de la elegida, con alguna cuota madura y
 * ninguna todavía en la gracia. `null` si no hay ninguna. La de la cuota 2
 * suele ser una semana más vieja que la de la 1: vence una semana después.
 */
export function semanaJuzgadaDelImpago(pc: PrimeraCuota, lunes: string): FilaPrimeraCuota | null {
  const candidatas = pc.filas
    .filter((f) => f.clave <= lunes && f.enGracia === 0 && f.maduras > 0)
    .sort((a, b) => b.clave.localeCompare(a.clave))
  return candidatas[0] ?? null
}

/**
 * «12 de 61 cuotas · consumos del 7 al 13 sep, la última semana con la
 * gracia terminada»: el numerador y el denominador del porcentaje, y de qué
 * semana de consumo son.
 */
export function pieDelImpago(fila: FilaPrimeraCuota | null, lunesElegido: string): string {
  if (!fila) return 'Ninguna semana ha terminado la gracia todavía'
  const cuantas = `${fila.impagas} de ${fila.maduras} ${fila.maduras === 1 ? 'cuota' : 'cuotas'}`
  const rango = `financiamientos del ${formatDayShort(fila.clave)} al ${formatDayShort(sumarDias(fila.clave, 6))}`
  return fila.clave === lunesElegido
    ? `${cuantas} · ${rango}`
    : `${cuantas} · ${rango}, la última semana con la gracia terminada`
}

/**
 * La lectura de las dos cuotas para el globo y el lector de pantalla: «Cuota
 * 1: 12 % · cuota 2: 8 %». Una cuota sin semana juzgada dice «sin juzgar».
 */
export function comparaLasCuotas(
  impagos: ReadonlyArray<{ cuota: number; fila: FilaPrimeraCuota | null }>,
): string {
  return impagos
    .map(({ cuota, fila }, i) => {
      const valor = fila?.impagoPct == null ? 'sin juzgar' : formatPorcentaje(fila.impagoPct)
      return `${i === 0 ? 'Cuota' : 'cuota'} ${cuota}: ${valor}`
    })
    .join(' · ')
}

// ── admin_collection_flow: el paso de la semana ────────────────────────────

export type PasoDeLaSemana = {
  /** Estaban en un tramo vencido y están al día. */
  seAlDia: number
  /** Siguen en mora pero en un tramo de menos días. */
  mejoraron: number
  /** Pasaron a un tramo de más días. */
  empeoraron: number
  /** Estaban al día (o no tenían cuotas) y ahora deben algo vencido. */
  entraron: number
  /** Siguen en el mismo tramo vencido. */
  siguen: number
}

/** Las cuatro líneas del paso entre tramos, de una semana del flujo. */
export function pasoDeLaSemana(semana: SemanaDeFlujo): PasoDeLaSemana {
  const r: PasoDeLaSemana = { seAlDia: 0, mejoraron: 0, empeoraron: 0, entraron: 0, siguen: 0 }
  for (const p of semana.pasos) {
    const vencidoAntes = p.desde !== 'nuevo' && p.desde !== 'al_dia'
    const vencidoAhora = p.hacia !== 'al_dia'
    if (vencidoAntes && !vencidoAhora) r.seAlDia += p.personas
    else if (!vencidoAntes && vencidoAhora) r.entraron += p.personas
    else if (vencidoAntes && vencidoAhora) {
      const sentido = sentidoDelPaso(p.desde, p.hacia)
      if (sentido === 'mejora') r.mejoraron += p.personas
      else if (sentido === 'empeora') r.empeoraron += p.personas
      else r.siguen += p.personas
    }
  }
  return r
}

/** «Del lunes 21 a hoy», «Del lunes 14 al lunes 21». */
export function periodoDelPaso(semana: SemanaDeFlujo): string {
  const desde = semana.desde ? `Del lunes ${Number(semana.desde.slice(8, 10))}` : 'Desde el corte anterior'
  if (semana.enCurso) return `${desde} a hoy`
  return `${desde} al lunes ${Number(semana.corte.slice(8, 10))}`
}

/** Todos los tramos, del mejor al peor: el orden de la matriz. */
export const TRAMOS_DEL_PASO = TRAMOS
