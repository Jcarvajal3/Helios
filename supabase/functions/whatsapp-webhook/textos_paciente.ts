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
import { formularioDePago, nombrarCampos } from './datos_pago.ts'
import type { Campo } from './datos_pago.ts'

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

/** El cierre de «Mi saldo y cuotas» (Javier, 2026-10-22). */
export const FRASE_SUBIR_DE_NIVEL = '⭐ Si pagas a tiempo, puedes subir de nivel y aumentar tu saldo máximo.'

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

export type ResumenDelPaciente = {
  nombre: string | null
  financiamientos: FinanciamientoActivo[]
  /** Su nivel (1, 2…), cómo se llama («Nivel 1») y el saldo total que le da, en dólares. */
  nivel?: number | null
  nivel_nombre?: string | null
  limite_usd?: number | null
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
 * Un monto por una tasa, en bolívares redondeados al céntimo como los
 * redondea la base (`round(x * tasa, 2)` en numeric): en enteros, sin los
 * errores de los decimales flotantes. El monto lleva hasta 4 decimales y la
 * tasa hasta 6.
 */
function aBolivares(x: number, tasa: number): number {
  const p = BigInt(Math.round(x * 1e4)) * BigInt(Math.round(tasa * 1e6)) // en 1e-10 Bs
  const centimos = (p + (p >= 0n ? 50_000_000n : -50_000_000n)) / 100_000_000n
  return Number(centimos) / 100
}

/**
 * Los bolívares de hoy: cada moneda a su tasa BCV, redondeada por separado y
 * luego sumada, como `helios_bolivares` en la base (Bs de una cuota = monto ×
 * tasa de su moneda + cargo por atraso × tasa del dólar). Así la cifra es la
 * misma que cotiza el bot al leer el comprobante, al céntimo. Null si falta
 * alguna tasa que haga falta.
 */
export function bolivaresDeHoy(r: ResumenDelPaciente, s: PorMoneda): number | null {
  let bs = 0
  for (const [m, x] of s) {
    const tasa = tasaDe(r, m)
    if (tasa === null) return null
    bs += aBolivares(x, tasa)
  }
  return Math.round(bs * 100) / 100
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

/** Todo lo que le queda por pagar, para quien quiera pagarlo de una vez. */
type Todo = { cuotas: number; s: PorMoneda }

/**
 * El bloque de pago (el mismo que `helios_payment_block` en la base): los
 * bolívares de hoy y que otro día será la tasa de ese día, las cuentas,
 * «envíanos la foto del comprobante» y la frase de los niveles.
 *
 * Con `todo` (2026-10-21, Javier): también los bolívares de hoy de todo lo
 * que le queda, para que quien quiera pagarlo de una vez copie la cifra
 * exacta en vez de multiplicar la de una cuota (que puede errar en un
 * céntimo, y entonces el lector no reconoce el pago).
 */
/**
 * El bloque de pago con dos o más cuotas vencidas (2026-10-29, caso 3): la
 * más antigua y todo de una vez; si además hay cuotas por vencer, también lo
 * vencido («para ponerte al día»). Null si falta alguna tasa (se usa el de
 * un monto).
 */
export function bloqueDePagoVencidas(
  r: ResumenDelPaciente,
  antigua: PorMoneda,
  vencidas: PorMoneda,
  todo: Todo | null,
): string | null {
  const bsAntigua = bolivaresDeHoy(r, antigua)
  const bsVencidas = bolivaresDeHoy(r, vencidas)
  const bsTodo = todo ? bolivaresDeHoy(r, todo.s) : bsVencidas
  if (bsAntigua === null || bsVencidas === null || bsTodo === null) return null
  const todas: PorMoneda = new Map(todo ? todo.s : vencidas)
  const montos = [
    `💵 *Para pagar la más antigua hoy: ${bolivares(bsAntigua)}*`,
    ...(todo ? [`💵 *Para ponerte al día hoy: ${bolivares(bsVencidas)}*`] : []),
    `💰 *Para pagar todo de una vez hoy: ${bolivares(bsTodo)}*`,
    `Es el equivalente a la tasa BCV ${deLasMonedas(todas)} de hoy. Si pagas otro día, paga el equivalente a la tasa BCV de ese día.`,
  ].join('\n')
  return [
    montos,
    r.datos_de_pago ?? r.cuentas_de_cobro,
    '📸 Cuando pagues, envíanos la foto del comprobante por este chat.',
    FRASE_NIVEL,
  ].join('\n\n')
}

export function bloqueDePago(r: ResumenDelPaciente, s: PorMoneda, todo: Todo | null = null): string {
  const bs = bolivaresDeHoy(r, s)
  const bsTodo = todo ? bolivaresDeHoy(r, todo.s) : null
  const monto =
    bs !== null
      ? `💵 *Monto en bolívares hoy: ${bolivares(bs)}*\n` +
        `Es el equivalente a ${enSusMonedas(s)} a la tasa BCV ${deLasMonedas(s)} de hoy. ` +
        'Si pagas otro día, paga el equivalente a la tasa BCV de ese día.'
      : `💵 *Monto en bolívares*\nPagas el equivalente a ${enSusMonedas(s)} a la tasa BCV ${deLasMonedas(s)} del día en que pagues.`
  const deUnaVez =
    todo && bsTodo !== null
      ? `💰 *Para pagar todo de una vez hoy: ${bolivares(bsTodo)}*\n` +
        `Son tus ${todo.cuotas} cuotas pendientes (${enSusMonedas(todo.s)}).`
      : null
  return [
    monto,
    ...(deUnaVez ? [deUnaVez] : []),
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

/** El botón «Ya pagué» de los recordatorios: la foto y la referencia escrita. */
export function mensajeYaPague(nombre: string | null): string {
  return (
    `¡Gracias${hola(nombre)}! Envíanos por aquí la foto del comprobante 📸 y escribe también el número de referencia del pago. ` +
    'Así lo confirmamos más rápido.'
  )
}

// ─── El lector de comprobantes (docs/03 §6, con el lector activo) ──────────

/** La captura llegó y la lee el bot. */
export function mensajeComprobanteLeyendo(nombre: string | null): string {
  return `📄 ¡Gracias${hola(nombre)}! Recibimos tu comprobante.\nLo estamos verificando y te avisamos por aquí 💙`
}

/** «Ya pagué» con el lector activo: la foto, o los datos escritos. */
export function mensajeYaPagueConDatos(nombre: string | null): string {
  return (
    `¡Gracias${hola(nombre)}! Envíanos por aquí la foto del comprobante 📸\n` +
    'Si no la tienes, escribe *datos* y te pido los datos del pago.'
  )
}

/** El formulario de los datos de un Pago Móvil (banco, teléfono y referencia completa). */
export function mensajePedirDatosDePago(): string {
  return (
    'Escríbeme los datos de tu Pago Móvil ✍️ Copia este mensaje, completa cada línea y envíamelo:\n\n' +
    formularioDePago()
  )
}

/** Lo que falta del formulario. */
export function mensajeFaltanDatosDePago(campos: Campo[]): string {
  return `Me falta ${nombrarCampos(campos)}. Escríbelo así:\n\n${formularioDePago(campos)}`
}

/** Los datos están completos: se espera al banco. */
export function mensajeDatosDePagoRecibidos(nombre: string | null): string {
  return `¡Gracias${hola(nombre)}! Con estos datos buscamos tu pago en el banco y te avisamos por aquí en cuanto lo confirmemos 💙`
}

/** La referencia que pidió el bot llegó. */
export function mensajeReferenciaRecibida(nombre: string | null): string {
  return `¡Gracias${hola(nombre)}! Ya lo estamos verificando y te avisamos por aquí 💙`
}

/** El bot no pudo seguir: lo revisa una persona. */
export function mensajeLoRevisaElEquipo(nombre: string | null): string {
  return `Gracias${hola(nombre)}. Alguien de nuestro equipo lo revisa y te escribe por aquí 💙`
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
      '\nAún estás a tiempo de ponerte al día 💙' +
      // 2026-10-29: con dos o más, que puede empezar por la más antigua.
      (n > 1 ? ` Puedes pagar ${n === 2 ? 'las dos' : 'todas'} o empezar por la más antigua.` : '')
  } else {
    const { f, c } = aPagar[0]
    cabeza =
      '💳 *Tu próxima cuota*\n' +
      `${montoDeLaCuota(f, c)} · vence el ${diaLargo(c.due_date)}\n` +
      `Consulta con ${medicoRefDe(f)} (orden #${f.orden})`
  }

  // Todo lo que le queda, si es más de lo que toca. No con un pago en
  // revisión: sus cuotas no entran en lo que el bot reconoce al leer el
  // siguiente comprobante.
  const pendientes = r.financiamientos.flatMap((f) => f.cuotas.map((c) => ({ f, c })))
  const todo = pendientes.length > aPagar.length && !r.pago_en_revision ? { cuotas: pendientes.length, s: porMoneda(pendientes) } : null

  // Dos o más vencidas: la más antigua (las de su fecha) y todo de una vez.
  let bloque: string | null = null
  if (vencidas && aPagar.length > 1) {
    const primera = aPagar[0].c.due_date
    bloque = bloqueDePagoVencidas(r, porMoneda(aPagar.filter((x) => x.c.due_date === primera)), total, todo)
  }

  return [cabeza, ...(r.pago_en_revision ? [PAGO_EN_REVISION] : []), bloque ?? bloqueDePago(r, total, todo)].join('\n\n')
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

/**
 * Su nivel, su saldo total y lo disponible, en líneas seguidas. Sin nivel
 * (nivel 0 o tope en 0, o una base que no lo manda), solo lo disponible.
 */
function bloqueDelSaldo(r: ResumenDelPaciente): string | null {
  const lineas: string[] = []
  const limite = Number(r.limite_usd ?? 0)
  if (r.nivel && r.nivel > 0 && limite > 0) {
    lineas.push(`🏅 *${r.nivel_nombre?.trim() || `Nivel ${r.nivel}`}*`)
    lineas.push(`💰 *Saldo total: ${dinero(limite)}*`)
  }
  const disponible = lineaDisponible(r)
  if (disponible) lineas.push(disponible)
  return lineas.length > 0 ? lineas.join('\n') : null
}

/**
 * «Mi saldo y cuotas»: su nivel, su saldo total y lo disponible; los pagos en
 * cuotas activos con lo que falta por pagar (si no hay, nada); y que pagando a
 * tiempo sube de nivel. Sin la lista de pagos terminados: el mensaje se hacía
 * largo (2026-10-22).
 */
export function mensajeFinanciamientos(r: ResumenDelPaciente): string {
  const partes: string[] = ['📋 *Tu cuenta Helios*']
  const saldo = bloqueDelSaldo(r)
  if (saldo) partes.push(saldo)

  if (r.financiamientos.length > 0) {
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

  if (r.pago_en_revision) partes.push('🔎 Tienes un pago en revisión: aún no aparece descontado.')
  partes.push(FRASE_SUBIR_DE_NIVEL)
  return partes.join('\n\n')
}

/** ¿Hay algo que pagar? (para ofrecer el botón «Pagar mi cuota»). */
export function tienePendientes(r: ResumenDelPaciente): boolean {
  return r.financiamientos.some((f) => f.cuotas.length > 0)
}
