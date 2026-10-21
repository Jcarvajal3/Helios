import {
  comoFila,
  filaONula,
  filas,
  numero,
  numeroONulo,
  texto,
  textoONulo,
} from '@/lib/json'
import { leerMoneda } from '@/components/ui'
import type { Moneda } from '@/components/ui'
import { leerMonto } from '@/lib/montos'

// ═══════════════════════════════════════════════════════════════════════════
// Nuevo pago en cuotas: lo que va y viene de las tres RPC del alta.
//
//   helios_patient_eligibility  → leerElegibilidad
//   helios_fx_today             → leerTasasDeHoy
//   preview_patient_charge      → leerVistaPrevia
//   create_patient_charge       → leerFinanciamiento  (helios_charge_for_staff)
//   staff_resend_receipt        → leerReenvio
//
// Puro: los lectores reciben el `unknown` de la RPC y devuelven el tipo bueno
// (docs/01-CONTRATO-RPC §1.1–1.4). Las llamadas viven en `registroApi.ts`,
// que es lo único que toca Supabase.
// ═══════════════════════════════════════════════════════════════════════════

// ── 1. Elegibilidad ───────────────────────────────────────────────────────

/**
 * Las tres respuestas de la consulta de cédula.
 *
 * **`no_disponible` no dice por qué, y no es un olvido.** Mora, lista negra,
 * bloqueo o cupo agotado se contestan igual: una clínica nunca sabe la deuda
 * de un paciente con otra (plan §5, privacidad entre clínicas). El tipo no
 * tiene un campo de motivo para que ninguna pantalla pueda enseñarlo.
 */
export type Elegibilidad =
  | { estado: 'nuevo'; minChargeUsd: number; limiteUsd: number }
  | {
      estado: 'disponible'
      disponibleUsd: number
      minChargeUsd: number
      /** Completos desde el 2026-10-21: la secretaria se los lee al paciente. */
      nombre: string | null
      /** «0414-1234567». */
      telefono: string | null
      email: string | null
    }
  | { estado: 'no_disponible'; mensaje: string; whatsappHelios: string | null }

/** El mínimo del contrato cuando la base no lo manda (§3, `min_charge_usd`). */
export const MINIMO_POR_DEFECTO = 10

/** El texto neutro de «no disponible» cuando la base no manda el suyo. */
export const NO_DISPONIBLE_POR_DEFECTO =
  'Esta persona no puede pagar en cuotas con Helios. Si tiene dudas, puede escribir a Helios.'

/**
 * El porcentaje de la Comisión Helios cuando la base no lo manda
 * (parámetro `consumer_fee_pct`, 12 % + IVA desde el 2026-10-06). Lo paga el
 * paciente; a la clínica no le cuesta nada.
 */
export const COMISION_DE_SERVICIO_POR_DEFECTO = 12

/**
 * Lee la respuesta de `helios_patient_eligibility`.
 *
 * Un `estado` que no es ninguno de los tres es un fallo del contrato y se
 * lanza: tratarlo como «nuevo» abriría el alta de alguien que la base no ha
 * dejado pasar, y como «no disponible» le diría que no a un paciente bueno.
 */
export function leerElegibilidad(v: unknown): Elegibilidad {
  const r = comoFila(v)
  const minimo = numeroONulo(r.min_charge_usd) ?? MINIMO_POR_DEFECTO

  switch (r.estado) {
    case 'nuevo':
      return { estado: 'nuevo', minChargeUsd: minimo, limiteUsd: numero(r.limite_usd) }
    case 'disponible':
      return {
        estado: 'disponible',
        disponibleUsd: numero(r.disponible_usd),
        minChargeUsd: minimo,
        nombre: textoONulo(r.nombre),
        telefono: textoONulo(r.telefono),
        email: textoONulo(r.email),
      }
    case 'no_disponible':
      return {
        estado: 'no_disponible',
        mensaje: textoONulo(r.mensaje) ?? NO_DISPONIBLE_POR_DEFECTO,
        whatsappHelios: textoONulo(r.whatsapp_helios),
      }
    default:
      throw new Error('La consulta de la cédula devolvió una respuesta que el panel no entiende.')
  }
}

