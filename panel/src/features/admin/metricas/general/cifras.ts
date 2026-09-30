import { MESES_LARGOS, formatDayShort, formatUsd, formatPct } from '@/components/ui'
import type { SenalDeCifra } from '@/components/ui'
import type { LinePoint } from '@/components/charts'
import type { ParteDeFrase } from '@/components/admin/metricas/kit'
import { pctDeUmbral, senalDelImpago } from '@/components/admin/tableros/senales'
import { porcentaje } from '@/features/admin/metricas/formato'
import { lunesDe } from '@/features/admin/semana'
import { senalPorUmbral, senalPorUmbralAlto, umbralCobroATiempo, umbralImpago, umbralMora } from '@/features/admin/umbrales'
import type { Parametros } from '@/features/admin/parametros'
import type { CobroATiempo, General, PorCadaCien, SemanaDeLaCurva } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que la pestaña General escribe con las cifras de la base: la frase de
// arriba, los pies de las tarjetas, las pastillas de estado, las líneas de
// «por cada €100» y los puntos de la curva.
//
// Ninguna cifra de negocio nace aquí. Solo se escriben las que da la base y,
// como mucho, la parte de una sobre otra (`porcentaje`). Ningún texto suma
// lo que se paga en cuotas: un importe payable va siempre con su desglose, y
// eso lo pinta la tarjeta (`DesgloseEnTarjeta`), no una frase.
//
// Puro: se prueba en `cifras.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Lo que va en una tarjeta cuando la cifra no tiene con qué calcularse. */
export const SIN_DATO = '—'

/** «1 persona», «3 personas». */
export function contar(n: number, singular: string, plural: string): string {
  return `${n.toLocaleString('es-VE')} ${n === 1 ? singular : plural}`
}

/** Un recuento con el punto de los miles: «1.940». */
export function entero(n: number): string {
  return n.toLocaleString('es-VE')
}

/** Un porcentaje de la base, o el guion si no hay con qué calcularlo. */
export function pctOGuion(v: number | null): string {
  return v === null ? SIN_DATO : formatPct(v)
}

/** '28 de agosto', y con el año si no es el de `hoy`: '28 de agosto de 2025'. */
export function diaYMes(dia: string, hoy: string): string {
  const [a = '', m = '', d = ''] = dia.slice(0, 10).split('-')
  const mes = MESES_LARGOS[Number(m) - 1] ?? m
  return a === hoy.slice(0, 4) ? `${Number(d)} de ${mes}` : `${Number(d)} de ${mes} de ${a}`
}

// ── La frase de arriba ─────────────────────────────────────────────────────

/**
 * La frase de arriba: solo lo que no dice ninguna tarjeta, desde qué día
 * cuentan las cifras «desde el inicio». Los registros, los usuarios, el
 * facturado, los consumos y el service fee ya están en sus tarjetas.
 *
 * Sin local: «Las cifras desde el inicio cuentan desde el 28 de agosto.»
 */
export function fraseGeneral(g: General, nombreLocal: string | null): ParteDeFrase[] {
  const donde = g.local === null ? null : (nombreLocal ?? 'esta clínica')

  if (g.desde === null) {
    return donde === null
      ? ['Todavía no hay registros ni financiamientos.']
      : [`${capitalizar(donde)} todavía no tiene financiamientos.`]
  }

  const desde: ParteDeFrase = { cifra: diaYMes(g.desde, g.hoy) }
  if (donde !== null) return [`En ${donde}, las cifras desde el inicio cuentan desde el `, desde, ', su primer financiamiento.']
  return ['Las cifras desde el inicio cuentan desde el ', desde, '.']
}

function capitalizar(texto: string): string {
  return texto.charAt(0).toUpperCase() + texto.slice(1)
}

// ── Los pies de las tarjetas ───────────────────────────────────────────────

/** «134 de 194 registros». */
export function pieHanComprado(g: General): string | undefined {
  const { hanComprado, registros } = g.gente
  if (hanComprado === null || registros === null) return undefined
  return `${hanComprado.toLocaleString('es-VE')} de ${contar(registros, 'registro', 'registros')}`
}

/** El pie de «Registros»: lo que es un registro, en forma y no en párrafo. */
export const PIE_REGISTROS = 'Con la identidad verificada'

/** «82,2 % llegó a registrarse»: qué parte de quien pidió el código se verificó. */
export function pieSolicitaron(g: General): string | undefined {
  const { solicitaron, registros } = g.gente
  if (solicitaron === null || registros === null) return undefined
  const parte = porcentaje(registros, solicitaron)
  return parte === null ? undefined : `${formatPct(parte)} llegó a registrarse`
}

