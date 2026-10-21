import { formatUsd, formatPorcentaje } from '@/components/ui'
import type { Desglose } from '@/features/admin/metricas/lectura'
import { desgloseEnFrase } from './desglose'
import { aunNoVence } from './estados'
import { rangoDeVencimiento, semanaLarga } from './semanas'
import type { Cohorte, CuotaDeCohorte, CurvaDeCuota, PuntoDeCurva } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// Las frases con cifras de la pestaña Cohortes. La gente no lee: una frase
// con los números dentro vale más que un párrafo.
//
// Cohortes habla en lo que hay que COBRAR: el total a cobrar de una semana es
// la cuota 1 + la cuota 2, con la Comisión Helios dentro. Todo importe que se
// cobra lleva su desglose entre paréntesis (consumo sin comisión + Comisión Helios):
// es la condición de la excepción que aprobó Javier. Las frases prefieren los
// porcentajes, que no necesitan desglose.
//
// Cada frase es una lista de trozos: texto corrido, o `{ cifra }` para lo que
// se destaca en blanco (`FraseConCifras` del kit los pinta).
//
// Puro: se prueba en `frases.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Un trozo de frase: texto, o una cifra que se destaca. */
export type Trozo = string | { cifra: string }

/** La frase en texto plano: para un `aria-label` o una prueba. */
export function textoPlano(trozos: ReadonlyArray<Trozo>): string {
  return trozos.map((t) => (typeof t === 'string' ? t : t.cifra)).join('')
}

/** «17 %» sin decimales por encima del 10 %, «6,8 %» por debajo. */
export function pct(p: number): string {
  return formatPorcentaje(p, Math.abs(p) < 10 && p !== 0 ? 1 : 0)
}

function usuarios(n: number): string {
  return `${n} ${n === 1 ? 'paciente' : 'pacientes'}`
}

/** Un importe que se cobra con su desglose: «$45,20 (facturado $36,70 + service fee + IVA $8,50)». */
export function importeConDesglose(d: Desglose): Trozo[] {
  return [{ cifra: formatUsd(d.payableUsd) }, ` (${desgloseEnFrase(d)})`]
}

function mayuscula(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1)
}

// ── El detalle de una semana ───────────────────────────────────────────────

function trozosDeCuota(q: CuotaDeCohorte, hoy: string): Trozo[] {
  const nombre = `la cuota ${q.numero}`
  if (aunNoVence(q, hoy)) {
    return [` ${mayuscula(nombre)} vence ${rangoDeVencimiento(q.venceDesde, q.venceHasta)}.`]
  }
  const cobrado = q.cobradoPct ?? 0
  const vencidas = q.estados.vencida.personas
  if (vencidas > 0) {
    return [
      ` De ${nombre} se cobró el `,
      { cifra: pct(cobrado) },
      ' y ',
      { cifra: usuarios(vencidas) },
      ` la ${vencidas === 1 ? 'tiene' : 'tienen'} vencida.`,
    ]
  }
  if (q.estados.por_vencer.importe.payableUsd > 0) {
    return [` De ${nombre} se cobró el `, { cifra: pct(cobrado) }, ' y el resto todavía no vence.']
  }
  if (q.estados.perdida.importe.payableUsd > 0) {
    return [
      ` De ${nombre} se cobró el `,
      { cifra: pct(cobrado) },
      ' y ',
      { cifra: usuarios(q.estados.perdida.personas) },
      ` la ${q.estados.perdida.personas === 1 ? 'dejó' : 'dejaron'} sin pagar (dada por perdida).`,
    ]
  }
  return [` ${mayuscula(nombre)} está cobrada entera.`]
}

/**
 * La frase de arriba del detalle: qué parte de lo que hay que cobrar de la
 * semana ya se cobró y cómo va cada cuota. «Ya se cobró el 43 % de lo que hay
 * que cobrar de esta semana. De la cuota 1 se cobró el 58 % y 12 personas la
 * tienen vencida. La cuota 2 vence del 28 sep al 4 oct.» Los importes, con su
 * desglose, están justo encima, en las cifras.
 */
export function fraseDeLaSemana(c: Cohorte, hoy: string): Trozo[] {
  const a = c.aCobrar
  const trozos: Trozo[] =
    a.cobrado.importe.payableUsd > 0 && a.cobradoPct !== null
      ? ['Ya se cobró el ', { cifra: pct(a.cobradoPct) }, ' de lo que hay que cobrar de esta semana.']
      : ['Todavía no se ha cobrado nada de lo que hay que cobrar de esta semana.']
  for (const q of c.cuotas) trozos.push(...trozosDeCuota(q, hoy))
  return trozos
}

// ── La curva de cobro ──────────────────────────────────────────────────────

/** El último día de la curva de esta semana que ya cerró, si hay alguno. */
export function ultimoCerrado(curva: CurvaDeCuota): PuntoDeCurva | null {
  const cerrados = curva.puntos.filter((p) => p.estaPct !== null)
  return cerrados.at(-1) ?? null
}

function cuandoFue(dia: number): string {
  if (dia === 0) return 'El día que venció'
  const n = Math.abs(dia)
  const dias = n === 1 ? 'día' : 'días'
  return dia < 0 ? `A ${n} ${dias} de vencer` : `${n} ${dias} después de vencer`
}