/** El máximo que puede pagar en cuotas hoy: lo disponible o, si es nuevo, el límite. */
export function maximoParaFinanciar(e: Elegibilidad): number | null {
  if (e.estado === 'nuevo') return e.limiteUsd
  if (e.estado === 'disponible') return e.disponibleUsd
  return null
}

// ── 1b. La moneda de la consulta (2026-10-07) ─────────────────────────────

/**
 * Las tasas BCV de hoy (`helios_fx_today`): bolívares por dólar, bolívares
 * por euro y la cruzada, dólares por euro. Cualquiera puede faltar: el BCV
 * no publica en feriados y la tasa del euro se carga aparte.
 */
export type TasasDeHoy = {
  businessDate: string | null
  /** Bs por dólar. */
  usd: number | null
  /** Bs por euro. */
  eur: number | null
  /** Dólares por euro: con lo que la base pasa una consulta en euros a su libro en dólares. */
  usdPorEuro: number | null
}

function tasaPositiva(v: unknown): number | null {
  const n = numeroONulo(v)
  return n !== null && n > 0 ? n : null
}

export function leerTasasDeHoy(v: unknown): TasasDeHoy {
  const r = comoFila(v)
  return {
    businessDate: textoONulo(r.business_date),
    usd: tasaPositiva(filaONula(r.usd)?.rate),
    eur: tasaPositiva(filaONula(r.eur)?.rate),
    usdPorEuro: tasaPositiva(r.usd_per_eur),
  }
}

/** Bolívares por unidad de la moneda, hoy. `null` si el BCV no la tiene. */
export function tasaBcvDe(t: TasasDeHoy | undefined, moneda: Moneda): number | null {
  if (!t) return null
  return moneda === 'EUR' ? t.eur : t.usd
}

/** «del dólar», «del euro»: para «a la tasa BCV del euro de hoy». */
export const DE_LA_MONEDA: Record<Moneda, string> = { USD: 'del dólar', EUR: 'del euro' }

/**
 * El mínimo y el máximo del monto en la moneda de la consulta, con la tasa
 * cruzada de hoy. El libro, el límite de $150 y el mínimo de $10 siguen en
 * dólares; esto los pasa a euros IGUAL que la base
 * (`helios_assert_charge_amount_in`): el mínimo redondeado hacia arriba al
 * céntimo y el máximo truncado. Así lo que el panel deja pasar lo deja pasar
 * la base, y lo que rechaza lo rechaza con la misma cifra.
 *
 * `null` si se eligió euros y no hay tasa del euro: sin ella no se sabe
 * cuánto es nada, y el paso del monto no deja seguir.
 *
 * El épsilon es por la coma flotante: 10 / 1,25 × 100 puede dar 800,0000001,
 * y redondear eso hacia arriba diría €8,01 donde la base dice €8,00.
 */
export function limitesEnMoneda(
  limitesUsd: { minimo: number; maximo: number | null },
  moneda: Moneda,
  usdPorEuro: number | null,
): { minimo: number; maximo: number | null } | null {
  if (moneda === 'USD') return limitesUsd
  if (usdPorEuro === null || usdPorEuro <= 0) return null
  return {
    minimo: Math.ceil((limitesUsd.minimo / usdPorEuro) * 100 - 1e-6) / 100,
    maximo:
      limitesUsd.maximo === null
        ? null
        : Math.floor((limitesUsd.maximo / usdPorEuro) * 100 + 1e-6) / 100,
  }
}

/**
 * Los bolívares de un monto a la tasa de hoy, al céntimo. Solo informativo:
 * el paciente paga a la tasa del día en que paga.
 */
export function enBolivares(monto: number, tasa: number | null): number | null {
  if (tasa === null) return null
  return Math.round(monto * tasa * 100) / 100
}

