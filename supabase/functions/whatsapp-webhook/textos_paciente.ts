// ═══════════════════════════════════════════════════════════════════════════
// Helios — Lo que el bot le dice al paciente (decisiones del 2026-10-06,
// docs/00 §15.6). Módulo puro: lo prueba `textos_paciente.test.ts`.
//
// Al paciente SÍ se le enseña lo que paga con la comisión de servicio dentro
// (es su deuda); a la clínica, nunca.
// ═══════════════════════════════════════════════════════════════════════════

import { dinero, montoEs } from './datos.ts'

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
  monto: number
  cargo_atraso: number
  vencida: boolean
}

export type FinanciamientoActivo = {
  orden: number
  clinica: string
  consulta: number
  cuotas: CuotaPendiente[]
}

export type ResumenDelPaciente = {
  nombre: string | null
  financiamientos: FinanciamientoActivo[]
  tasa_bcv: number | null
  cuentas_de_cobro: string
  pago_en_revision: boolean
}

function hola(nombre: string | null): string {
  return nombre ? `, ${nombre}` : ''
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

/** «Pagar cuota»: cuánto, en dólares y en bolívares de hoy, y cómo. */
export function mensajePagar(r: ResumenDelPaciente): string {
  const aPagar = cuotasAPagar(r)
  if (aPagar.length === 0) {
    return `No tienes cuotas pendientes${hola(r.nombre)}. ¡Gracias por estar al día! 💙`
  }

  const vencidas = aPagar.some((x) => x.c.vencida)
  const lineas = aPagar.map(({ f, c }) => {
    const cargo = c.cargo_atraso > 0 ? ` + cargo por atraso ${dinero(c.cargo_atraso)}` : ''
    return `* ${dinero(c.monto)}${cargo} — ${fechaLarga(c.due_date)} (#${f.orden}, ${f.clinica})${c.vencida ? ' ⚠️ vencida' : ''}`
  })
  const total = aPagar.reduce((s, { c }) => s + c.monto + c.cargo_atraso, 0)

  const bs =
    r.tasa_bcv && r.tasa_bcv > 0
      ? `En bolívares hoy: Bs. ${montoEs(total * r.tasa_bcv)} (tasa BCV ${montoEs(r.tasa_bcv)}).`
      : 'En bolívares, a la tasa BCV del día en que pagues.'

  return (
    `💳 ${vencidas ? 'Tienes cuotas vencidas' : 'Tu próxima cuota'}:\n${lineas.join('\n')}\n\n` +
    `Total a pagar: ${dinero(total)}\n${bs}\n\n` +
    (r.pago_en_revision ? 'Tienes un pago en revisión: te avisaremos por aquí cuando lo confirmemos.\n\n' : '') +
    `Cómo pagar:\n${r.cuentas_de_cobro}\n\n` +
    'Cuando pagues, envíanos el comprobante por este chat. 💙'
  )
}

/** «Mis pagos en cuotas»: los activos, lo pendiente de cada uno y el saldo. */
export function mensajeFinanciamientos(r: ResumenDelPaciente): string {
  if (r.financiamientos.length === 0) {
    return `No tienes pagos en cuotas activos${hola(r.nombre)}. 💙`
  }
  let saldoTotal = 0
  const bloques = r.financiamientos.map((f) => {
    const saldo = f.cuotas.reduce((s, c) => s + c.monto + c.cargo_atraso, 0)
    saldoTotal += saldo
    const cuotas = f.cuotas.map((c) => {
      const cargo = c.cargo_atraso > 0 ? ` + cargo ${dinero(c.cargo_atraso)}` : ''
      return `* ${dinero(c.monto)}${cargo} — ${fechaLarga(c.due_date)}${c.vencida ? ' ⚠️ vencida' : ''}`
    })
    return `🩺 #${f.orden} · ${f.clinica} (consulta ${dinero(f.consulta)})\n${cuotas.join('\n')}\nSaldo: ${dinero(saldo)}`
  })
  return (
    `📋 Tus pagos en cuotas activos:\n\n${bloques.join('\n\n')}` +
    (r.financiamientos.length > 1 ? `\n\nSaldo total: ${dinero(saldoTotal)}` : '') +
    (r.pago_en_revision ? '\n\nTienes un pago en revisión: aún no aparece descontado.' : '')
  )
}