/**
 * La línea de la curva: lo cobrado el día que venció (o el último día ya
 * cerrado) frente a la media de las semanas anteriores ese mismo día.
 */
export function fraseDeLaCurva(curva: CurvaDeCuota, q: CuotaDeCohorte | null): string {
  const n = curva.numero
  const punto = curva.puntos.find((p) => p.dia === 0 && p.estaPct !== null) ?? ultimoCerrado(curva)
  if (!punto || punto.estaPct === null) {
    if (!q) return `Esta semana no tiene cuota ${n}.`
    return `La cuota ${n} de esta semana vence ${rangoDeVencimiento(q.venceDesde, q.venceHasta)}. La curva empieza cuando hayan cerrado sus días.`
  }
  const esta = `${cuandoFue(punto.dia)}, esta semana llevaba cobrado el ${pct(punto.estaPct)} de la cuota ${n}`
  if (punto.mediaPct === null || punto.semanasEnMedia === 0) return `${esta}.`
  const cuantas =
    punto.semanasEnMedia === 1 ? 'la semana anterior llevaba' : `las ${punto.semanasEnMedia} semanas anteriores llevaban de media`
  return `${esta}; ${cuantas} el ${pct(punto.mediaPct)}.`
}

// ── Comparar todas ─────────────────────────────────────────────────────────

/**
 * La línea del gráfico «Lo que hay que cobrar, semana a semana»: la semana
 * de las que se ven con más vencido, con su desglose y qué parte es de lo
 * que había que cobrar de ella. Si no hay nada vencido, lo dice.
 */
export function fraseDelGrafico(cohortes: ReadonlyArray<Cohorte>): Trozo[] {
  if (cohortes.length === 0) return ['Todavía no hay ninguna semana con algo que cobrar.']
  let peor: Cohorte | null = null
  for (const c of cohortes) {
    const v = c.aCobrar.estados.vencida.importe.payableUsd
    if (v > 0 && (peor === null || v > peor.aCobrar.estados.vencida.importe.payableUsd)) peor = c
  }
  if (peor) {
    const a = peor.aCobrar
    const parte = a.importe.payableUsd > 0 ? (a.estados.vencida.importe.payableUsd / a.importe.payableUsd) * 100 : 0
    return [
      `La semana con más vencido es la ${semanaLarga(peor.semana)}: `,
      ...importeConDesglose(a.estados.vencida.importe),
      ', el ',
      { cifra: pct(parte) },
      ' de lo que hay que cobrar de ella.',
    ]
  }
  if (cohortes.some((c) => c.aCobrar.estados.por_vencer.importe.payableUsd > 0)) {
    return ['Ninguna de estas semanas tiene nada vencido: lo que falta por cobrar todavía no vence.']
  }
  return ['Todo lo que había que cobrar de estas semanas está cobrado o dado por perdido.']
}

/**
 * La semana con la que se explica la tabla comparada: la elegida arriba si su
 * cuota 1 ya empezó a vencer, y si no, la más reciente que sí.
 */
export function semanaDeEjemplo(
  cohortes: ReadonlyArray<Cohorte>,
  elegida: string,
  hoy: string,
): Cohorte | null {
  const empezada = (c: Cohorte) => c.cuotas.length > 0 && !aunNoVence(c.aCobrar, hoy)
  const suya = cohortes.find((c) => c.semana === elegida)
  if (suya && empezada(suya)) return suya
  return [...cohortes].sort((a, b) => (a.semana < b.semana ? 1 : -1)).find(empezada) ?? null
}

function trozosDeCuotaEnEjemplo(q: CuotaDeCohorte, hoy: string): Trozo[] {
  if (aunNoVence(q, hoy) && (q.cobradoPct ?? 0) === 0) {
    return [`la cuota ${q.numero} vence ${rangoDeVencimiento(q.venceDesde, q.venceHasta)}`]
  }
  return ['el ', { cifra: pct(q.cobradoPct ?? 0) }, ` de la cuota ${q.numero}`]
}

/**
 * «Cómo se lee» la tabla comparada, con los números de una semana de verdad:
 * «cada fila es lo que hay que cobrar de lo consumido una semana: la cuota 1
 * más la cuota 2, cada una con su service fee. En la del 14 al 20 de
 * septiembre hay que cobrar $1.419,26 (consumo $1.152,00 sin fee + service
 * fee $267,26) y ya se cobró el 43 % (el 58 % de la cuota 1 y el 28 % de la
 * cuota 2).»
 */
export function comoSeLee(c: Cohorte | null, hoy: string): Trozo[] {
  const base = 'cada fila es el total a cobrar de los financiamientos de una semana: la cuota 1 más la cuota 2, cada una con su Comisión Helios + IVA.'
  if (!c) return [base]
  const a = c.aCobrar
  const trozos: Trozo[] = [
    `${base} En la ${semanaLarga(c.semana)} hay que cobrar `,
    ...importeConDesglose(a.importe),
    ' y ya se cobró el ',
    { cifra: pct(a.cobradoPct ?? 0) },
  ]
  const partes = c.cuotas.map((q) => trozosDeCuotaEnEjemplo(q, hoy))
  if (partes.length > 0) {
    trozos.push(' (')
    partes.forEach((p, i) => {
      if (i > 0) trozos.push(i === partes.length - 1 ? ' y ' : ', ')
      trozos.push(...p)
    })
    trozos.push(')')
  }
  trozos.push('.')
  return trozos
}