// ── 2. Monto ──────────────────────────────────────────────────────────────

/**
 * El monto de la consulta ya leído, o por qué todavía no vale.
 *
 * Mismas reglas que la base: libre, con dos decimales como mucho, desde el
 * mínimo y dentro de lo disponible. El texto del tope repite el de la base
 * («El monto supera lo disponible ($X)») para que la secretaria no lea dos
 * frases distintas para lo mismo.
 *
 * Los límites y el `formato` van en la moneda de la consulta
 * (`limitesEnMoneda`): en euros, «El monto mínimo es €8,88», como la base.
 */
export function leerMontoDeConsulta(
  escrito: string,
  limites: { minimo: number; maximo: number | null },
  formato: (monto: number) => string,
): { ok: true; monto: number } | { ok: false; problema: string } {
  if (escrito.trim() === '') return { ok: false, problema: 'Escribe el monto de la consulta.' }

  const monto = leerMonto(escrito)
  if (monto === null) return { ok: false, problema: 'No entendemos ese monto. Escríbelo como 45 o 45,50.' }
  if (monto <= 0) return { ok: false, problema: 'El monto tiene que ser mayor que cero.' }
  if (Math.abs(monto * 100 - Math.round(monto * 100)) > 1e-6) {
    return { ok: false, problema: 'El monto lleva como mucho dos decimales.' }
  }
  if (monto < limites.minimo) {
    return { ok: false, problema: `El monto mínimo es ${formato(limites.minimo)}.` }
  }
  if (limites.maximo !== null && monto > limites.maximo) {
    return {
      ok: false,
      problema: `El monto supera lo disponible (${formato(limites.maximo)}).`,
    }
  }
  return { ok: true, monto: Math.round(monto * 100) / 100 }
}

/** El concepto que se propone. Genérico a propósito: viaja en un correo. */
export const CONCEPTO_SUGERIDO = 'Consulta'
export const TOPE_CONCEPTO = 80

// ── 3. Vista previa ───────────────────────────────────────────────────────

export type CuotaDelPlan = {
  sequence: number
  dueDate: string
  /** Lo que paga el paciente en esa cuota: su mitad de la consulta más su
   *  mitad de la Comisión Helios. En dólares: lo del libro. */
  amountUsd: number
  /** Lo mismo en la moneda de la orden: lo que se enseña. */
  amountCur: number
  /** Esa cuota en bolívares a la tasa de HOY, o null sin tasa. Informativo:
   *  el paciente paga a la tasa del día en que paga. */
  amountVes: number | null
}

/**
 * Las cifras `Usd` son dólares de verdad (el libro); las `Cur`, las mismas en
 * la moneda de la orden, que es lo que se enseña. En dólares son iguales.
 */
export type VistaPrevia = {
  moneda: Moneda
  /** Bs por unidad de la moneda de la orden, hoy. Null sin tasa. */
  tasaBcv: number | null
  /** Lo que vale la consulta y lo que se le paga a la clínica. */
  baseUsd: number
  baseCur: number
  feePct: number
  /** La Comisión Helios y su IVA, por separado. NUNCA se suman a la base. */
  feeUsd: number
  feeVatUsd: number
  feeCur: number
  feeVatCur: number
  businessDate: string | null
  cuotas: CuotaDelPlan[]
  lateFeeUsd: number | null
  lateFeeGraceDays: number | null
  /** `false` si no cabe en el disponible del paciente conocido. */
  cabe: boolean
  disponibleUsd: number | null
  /** Lo disponible en la moneda de la orden, truncado como en la base. */
  disponibleCur: number | null
}

function leerCuotas(v: unknown): CuotaDelPlan[] {
  return filas(v)
    .map((c) => {
      const usd = numero(c.amount_usd)
      return {
        sequence: numero(c.sequence),
        dueDate: texto(c.due_date),
        amountUsd: usd,
        // Una base sin la moneda nueva: la orden es en dólares, misma cifra.
        amountCur: numeroONulo(c.amount_cur) ?? usd,
        amountVes: numeroONulo(c.amount_ves),
      }
    })
    .sort((a, b) => a.sequence - b.sequence)
}

