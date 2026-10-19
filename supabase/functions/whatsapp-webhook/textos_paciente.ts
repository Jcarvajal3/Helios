// ═══════════════════════════════════════════════════════════════════════════
// Helios — Lo que el bot le dice al paciente (decisiones del 2026-10-06,
// docs/00 §15.6; textos nuevos aprobados por Javier el 2026-10-19). Módulo
// puro: lo prueba `textos_paciente.test.ts`.
//
// Al paciente SÍ se le enseña lo que paga con la Comisión Helios dentro
// (es su deuda); a la clínica, nunca. Se le nombra a su médico («la Dra.
// Nadia Khabbaze»), no a la clínica.
//
// La moneda (2026-10-07): cada orden está en dólares o en euros y sus cuotas
// se enseñan en esa moneda; el cargo por atraso es siempre en dólares. El
// paciente paga solo en bolívares (Pago Móvil o transferencia): cada monto
// a la tasa BCV de su moneda del día en que paga. Las monedas no se suman
// entre sí: el total que las junta es el de bolívares, y los bolívares salen
// solo en el bloque de pago, junto a las cuentas (2026-10-19).
// ═══════════════════════════════════════════════════════════════════════════

import { bolivares, dinero, dineroEn, monedaDe, nombreDeLaMoneda } from './datos.ts'
import type { Moneda } from './datos.ts'

export type Boton = { id: string; title: string }

export const BOTON_PAGAR: Boton = { id: 'paciente:pagar', title: 'Pagar mi cuota' }
export const BOTON_AYUDA: Boton = { id: 'paciente:ayuda', title: 'Hablar con alguien' }

/** El id `paciente:financiamientos` se queda: lo llevan los menús ya enviados. */
export const MENU_PACIENTE: Boton[] = [
  BOTON_PAGAR,
  { id: 'paciente:financiamientos', title: 'Mi saldo y cuotas' },
  BOTON_AYUDA,
]

/** Lo más largo que admite un mensaje con botones. */
export const MAXIMO_CON_BOTONES = 1024

/** La frase de los niveles: la misma que `helios_level_reminder()` en la base. */
export const FRASE_NIVEL = '⭐ Recuerda pagar a tiempo para subir de nivel y disponer de mayores beneficios.'

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

export type CuotaPagada = { sequence: number; due_date: string; monto: number }

export type FinanciamientoActivo = {
  orden: number
  clinica: string
  /** «Dra. Nadia Khabbaze» (o el nombre de la clínica). Sin él, `clinica`. */
  medico?: string
  /** «la Dra. Nadia Khabbaze». Sin él, `medico`. */
  medico_ref?: string
  /** 'USD' | 'EUR'; sin ella (una respuesta vieja), dólares. */
  moneda?: Moneda
  /** En la moneda de la orden. */
  consulta: number
  cuotas: CuotaPendiente[]
  pagadas?: CuotaPagada[]
}

export type Terminado = { orden: number; medico: string; moneda?: Moneda; consulta: number }

export type ResumenDelPaciente = {
  nombre: string | null
  financiamientos: FinanciamientoActivo[]
  terminados?: Terminado[]
  /** Lo que puede usar hoy, en dólares (la misma cifra que ve el médico). */
  disponible_usd?: number | null
  /** Por qué no puede usar nada hoy: 'cuota_vencida', 'estado', 'bloqueo'. */
  bloqueo?: string | null
  /** Bs por dólar hoy. */
  tasa_bcv: number | null
  /** Bs por euro hoy. */
  tasa_bcv_eur?: number | null
  /** Las cuentas en una línea cada una (respuesta vieja). */
  cuentas_de_cobro: string
  /** Las cuentas, cada dato en su línea (`helios_payment_accounts_block`). */
  datos_de_pago?: string
  pago_en_revision: boolean
}

function hola(nombre: string | null): string {
  return nombre ? `, ${nombre}` : ''
}

function medicoDe(f: FinanciamientoActivo): string {
  return f.medico ?? f.clinica
}