// Los pies son de una línea y se cortan si no caben: en una fila de cinco
// tarjetas caben unos treinta caracteres. Lo largo va al InfoDot.

/**
 * Qué parte son de todos los usuarios (quien ha consumido alguna vez): «92,5 %
 * de los usuarios». Con local, de los usuarios de ese local.
 */
export function pieDeQuienesConsumieron(parte: number, g: General): string | undefined {
  const p = porcentaje(parte, g.consumo.personas)
  if (p === null) return undefined
  return `${formatPct(p)} de los pacientes${g.local === null ? '' : ' de la clínica'}`
}

/** «3 han vendido alguna vez»: el titular son los que vendieron en el último mes. */
export function pieLocalesActivos(g: General): string | undefined {
  const n = g.consumo.locales
  if (n === null) return undefined
  return `${entero(n)} ${n === 1 ? 'ha' : 'han'} financiado alguna vez`
}

/** «12 cuotas de 8 usuarios». */
export function pieDeCuotas(cuotas: number, personas: number): string {
  if (cuotas === 0) return 'Ninguna cuota'
  return `${contar(cuotas, 'cuota', 'cuotas')} de ${contar(personas, 'paciente', 'pacientes')}`
}

/** «De ello, cobrado €148,00», o que no hay ninguno. */
export function pieCargos(g: General): string {
  const c = g.dinero.cargos
  if (c.cargos === 0) return 'Ninguno todavía'
  return `De ello, cobrado ${formatUsd(c.cobradoUsd)}`
}

export function piePerdido(g: General): string {
  const n = g.dinero.perdido.personas
  return n === 0 ? 'Nada perdido todavía' : `De ${contar(n, 'paciente', 'pacientes')}`
}

export function piePorPagar(g: General): string {
  const p = g.dinero.porPagarLocales
  return p.atrasadoUsd > 0 ? `De ello, atrasado ${formatUsd(p.atrasadoUsd)}` : 'Nada atrasado'
}

export function pieMora(g: General): string {
  if (g.riesgo.moraPct === null) return 'Nada por cobrar'
  const n = g.dinero.vencido.personas
  return n === 0 ? 'Ningún paciente con deuda vencida' : `${contar(n, 'paciente', 'pacientes')} con deuda vencida`
}

export function pieImpago(g: General): string {
  const e = g.riesgo.empatePct
  return e === null ? 'Sin financiamientos para el empate' : `Helios pierde desde el ${formatPct(e)}`
}

/** «272 de 356 con plazo cerrado». */
export function pieCuotaATiempo(c: CobroATiempo | undefined): string {
  if (!c || c.juzgadas === 0) return 'Ninguna ha cerrado su plazo'
  return `${entero(c.aTiempo)} de ${entero(c.juzgadas)} con plazo cerrado`
}

/** El cobro a tiempo de un número de cuota, o nada si la base no lo trae. */
export function cuotaATiempo(g: General, cuota: number): CobroATiempo | undefined {
  return g.riesgo.aTiempo.find((c) => c.cuota === cuota)
}

// ── Las pastillas: solo al cruzar un umbral ────────────────────────────────

export function senalMora(g: General, p: Parametros | undefined): SenalDeCifra | undefined {
  return senalPorUmbral(g.riesgo.moraPct, umbralMora(p), pctDeUmbral)
}

export function senalImpago(g: General, p: Parametros | undefined): SenalDeCifra | undefined {
  return senalDelImpago(g.riesgo.impagoPct, g.riesgo.empatePct, umbralImpago(p))
}

export function senalCuotaATiempo(
  c: CobroATiempo | undefined,
  p: Parametros | undefined,
): SenalDeCifra | undefined {
  return senalPorUmbralAlto(c?.pct ?? null, umbralCobroATiempo(p), pctDeUmbral)
}

// ── Por cada €100 ──────────────────────────────────────────────────────────

export type LineaPorCadaCien = { rotulo: string; valor: string; info: string; total?: boolean }

/** Una línea con su signo delante: lo que entra suma y lo que se pierde resta. */
function conSigno(valor: number): string {
  return `${valor < 0 ? '−' : '+'}${formatUsd(Math.abs(valor))}`
}