export function leerVistaPrevia(v: unknown): VistaPrevia {
  const r = comoFila(v)
  const baseUsd = numero(r.base_usd)
  const feeUsd = numero(r.consumer_fee_usd)
  const feeVatUsd = numero(r.consumer_fee_vat_usd)
  const disponibleUsd = numeroONulo(r.disponible_usd)
  return {
    moneda: leerMoneda(r.currency),
    tasaBcv: numeroONulo(r.tasa_bcv),
    baseUsd,
    baseCur: numeroONulo(r.base_cur) ?? baseUsd,
    feePct: numeroONulo(r.consumer_fee_pct) ?? COMISION_DE_SERVICIO_POR_DEFECTO,
    feeUsd,
    feeVatUsd,
    feeCur: numeroONulo(r.consumer_fee_cur) ?? feeUsd,
    feeVatCur: numeroONulo(r.consumer_fee_vat_cur) ?? feeVatUsd,
    businessDate: textoONulo(r.business_date),
    cuotas: leerCuotas(r.installments),
    lateFeeUsd: numeroONulo(r.late_fee_usd),
    lateFeeGraceDays: numeroONulo(r.late_fee_grace_days),
    // Si la base no lo dice, se asume que cabe: la vista previa ya validó el
    // monto contra el disponible y, si no cupiera, `create_patient_charge`
    // lo rechaza con su propio texto.
    cabe: r.cabe === false ? false : true,
    disponibleUsd,
    disponibleCur: numeroONulo(r.disponible_cur) ?? disponibleUsd,
  }
}

/**
 * «Comisión Helios 12% + IVA»: el rótulo de la ÚNICA línea donde aparece la
 * Comisión Helios en la pantalla de la clínica. Con el porcentaje que manda
 * la base. Al lado va siempre `LO_PAGA_EL_PACIENTE`.
 */
export function rotuloDelServicio(feePct: number): string {
  const pct = Number.isInteger(feePct) ? String(feePct) : String(feePct).replace('.', ',')
  return `Comisión Helios ${pct}% + IVA`
}

/**
 * Junto a la Comisión Helios en todo desglose que ve el médico (panel y bot):
 * que nadie piense que se la descuentan (Javier, 2026-10-13).
 */
export const LO_PAGA_EL_PACIENTE = '(Lo paga el paciente)'

/**
 * La regla del cargo por atraso, en una frase para leérsela al paciente.
 * `null` si la base no mandó las cifras: mejor no decir nada que una regla
 * inventada. `null` también con el cargo en 0: desde el 2026-10-07 no se
 * cobran cargos por mora (`late_fee_usd` = 0) y no se promete lo que no se
 * cobra. Si vuelve a valer algo, la frase vuelve sola.
 */
export function reglaDelAtraso(
  p: Pick<VistaPrevia, 'lateFeeUsd' | 'lateFeeGraceDays'>,
  formato: (usd: number) => string,
): string | null {
  if (p.lateFeeUsd === null || p.lateFeeGraceDays === null || p.lateFeeUsd <= 0) return null
  const dias = p.lateFeeGraceDays === 1 ? '1 día' : `${p.lateFeeGraceDays} días`
  return `Si una cuota se paga con más de ${dias} de atraso, se suma un cargo de ${formato(
    p.lateFeeUsd,
  )} a esa cuota.`
}

const DIAS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado']

/**
 * 'jueves' para '2026-10-08'. Al paciente se le dice «el jueves 8», no
 * «el 08/10/26»: es como se apunta una cita.
 *
 * En UTC a propósito: una columna `date` no tiene hora ni zona, y construirla
 * con la hora local del navegador la movería de día.
 */
