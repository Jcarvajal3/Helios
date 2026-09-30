import { formatPorcentaje, sumarDias } from '@/components/ui'
import type { Desglose } from '@/features/admin/metricas/lectura'
import { ESTADOS_DE_CUOTA } from './tipos'
import type { Cobro, Cohorte, CuotaDeCohorte, EstadoDeCuota, NumeroDeCuota } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// En qué está una semana y cada una de sus cuotas: la pastilla de la lista,
// la de cada tarjeta de cuota y los tramos de sus barras.
//
// Todo en lo que se COBRA (payable): la pastilla de la SEMANA mira lo que hay
// que cobrar de ella (la cuota 1 + la 2); la de una CUOTA, lo que se cobra en
// esa cuota. «11 % vencido» es la parte de ese total que está vencida.
//
// Puro: se prueba en `estados.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** El tono de una pastilla (los de `Badge`). */
export type TonoDePastilla = 'neutral' | 'warning' | 'success' | 'error'

export type Pastilla = { texto: string; tono: TonoDePastilla }

/** Cómo se llama cada estado de una cuota, en el orden en que se pinta. */
export const ROTULO_DE_ESTADO: Record<EstadoDeCuota, string> = {
  a_tiempo: 'Cobrado a tiempo',
  tarde: 'Cobrado con atraso',
  vencida: 'Vencido',
  por_vencer: 'Por vencer',
  perdida: 'Perdido',
}

/** Qué es cada estado, en una frase (va a las ayudas). */
export const QUE_ES_EL_ESTADO: Record<EstadoDeCuota, string> = {
  a_tiempo: 'pagada con un pago reportado, como tarde, el último día de gracia (vencimiento + días de gracia, por día operativo del reporte)',
  tarde: 'pagada con un pago reportado después de la gracia',
  vencida: 'sin pagar, con el vencimiento ya pasado (también dentro de la gracia) y sin dar por perdida',
  por_vencer: 'sin pagar y con el vencimiento todavía por llegar',
  perdida: 'sin pagar y dada por perdida',
}

/** Los cinco estados explicados en un solo texto, para un `InfoDot`. */
export function queEsCadaEstado(): string {
  return ESTADOS_DE_CUOTA.map((e) => `${ROTULO_DE_ESTADO[e]}: ${QUE_ES_EL_ESTADO[e]}.`).join(' ')
}

/**
 * Un porcentaje corto para una pastilla: con un decimal por debajo del 10 %
 * («5,5 %») y sin él por encima («14 %»). Lo que no llega a una décima no se
 * redondea a cero: un vencido de verdad no puede decir «0,0 %».
 */
export function pctCorto(p: number): string {
  if (p > 0 && p < 0.05) return 'menos del 0,1 %'
  return formatPorcentaje(p, p < 10 ? 1 : 0)
}

function parte(valor: number, total: number): number {
  return total > 0 ? (valor / total) * 100 : 0
}

/** La cuota N de una cohorte, si la tiene. */
export function cuotaDe(c: Cohorte, n: NumeroDeCuota): CuotaDeCohorte | null {
  return c.cuotas.find((q) => q.numero === n) ?? null
}

/**
 * Todavía no ha vencido nada de esto: ni una cuota de la tanda (o, en el
 * total, ninguna de las dos). Sin vencimiento (una semana sin cuotas), no.
 */
export function aunNoVence(q: { venceDesde: string | null }, hoy: string): boolean {
  return q.venceDesde !== null && q.venceDesde > hoy
}

/**
 * En qué está lo que se cobra en algo (una cuota, o lo que hay que cobrar de
 * una semana): si aún no vence, si queda algo vencido (en % de lo que se
 * cobra), si sigue en curso, si se dio algo por perdido o si está cobrado.
 */
export function pastillaDeCobro(q: Cobro & { venceDesde: string | null }, hoy: string): Pastilla {
  const total = q.importe.payableUsd
  if (aunNoVence(q, hoy)) return { texto: 'Aún no vence', tono: 'neutral' }
  const vencido = q.estados.vencida.importe.payableUsd
  if (vencido > 0) return { texto: `${pctCorto(parte(vencido, total))} vencido`, tono: 'warning' }
  if (q.estados.por_vencer.importe.payableUsd > 0) return { texto: 'En curso', tono: 'neutral' }
  const perdido = q.estados.perdida.importe.payableUsd
  if (perdido > 0) return { texto: `${pctCorto(parte(perdido, total))} perdido`, tono: 'error' }
  return { texto: 'Cobrada', tono: 'success' }
}

/** La pastilla de una semana en la lista: la de lo que hay que cobrar de ella. */
export function pastillaDeSemana(c: Cohorte, hoy: string): Pastilla {
  if (c.cuotas.length === 0) return { texto: 'Sin cuotas', tono: 'neutral' }
  return pastillaDeCobro(c.aCobrar, hoy)
}

/** La pastilla de una cuota: la misma lectura, en lo que se cobra en ella. */
export function pastillaDeCuota(q: CuotaDeCohorte, hoy: string): Pastilla {
  return pastillaDeCobro(q, hoy)
}

/**
 * Un tramo de una barra de estados: su clave (para el color), su rótulo, su
 * cifra (lo que se cobra) y, para el globo, su desglose y sus personas.
 */
export type Tramo<TClave extends string> = {
  clave: TClave
  rotulo: string
  valor: number
  desglose?: Desglose
  personas?: number
}

/** Los cinco tramos de lo que se cobra en algo, en el orden de la leyenda. */
export function tramosDeCobro(q: Cobro): Array<Tramo<EstadoDeCuota>> {
  return ESTADOS_DE_CUOTA.map((e) => ({
    clave: e,
    rotulo: ROTULO_DE_ESTADO[e],
    valor: q.estados[e].importe.payableUsd,
    desglose: q.estados[e].importe,
    personas: q.estados[e].personas,
  }))
}

/** La parte de lo que se cobra que está en un estado, de 0 a 100; `null` si no hay nada que cobrar. */
export function parteDeEstado(q: Cobro, e: EstadoDeCuota): number | null {
  const total = q.importe.payableUsd
  return total > 0 ? (q.estados[e].importe.payableUsd / total) * 100 : null
}

/**
 * La cuota ya tuvo tiempo de cobrarse entera a tiempo: su último vencimiento
 * más la gracia ya pasó. Hasta entonces su «a tiempo» todavía puede subir.
 */
export function plazoCerrado(q: { venceHasta: string | null }, hoy: string, graciaDias: number): boolean {
  return q.venceHasta !== null && sumarDias(q.venceHasta, graciaDias) < hoy
}