/**
 * Las líneas de «por cada €100»: el service fee y los cargos suman y el
 * margen cierra. Lo perdido no va en su línea: es la misma cifra que
 * «Impago (%)» del bloque Riesgo, y el margen dice que ya lo resta. El fee se
 * ve como sumando, nunca sumado al consumo. `null` sin consumo: no hay nada
 * que repartir.
 */
export function lineasPorCadaCien(p: PorCadaCien): LineaPorCadaCien[] | null {
  const c = p.por100
  if (c === null) return null
  return [
    {
      rotulo: 'Service fee sin IVA',
      valor: conSigno(c.servicioUsd),
      info: `El service fee sin IVA: ${formatUsd(p.servicioUsd)} desde el primer día. Se gana al confirmar el financiamiento.`,
    },
    {
      rotulo: 'Cargos por atraso',
      valor: conSigno(c.cargosUsd),
      info: `Los cargos por atraso sin los condonados: ${formatUsd(p.cargosUsd)} desde el primer día.`,
    },
    {
      rotulo: 'Margen, menos el impago',
      valor: formatUsd(c.margenUsd),
      info: `Las dos líneas de arriba menos lo perdido, antes de costes: ${formatUsd(c.perdidoUsd)} por cada $100, que es el «Impago (%)» del bloque Riesgo (${formatUsd(p.perdidoUsd)} facturados que se dieron por perdidos). Cuenta el service fee devengado, también el de las cuotas perdidas, que nunca se cobra.`,
      total: true,
    },
  ]
}

/** «318 consumos con €7.373,00 facturados (sin fee)». */
export function resumenPorCadaCien(p: PorCadaCien): string {
  if (p.consumos === 0) return 'Todavía no hay financiamientos.'
  return `${contar(p.consumos, 'financiamiento', 'financiamientos')} con ${formatUsd(p.financedUsd)} facturados (sin fee)`
}

/**
 * Cuánto de ese consumo ya terminó su ciclo de cobro: hasta entonces, lo
 * perdido todavía puede crecer y el margen es provisional.
 */
export function notaDeMadurez(p: PorCadaCien): string | null {
  const parte = porcentaje(p.financedMaduroUsd, p.financedUsd)
  if (parte === null) return null
  if (parte >= 99.95) return 'Todo lo financiado ya cerró su ciclo de cobro: lo perdido es definitivo.'
  if (parte === 0) return 'Nada de lo financiado ha cerrado todavía su ciclo de cobro: lo perdido todavía puede crecer.'
  return `El ${formatPct(parte)} de lo financiado ya cerró su ciclo de cobro; lo perdido del resto todavía puede crecer.`
}

// ── La curva ───────────────────────────────────────────────────────────────

/** El rótulo de una semana en el eje: su lunes, «24 ago», o «Esta semana». */
export function rotuloDeSemana(semana: SemanaDeLaCurva, hoy: string): string {
  return semana.semana === lunesDe(hoy) ? 'Esta semana' : formatDayShort(semana.semana)
}

/**
 * Los puntos de «registros acumulados». `null` si la curva no los trae (hay
 * un local elegido): no se pintan como cero.
 */
export function puntosDeRegistros(curva: ReadonlyArray<SemanaDeLaCurva>, hoy: string): LinePoint[] | null {
  if (curva.length === 0 || curva.some((s) => s.registrosAcum === null)) return null
  return curva.map((s) => ({
    key: s.semana,
    label: rotuloDeSemana(s, hoy),
    values: [s.registrosAcum],
    note: `${contar(s.registros ?? 0, 'registro', 'registros')} esa semana`,
  }))
}

/** Los puntos de «consumo acumulado», sin el service fee. */
export function puntosDeConsumo(curva: ReadonlyArray<SemanaDeLaCurva>, hoy: string): LinePoint[] {
  return curva.map((s) => ({
    key: s.semana,
    label: rotuloDeSemana(s, hoy),
    values: [s.financedAcumUsd],
    note: `${formatUsd(s.financedUsd)} esa semana`,
  }))
}

/** «194 registros en 12 semanas». */
export function resumenDeRegistros(g: General): string | undefined {
  if (g.gente.registros === null || g.curva.length === 0) return undefined
  return `${contar(g.gente.registros, 'registro', 'registros')} en ${contar(g.curva.length, 'semana', 'semanas')}`
}

/** «€7.373,00 en 12 semanas, sin el service fee». */
export function resumenDeConsumo(g: General): string | undefined {
  if (g.curva.length === 0) return undefined
  return `${formatUsd(g.consumo.financedUsd)} en ${contar(g.curva.length, 'semana', 'semanas')}, sin el service fee`
}