export function diaDeLaSemana(fecha: string): string {
  const [y = 1970, m = 1, d = 1] = fecha.slice(0, 10).split('-').map(Number)
  return DIAS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()] ?? ''
}

// ── 4. El pago en cuotas creado ───────────────────────────────────────────

/**
 * Estado del comprobante por correo (plan §7.3).
 *
 *   pendiente       en cola; sale en el minuto siguiente
 *   enviado         el proveedor lo aceptó
 *   entregado       llegó al buzón
 *   rebotado        el correo no existe o no acepta: no llegó
 *   sin_configurar  Helios todavía no tiene el envío de correos listo
 *   sin_enviar      la orden espera el «Sí» del paciente: sale al aceptar
 */
export type EstadoDelComprobante =
  | 'pendiente'
  | 'enviado'
  | 'entregado'
  | 'rebotado'
  | 'sin_configurar'
  | 'sin_enviar'

const ESTADOS_DEL_COMPROBANTE: readonly EstadoDelComprobante[] = [
  'pendiente',
  'enviado',
  'entregado',
  'rebotado',
  'sin_configurar',
  'sin_enviar',
]

/** Un estado conocido, o `null`: un estado nuevo no se pinta como otro. */
export function leerEstadoDelComprobante(v: unknown): EstadoDelComprobante | null {
  return ESTADOS_DEL_COMPROBANTE.find((e) => e === v) ?? null
}

/** Cómo se ve cada estado en una insignia. */
export const COMPROBANTE: Record<
  EstadoDelComprobante,
  { texto: string; tone: 'neutral' | 'warning' | 'error' | 'success' }
> = {
  pendiente: { texto: 'Pendiente', tone: 'neutral' },
  enviado: { texto: 'Enviado', tone: 'success' },
  entregado: { texto: 'Entregado', tone: 'success' },
  rebotado: { texto: 'Rebotado', tone: 'error' },
  sin_configurar: { texto: 'Sin configurar', tone: 'warning' },
  sin_enviar: { texto: 'Sin enviar', tone: 'neutral' },
}

/**
 * La frase de la pantalla de éxito sobre el comprobante, con el correo
 * enmascarado que manda la base (es el REGISTRADO, no el tecleado).
 */
export function fraseDelComprobante(
  estado: EstadoDelComprobante | null,
  correo: string | null,
): string {
  const a = correo ? ` a ${correo}` : ' al correo del paciente'
  switch (estado) {
    case 'enviado':
    case 'entregado':
      return `Comprobante enviado${a}.`
    case 'rebotado':
      return `El correo${correo ? ` ${correo}` : ''} rebotó: el comprobante no llegó. Avisa a Helios para corregirlo.`
    case 'sin_configurar':
      return 'El envío de correos de Helios todavía no está configurado: el comprobante saldrá en cuanto lo esté.'
    case 'sin_enviar':
      return `El comprobante sale${a} en cuanto el paciente acepte.`
    case 'pendiente':
    case null:
      return `Comprobante en camino${a}. Llega en uno o dos minutos.`
  }
}

// ── 4b. La confirmación del paciente (contrato §1.3.1) ─────────────────────

/**
 * Cómo va la pregunta al paciente por WhatsApp.
 *
 *   por_enviar   en la cola de WhatsApp; sale en segundos
 *   enviada      WhatsApp la aceptó
 *   entregada    llegó a su teléfono
 *   leida        la abrió
 *   fallida      no se le pudo escribir (teléfono sin WhatsApp, por ejemplo)
 *   aceptada     respondió Sí: el pago en cuotas está confirmado
 *   rechazada    respondió No (o ya no podía pagar en cuotas)
 *   vencida      no respondió a tiempo
 */
export type EstadoDeLaConfirmacion =
  | 'por_enviar'
  | 'enviada'
  | 'entregada'
  | 'leida'
  | 'fallida'
  | 'aceptada'
  | 'rechazada'
  | 'vencida'

