// ═══════════════════════════════════════════════════════════════════════════
// Helios — Lo que el bot le dice al paciente (decisiones del 2026-10-06,
// docs/00 §15.6). Módulo puro: lo prueba `textos_paciente.test.ts`.
//
// Al paciente SÍ se le enseña lo que paga con la comisión de servicio dentro
// (es su deuda); a la clínica, nunca.
//
// La moneda (2026-10-07): cada orden está en dólares o en euros y sus cuotas
// se enseñan en esa moneda; el cargo por atraso es siempre en dólares. El
// paciente paga solo en bolívares (Pago Móvil o transferencia): cada monto
// a la tasa BCV de su moneda del día en que paga. Las monedas no se suman
// entre sí: el total que las junta es el de bolívares.
// ═══════════════════════════════════════════════════════════════════════════

import { bolivares, dinero, dineroEn, monedaDe, montoEs, nombreDeLaMoneda } from './datos.ts'
import type { Moneda } from './datos.ts'

export type Boton = { id: string; title: string }

export const MENU_PACIENTE: Boton[] = [
  { id: 'paciente:pagar', title: 'Pagar cuota' },
  { id: 'paciente:financiamientos', title: 'Mis pagos en cuotas' },
  { id: 'paciente:ayuda', title: 'Ayuda' },
]

/** Una cuota pendiente, como la manda `bot_paciente_resumen`. */
export type CuotaPendiente = {
  sequence: number
  due_date: string
  /** En la moneda de la orden. */
  monto: number
  /** En DÓLARES, sea cual sea la moneda de la orden. */
  cargo_atraso: number
  vencida: boolean
}

export type FinanciamientoActivo = {
  orden: number
  clinica: string
  /** 'USD' | 'EUR'; sin ella (una respuesta vieja), dólares. */
  moneda?: Moneda
  /** En la moneda de la orden. */
  consulta: number
  cuotas: CuotaPendiente[]
}

export type ResumenDelPaciente = {
  nombre: string | null
  financiamientos: FinanciamientoActivo[]
  /** Bs por dólar hoy. */
  tasa_bcv: number | null
  /** Bs por euro hoy. */
  tasa_bcv_eur?: number | null
  cuentas_de_cobro: string
  pago_en_revision: boolean
}

function hola(nombre: string | null): string {
  return nombre ? `, ${nombre}` : ''
}

/** Lo que se debe, por moneda, en el orden en que aparece cada una. */
type PorMoneda = Map<Moneda, number>

function sumar(s: PorMoneda, m: Moneda, x: number) {
  if (x > 0) s.set(m, (s.get(m) ?? 0) + x)
}

/** Las cuotas por moneda: el monto en la de su orden, el cargo por atraso en dólares. */
function porMoneda(cuotas: Array<{ f: FinanciamientoActivo; c: CuotaPendiente }>): PorMoneda {
  const s: PorMoneda = new Map()
  for (const { f, c } of cuotas) {
    sumar(s, monedaDe(f.moneda), c.monto)
    sumar(s, 'USD', c.cargo_atraso)
  }
  return s
}

/** «$58,96», «€113,92 + $2»: cada moneda con lo suyo, sin convertir. */
export function enSusMonedas(s: PorMoneda): string {
  if (s.size === 0) return dinero(0)
  return [...s].map(([m, x]) => dineroEn(x, m)).join(' + ')
}

function tasaDe(r: ResumenDelPaciente, m: Moneda): number | null {
  const t = m === 'EUR' ? r.tasa_bcv_eur : r.tasa_bcv
  return t && t > 0 ? t : null
}

/**
 * Los bolívares de hoy: cada monto a la tasa BCV de su moneda (Bs de una
 * cuota = monto × tasa de su moneda + cargo por atraso × tasa del dólar).
 * Null si falta alguna tasa que haga falta.
 */
export function bolivaresDeHoy(r: ResumenDelPaciente, s: PorMoneda): number | null {
  let bs = 0
  for (const [m, x] of s) {
    const tasa = tasaDe(r, m)
    if (tasa === null) return null
    bs += x * tasa
  }
  return bs
}

/** «del dólar», «del euro», «del dólar y del euro». */
function deLasMonedas(s: PorMoneda): string {
  const ms = s.size > 0 ? [...s.keys()] : (['USD'] as Moneda[])
  return ms.map((m) => `del ${nombreDeLaMoneda(m)}`).join(' y ')
}

/**
 * «En bolívares hoy: Bs 10.510,26 (tasa BCV del dólar 184,52).» o, si falta
 * una tasa, «En bolívares, a la tasa BCV del euro del día en que pagues.»
 */
function lineaDeBolivares(r: ResumenDelPaciente, s: PorMoneda): string {
  const bs = bolivaresDeHoy(r, s)
  if (bs === null) return `En bolívares, a la tasa BCV ${deLasMonedas(s)} del día en que pagues.`
  const tasas = [...s.keys()].map((m) => `tasa BCV del ${nombreDeLaMoneda(m)} ${montoEs(tasaDe(r, m)!)}`)
  return `En bolívares hoy: ${bolivares(bs)} (${tasas.join(' · ')}).`
}

/** «12/10/2026» para «2026-10-12». */
export function fechaLarga(fecha: string): string {
  const [y, m, d] = fecha.slice(0, 10).split('-')
  return `${d}/${m}/${y}`
}