function medicoRefDe(f: FinanciamientoActivo): string {
  return f.medico_ref ?? medicoDe(f)
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

const DIAS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado']

/** «lunes 26/10» para «2026-10-26» (como `helios_weekday_es` + DD/MM en la base). */
export function diaLargo(fecha: string): string {
  const [y, m, d] = fecha.slice(0, 10).split('-').map(Number)
  const f = new Date(Date.UTC(y, m - 1, d))
  return `${DIAS[f.getUTCDay()]} ${String(d).padStart(2, '0')}/${String(m).padStart(2, '0')}`
}

/** «12/10/2026» para «2026-10-12». */
export function fechaLarga(fecha: string): string {
  const [y, m, d] = fecha.slice(0, 10).split('-')
  return `${d}/${m}/${y}`
}

/**
 * El bloque de pago (el mismo que `helios_payment_block` en la base): los
 * bolívares de hoy y que otro día será la tasa de ese día, las cuentas,
 * «envíanos la foto del comprobante» y la frase de los niveles.
 */
export function bloqueDePago(r: ResumenDelPaciente, s: PorMoneda): string {
  const bs = bolivaresDeHoy(r, s)
  const monto =
    bs !== null
      ? `💵 *Monto en bolívares hoy: ${bolivares(bs)}*\n` +
        `Es el equivalente a ${enSusMonedas(s)} a la tasa BCV ${deLasMonedas(s)} de hoy. ` +
        'Si pagas otro día, paga el equivalente a la tasa BCV de ese día.'
      : `💵 *Monto en bolívares*\nPagas el equivalente a ${enSusMonedas(s)} a la tasa BCV ${deLasMonedas(s)} del día en que pagues.`
  return [
    monto,
    r.datos_de_pago ?? r.cuentas_de_cobro,
    '📸 Cuando pagues, envíanos la foto del comprobante por este chat.',
    FRASE_NIVEL,
  ].join('\n\n')
}

/** El menú, con los tres botones (los pone quien lo envía). */
export function mensajeGenerico(nombre: string | null): string {
  return (
    `💙 ¡Hola${hola(nombre)}! Gracias por escribirnos.\n` +
    '¿En qué te ayudamos hoy? Si prefieres, cuéntanos por aquí y alguien del equipo te responde.'
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
  return `📄 ¡Gracias${hola(nombre)}! Recibimos tu comprobante.\nLo revisamos y te confirmamos el pago por aquí en cuanto esté listo 💙`
}

/** El botón «Ya pagué» de los recordatorios. */
export function mensajeYaPague(nombre: string | null): string {
  return `¡Gracias${hola(nombre)}! Envíanos la foto del comprobante por aquí 📸 y lo confirmamos.`
}

export function mensajeAyuda(nombre: string | null): string {
  return `Listo${hola(nombre)}. Alguien de nuestro equipo te escribe por aquí en breve 💙`
}

export function mensajePedirCedula(): string {
  return 'Para proteger tus datos, escríbenos tu número de cédula (por ejemplo V12345678):'
}

export function mensajeCedulaNoCoincide(): string {
  return 'Esa cédula no coincide con este número. Revísala y escríbela otra vez (por ejemplo V12345678):'
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

/** «$56,96» o «$56,96 + cargo por atraso $2». */
function montoDeLaCuota(f: FinanciamientoActivo, c: CuotaPendiente): string {
  const cargo = c.cargo_atraso > 0 ? ` + cargo por atraso ${dinero(c.cargo_atraso)}` : ''
  return `${dineroEn(c.monto, monedaDe(f.moneda))}${cargo}`
}

const PAGO_EN_REVISION = '🔎 Estamos revisando un pago que nos enviaste. Te avisamos por aquí en cuanto lo confirmemos.'

/** «Pagar mi cuota»: cuánto, en la moneda de cada orden, y el bloque de pago. */
export function mensajePagar(r: ResumenDelPaciente): string {
  const aPagar = cuotasAPagar(r)
  if (aPagar.length === 0) {
    return `No tienes cuotas pendientes${hola(r.nombre)}. ¡Gracias por estar al día! 💙`
  }

  const total = porMoneda(aPagar)
  const vencidas = aPagar.some((x) => x.c.vencida)
  let cabeza: string
  if (vencidas) {
    const n = aPagar.length
    const lineas = aPagar.map(({ f, c }) => `• ${montoDeLaCuota(f, c)} · venció el ${diaLargo(c.due_date)} · ${medicoDe(f)}`)
    cabeza =
      `⚠️ *Tienes ${n} ${n === 1 ? 'cuota pendiente' : 'cuotas pendientes'}*\n${lineas.join('\n')}\n` +
      (n > 1 ? `*Total: ${enSusMonedas(total)}*\n` : '') +
      '\nAún estás a tiempo de ponerte al día 💙'
  } else {
    const { f, c } = aPagar[0]
    cabeza =
      '💳 *Tu próxima cuota*\n' +
      `${montoDeLaCuota(f, c)} · vence el ${diaLargo(c.due_date)}\n` +
      `Consulta con ${medicoRefDe(f)} (orden #${f.orden})`
  }

  return [cabeza, ...(r.pago_en_revision ? [PAGO_EN_REVISION] : []), bloqueDePago(r, total)].join('\n\n')
}

/** «1.ª cuota». */
function ordinal(n: number): string {
  return `${n}.ª cuota`
}

/** Lo disponible: lo que puede usar hoy, o por qué es cero. Null si la base no lo manda. */
function lineaDisponible(r: ResumenDelPaciente): string | null {
  if (r.disponible_usd === undefined || r.disponible_usd === null) return null
  const d = Math.max(0, Number(r.disponible_usd))
  if (d === 0 && r.bloqueo === 'cuota_vencida') {
    return '✨ *Disponible: $0*. Tienes una cuota pendiente; en cuanto la pagues, se reactiva.'
  }
  return `✨ *Disponible para tu próxima consulta: ${dinero(d)}*`
}

/** «Mi saldo y cuotas»: lo disponible, los pagos en cuotas activos, lo que falta por pagar y los terminados. */
export function mensajeFinanciamientos(r: ResumenDelPaciente): string {
  const partes: string[] = ['📋 *Tu cuenta Helios*']
  const disponible = lineaDisponible(r)
  if (disponible) partes.push(disponible)

  if (r.financiamientos.length === 0) {
    partes.push(`No tienes pagos en cuotas activos${hola(r.nombre)}. 💙`)
  } else {
    const bloques = r.financiamientos.map((f) => {
      const m = monedaDe(f.moneda)
      const pagadas = (f.pagadas ?? []).map((p) => ({ sequence: p.sequence, linea: `✅ ${ordinal(p.sequence)} ${dineroEn(p.monto, m)} · pagada` }))
      const pendientes = f.cuotas.map((c) => ({
        sequence: c.sequence,
        linea: c.vencida
          ? `⚠️ ${ordinal(c.sequence)} ${montoDeLaCuota(f, c)} · venció el ${diaLargo(c.due_date)}`
          : `⏳ ${ordinal(c.sequence)} ${montoDeLaCuota(f, c)} · vence el ${diaLargo(c.due_date)}`,
      }))
      const cuotas = [...pagadas, ...pendientes].sort((a, b) => a.sequence - b.sequence).map((x) => x.linea)
      return `🩺 ${medicoDe(f)} · orden #${f.orden}\nConsulta: ${dineroEn(f.consulta, m)}\n${cuotas.join('\n')}`
    })
    const porPagar = porMoneda(r.financiamientos.flatMap((f) => f.cuotas.map((c) => ({ f, c }))))
    partes.push(`*Pagos en cuotas activos*\n${bloques.join('\n\n')}`)
    partes.push(`*Por pagar: ${enSusMonedas(porPagar)}*`)
  }

  const terminados = r.terminados ?? []
  if (terminados.length > 0) {
    partes.push(`*Terminados*\n${terminados.map((t) => `✔️ ${t.medico} · orden #${t.orden} · pagado completo`).join('\n')}`)
  }

  if (r.pago_en_revision) partes.push('🔎 Tienes un pago en revisión: aún no aparece descontado.')
  return partes.join('\n\n')
}

/** ¿Hay algo que pagar? (para ofrecer el botón «Pagar mi cuota»). */
export function tienePendientes(r: ResumenDelPaciente): boolean {
  return r.financiamientos.some((f) => f.cuotas.length > 0)
}