const ESTADOS_DE_LA_CONFIRMACION: readonly EstadoDeLaConfirmacion[] = [
  'por_enviar',
  'enviada',
  'entregada',
  'leida',
  'fallida',
  'aceptada',
  'rechazada',
  'vencida',
]

/** Cómo se ve cada estado en una insignia. */
export const CONFIRMACION: Record<
  EstadoDeLaConfirmacion,
  { texto: string; tone: 'neutral' | 'warning' | 'error' | 'success' }
> = {
  por_enviar: { texto: 'Enviando', tone: 'neutral' },
  enviada: { texto: 'Enviada', tone: 'neutral' },
  entregada: { texto: 'Entregada', tone: 'neutral' },
  leida: { texto: 'Leída', tone: 'neutral' },
  fallida: { texto: 'No se pudo enviar', tone: 'error' },
  aceptada: { texto: 'Aceptó', tone: 'success' },
  rechazada: { texto: 'Rechazada', tone: 'error' },
  vencida: { texto: 'Vencida', tone: 'warning' },
}

export type Confirmacion = {
  status: EstadoDeLaConfirmacion | null
  /** El teléfono REGISTRADO al que se le preguntó, enmascarado. */
  telefonoEnmascarado: string | null
  sentAt: string | null
  answeredAt: string | null
  resendsToday: number
}

export function leerConfirmacion(v: unknown): Confirmacion | null {
  const r = filaONula(v)
  if (!r) return null
  return {
    status: ESTADOS_DE_LA_CONFIRMACION.find((e) => e === r.status) ?? null,
    telefonoEnmascarado: textoONulo(r.telefono_enmascarado),
    sentAt: textoONulo(r.sent_at),
    answeredAt: textoONulo(r.answered_at),
    resendsToday: numeroONulo(r.resends_today) ?? 0,
  }
}

/** La orden todavía espera la respuesta del paciente. */
export function esperaAlPaciente(f: Pick<Financiamiento, 'status'>): boolean {
  return f.status === 'pending'
}

/** Minutos enteros que le quedan a la orden (0 si ya venció o no tiene plazo). */
export function minutosRestantes(expiresAt: string | null, ahora: number): number {
  if (!expiresAt) return 0
  const fin = Date.parse(expiresAt)
  if (Number.isNaN(fin)) return 0
  return Math.max(0, Math.ceil((fin - ahora) / 60_000))
}

/** «1 h 25 min», «40 min», «menos de 1 min». */
export function textoDelPlazo(minutos: number): string {
  if (minutos <= 0) return 'menos de 1 min'
  const h = Math.floor(minutos / 60)
  const m = minutos % 60
  if (h === 0) return `${m} min`
  return m === 0 ? `${h} h` : `${h} h ${m} min`
}

/** La frase de la pantalla de espera, según cómo va la pregunta. */
export function fraseDeLaEspera(c: Confirmacion | null): string {
  const a = c?.telefonoEnmascarado ? ` al ${c.telefonoEnmascarado}` : ' al paciente'
  switch (c?.status ?? null) {
    case 'fallida':
      return `No pudimos escribirle por WhatsApp${a}. Revisa con Helios que el teléfono tenga WhatsApp y reenvía.`
    case 'leida':
      return 'El paciente ya leyó el mensaje. Falta que responda Sí.'
    case 'entregada':
    case 'enviada':
      return `Le enviamos un WhatsApp${a} con el resumen. Tiene que responder Sí para aceptar.`
    default:
      return `Enviando un WhatsApp${a} con el resumen. Tiene que responder Sí para aceptar.`
  }
}