/** El mensaje genérico, con los tres botones (los pone quien lo envía). */
export function mensajeGenerico(nombre: string | null): string {
  return (
    `💙 Gracias por escribirnos${hola(nombre)}.\n\n` +
    'Hemos recibido tu mensaje. Si necesitas asistencia con tu pago en cuotas con Helios, nuestro equipo está para ayudarte.\n\n' +
    'Mientras tanto, puedes consultar o pagar tu cuota desde aquí:'
  )
}

/** Para quien escribe sin ser paciente: lo atiende el equipo. */
export function mensajeSinFinanciamientos(): string {
  return (
    '💙 Gracias por escribirnos.\n\n' +
    'Hemos recibido tu mensaje. Nuestro equipo te responderá por aquí en breve.'
  )
}

export function mensajeComprobante(nombre: string | null): string {
  return (
    `📄 Recibimos tu comprobante${hola(nombre)}. Nuestro equipo lo revisará y te confirmará el pago por aquí. ¡Gracias! 💙`
  )
}

export function mensajeAyuda(nombre: string | null): string {
  return `Listo${hola(nombre)}. Una persona de nuestro equipo te atenderá por este chat en breve. 💙`
}

export function mensajePedirCedula(): string {
  return 'Para ayudarte, escribe tu número de cédula (por ejemplo V12345678):'
}

/**
 * Las cuotas a pagar ahora: todas las vencidas, o si no hay, la próxima.
 * Con el pago en cuotas al que pertenece cada una.
 */
export function cuotasAPagar(r: ResumenDelPaciente): Array<{ f: FinanciamientoActivo; c: CuotaPendiente }> {
  const todas = r.financiamientos
    .flatMap((f) => f.cuotas.map((c) => ({ f, c })))
    .sort((a, b) => a.c.due_date.localeCompare(b.c.due_date) || a.c.sequence - b.c.sequence)
  const vencidas = todas.filter((x) => x.c.vencida)
  if (vencidas.length > 0) return vencidas
  return todas.slice(0, 1)
}

/** «Pagar cuota»: cuánto, en la moneda de cada orden y en bolívares de hoy, y cómo (solo en bolívares). */
export function mensajePagar(r: ResumenDelPaciente): string {
  const aPagar = cuotasAPagar(r)
  if (aPagar.length === 0) {
    return `No tienes cuotas pendientes${hola(r.nombre)}. ¡Gracias por estar al día! 💙`
  }

  const vencidas = aPagar.some((x) => x.c.vencida)
  const lineas = aPagar.map(({ f, c }) => {
    const cargo = c.cargo_atraso > 0 ? ` + cargo por atraso ${dinero(c.cargo_atraso)}` : ''
    return `* ${dineroEn(c.monto, monedaDe(f.moneda))}${cargo} — ${fechaLarga(c.due_date)} (#${f.orden}, ${f.clinica})${c.vencida ? ' ⚠️ vencida' : ''}`
  })
  const total = porMoneda(aPagar)

  return (
    `💳 ${vencidas ? 'Tienes cuotas vencidas' : 'Tu próxima cuota'}:\n${lineas.join('\n')}\n\n` +
    `Total a pagar: ${enSusMonedas(total)}\n${lineaDeBolivares(r, total)}\n\n` +
    (r.pago_en_revision ? 'Tienes un pago en revisión: te avisaremos por aquí cuando lo confirmemos.\n\n' : '') +
    `Cómo pagar (en bolívares, por Pago Móvil o transferencia):\n${r.cuentas_de_cobro}\n\n` +
    'Cuando pagues, envíanos el comprobante por este chat. 💙'
  )
}

/** «Mis pagos en cuotas»: los activos, lo pendiente de cada uno y el saldo. */
export function mensajeFinanciamientos(r: ResumenDelPaciente): string {
  if (r.financiamientos.length === 0) {
    return `No tienes pagos en cuotas activos${hola(r.nombre)}. 💙`
  }
  const bloques = r.financiamientos.map((f) => {
    const m = monedaDe(f.moneda)
    const saldo = porMoneda(f.cuotas.map((c) => ({ f, c })))
    const cuotas = f.cuotas.map((c) => {
      const cargo = c.cargo_atraso > 0 ? ` + cargo ${dinero(c.cargo_atraso)}` : ''
      return `* ${dineroEn(c.monto, m)}${cargo} — ${fechaLarga(c.due_date)}${c.vencida ? ' ⚠️ vencida' : ''}`
    })
    return `🩺 #${f.orden} · ${f.clinica} (consulta ${dineroEn(f.consulta, m)})\n${cuotas.join('\n')}\nSaldo: ${enSusMonedas(saldo)}`
  })
  const saldoTotal = porMoneda(r.financiamientos.flatMap((f) => f.cuotas.map((c) => ({ f, c }))))
  const bs = bolivaresDeHoy(r, saldoTotal)
  return (
    `📋 Tus pagos en cuotas activos:\n\n${bloques.join('\n\n')}` +
    (r.financiamientos.length > 1 ? `\n\nSaldo total: ${enSusMonedas(saldoTotal)}` : '') +
    (bs !== null && bs > 0 ? `\nEn bolívares hoy: ${bolivares(bs)}.` : '') +
    (r.pago_en_revision ? '\n\nTienes un pago en revisión: aún no aparece descontado.' : '')
  )
}