export type Financiamiento = {
  id: string
  orderNumber: number
  /** pending (espera al paciente) · confirmed · declined · expired · voided · reverted */
  status: string
  /** Hasta cuándo espera la orden el «Sí». Solo en pending y expired. */
  expiresAt: string | null
  channel: 'panel' | 'whatsapp'
  confirmation: Confirmacion | null
  declineReason: 'paciente' | 'no_disponible' | null
  /** El texto que se enseña si se rechazó (el neutro, si ya no podía pagar en cuotas). */
  declineMessage: string | null
  createdAt: string | null
  businessDate: string | null
  /** La moneda en la que cobró la clínica. */
  moneda: Moneda
  /** La consulta: lo que se le paga a la clínica. Sin la Comisión Helios. */
  merchantSaleUsd: number
  /** La misma consulta en la moneda de la orden: lo que se enseña. */
  merchantSaleCur: number
  concept: string | null
  beneficiaryName: string | null
  patientName: string | null
  documentoEnmascarado: string | null
  emailEnmascarado: string | null
  cuotas: CuotaDelPlan[]
  /** Del desglose; la Comisión Helios solo se enseña como línea aparte. */
  feePct: number
  feeUsd: number | null
  feeVatUsd: number | null
  feeCur: number | null
  feeVatCur: number | null
  receipt: EstadoDelComprobante | null
  registeredBy: string | null
  staffCommissionUsd: number | null
}

export function leerFinanciamiento(v: unknown): Financiamiento {
  const r = comoFila(v)
  const paciente = filaONula(r.patient) ?? {}
  const desglose = filaONula(r.breakdown) ?? {}
  const recibo = filaONula(r.receipt) ?? {}

  const id = textoONulo(r.id) ?? textoONulo(r.charge_id)
  if (id === null) throw new Error('El pago en cuotas se registró pero la respuesta no trae su número.')

  const base = numeroONulo(r.merchant_sale_usd) ?? numero(desglose.base_usd)
  const fee = numeroONulo(desglose.consumer_fee_usd)
  const feeVat = numeroONulo(desglose.consumer_fee_vat_usd)

  return {
    id,
    orderNumber: numero(r.order_number),
    status: texto(r.status, 'confirmed'),
    expiresAt: textoONulo(r.expires_at),
    channel: r.channel === 'whatsapp' ? 'whatsapp' : 'panel',
    confirmation: leerConfirmacion(r.confirmation),
    declineReason:
      r.decline_reason === 'paciente' || r.decline_reason === 'no_disponible'
        ? r.decline_reason
        : null,
    declineMessage: textoONulo(r.decline_message),
    createdAt: textoONulo(r.created_at),
    businessDate: textoONulo(r.business_date),
    moneda: leerMoneda(r.currency),
    merchantSaleUsd: base,
    merchantSaleCur: numeroONulo(r.merchant_sale_cur) ?? numeroONulo(desglose.base_cur) ?? base,
    concept: textoONulo(r.concept),
    beneficiaryName: textoONulo(r.beneficiary_name),
    patientName: textoONulo(paciente.nombre),
    documentoEnmascarado: textoONulo(paciente.documento_enmascarado),
    emailEnmascarado: textoONulo(paciente.email_enmascarado),
    cuotas: leerCuotas(r.installments),
    feePct: numeroONulo(desglose.consumer_fee_pct) ?? porcentajeDelServicio(base, fee),
    feeUsd: fee,
    feeVatUsd: feeVat,
    feeCur: numeroONulo(desglose.consumer_fee_cur) ?? fee,
    feeVatCur: numeroONulo(desglose.consumer_fee_vat_cur) ?? feeVat,
    receipt: leerEstadoDelComprobante(recibo.status),
    registeredBy: textoONulo(r.registered_by),
    staffCommissionUsd: numeroONulo(r.staff_commission_usd),
  }
}

/**
 * El porcentaje de la Comisión Helios a partir de sus cifras, para el
 * rótulo del desglose cuando la respuesta no lo trae (`helios_charge_for_staff`
 * manda el importe, no el porcentaje). Con una décima: $12 sobre $100 es 12.
 */
export function porcentajeDelServicio(baseUsd: number, feeUsd: number | null): number {
  if (feeUsd === null || baseUsd <= 0) return COMISION_DE_SERVICIO_POR_DEFECTO
  return Math.round((feeUsd / baseUsd) * 1000) / 10
}

/**
 * Si lo que devolvió la base es lo que se pidió.
 *
 * `create_patient_charge` es idempotente: la misma clave devuelve el MISMO
 * pago en cuotas aunque los datos hayan cambiado. Eso protege del doble clic
 * y de la recarga, pero tiene un caso raro: la respuesta de un alta se
 * pierde (la red cae justo entonces), la secretaria corrige el monto o la
 * cédula y vuelve a confirmar. La base contesta con el de antes, y la
 * pantalla tiene que decirlo en vez de celebrar un alta que no es la que se
 * pidió.
 *
 * Se compara lo que la respuesta deja ver: el monto en su moneda (€100 no
 * son los $100 que se pidieron) y los últimos cuatro dígitos de la cédula
 * enmascarada.
 */
export function coincideConLoPedido(
  f: Pick<Financiamiento, 'merchantSaleCur' | 'moneda' | 'documentoEnmascarado'>,
  pedido: { amount: number; moneda: Moneda; document: string },
): boolean {
  if (f.moneda !== pedido.moneda) return false
  if (Math.abs(f.merchantSaleCur - pedido.amount) >= 0.005) return false

  const visibles = (f.documentoEnmascarado ?? '').replace(/\D/g, '')
  if (visibles === '') return true
  return pedido.document.replace(/\D/g, '').endsWith(visibles)
}

// ── 5. Reenviar el comprobante ────────────────────────────────────────────

export type Reenvio = { emailEnmascarado: string | null; status: EstadoDelComprobante | null }

export function leerReenvio(v: unknown): Reenvio {
  const r = comoFila(v)
  if (r.ok === false) throw new Error('No se pudo reenviar el comprobante.')
  return {
    emailEnmascarado: textoONulo(r.email_enmascarado),
    status: leerEstadoDelComprobante(r.status),
  }
}

// ── 6. A qué paso lleva cada error ────────────────────────────────────────

export type PasoDelAlta = 'cedula' | 'datos' | 'monto' | 'confirmar'

/**
 * Dónde se corrige lo que la base rechazó, para ofrecer el botón que lleva
 * ahí. `null` si no es un dato de la secretaria (permiso, mantenimiento…):
 * ahí no hay nada que corregir en el formulario.
 *
 * Se decide por el texto, que es el contrato (§1.3): la base lanza casi todo
 * con el mismo `22023` y lo que cambia es la frase.
 */
export function pasoDelError(mensaje: string | undefined, esNuevo: boolean): PasoDelAlta | null {
  if (!mensaje) return null
  const m = mensaje.toLowerCase()

  // Con las dos redacciones: la de antes («No podemos financiar a esta
  // persona») y la de ahora («Esta persona no puede pagar en cuotas»).
  if (m.includes('no podemos financiar') || m.includes('no puede pagar en cuotas')) return 'cedula'
  if (/monto|disponible/.test(m)) return 'monto'
  if (
    esNuevo &&
    /mayor de edad|tel[eé]fono|correo|referencia|nombre|apellido|nacimiento|direcci[oó]n|ciudad|estado|sexo/.test(
      m,
    )
  ) {
    return 'datos'
  }
  return null
}

/** El `errcode` de un error de PostgREST, si lo trae. */
export function codigoDeError(error: unknown): string | null {
  if (typeof error !== 'object' || error === null) return null
  const code = (error as { code?: unknown }).code
  return typeof code === 'string' && code !== '' ? code : null
}

/**
 * Si el error viene de la propia base —una RPC que se negó con su texto— y
 * no de la red. Solo entonces es seguro decir que no se registró nada: un
 * fallo de red en pleno alta puede haber llegado a crear el pago en cuotas.
 */
export function esRechazoDeLaBase(error: unknown): boolean {
  const code = codigoDeError(error)
  return code !== null && /^[0-9A-Z]{5}$/.test(code)
}
