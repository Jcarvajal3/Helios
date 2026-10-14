import { whatsappNumber } from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import { unoDe } from '@/lib/busqueda'
import { comoFila, numero, numeroONulo, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Los avisos: lo que el equipo le manda a cada paciente (contrato §2.2).
//
// Helios no tiene app: los recordatorios los generan los crons de la base en
// `outbound_messages` y una persona los manda uno a uno por WhatsApp desde la
// cola de «Avisos de hoy». Los correos (el comprobante y la víspera) salen
// solos, y aquí solo se miran y se reenvían.
//
// Módulo puro: lectura de las filas, el enlace de `wa.me`, el orden de la
// cola y los recuentos. Lo prueba `avisos.test.ts`; las llamadas viven en
// `api.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** `whatsapp` sale solo por la API (360dialog); `whatsapp_manual` lo manda una persona. */
export type CanalAviso = 'whatsapp_manual' | 'email' | 'whatsapp'
export const CANALES: readonly CanalAviso[] = ['whatsapp_manual', 'email', 'whatsapp']

export type EstadoAviso = 'pendiente' | 'enviado' | 'omitido' | 'fallido'
export const ESTADOS_AVISO: readonly EstadoAviso[] = ['pendiente', 'enviado', 'omitido', 'fallido']

export const ESTADO_AVISO: Record<EstadoAviso, { label: string; tone: BadgeTone }> = {
  pendiente: { label: 'Pendiente', tone: 'warning' },
  enviado: { label: 'Enviado', tone: 'success' },
  omitido: { label: 'Omitido', tone: 'neutral' },
  fallido: { label: 'Fallido', tone: 'error' },
}

/** Lo último que dijo el proveedor de correo (Resend) de un envío. */
export type EventoDeCorreo = 'sent' | 'delivered' | 'bounced' | 'complained'
const EVENTOS: readonly EventoDeCorreo[] = ['sent', 'delivered', 'bounced', 'complained']

/**
 * Las plantillas de la base (contrato §4), en el orden en que le llegan a un
 * paciente: primero la bienvenida, después los recordatorios de cada
 * vencimiento y al final lo que pasa con un pago. Es el orden de los grupos
 * de la cola.
 */
export const PLANTILLAS: ReadonlyArray<{
  clave: string
  rotulo: string
  canal: string
  cuando: string
}> = [
  { clave: 'comprobante_financiamiento', rotulo: 'Comprobante del financiamiento', canal: 'Correo', cuando: 'Al confirmar el financiamiento, y al reenviarlo' },
  { clave: 'confirmar_financiamiento', rotulo: 'Confirma tu financiamiento', canal: 'WhatsApp automático (plantilla de Meta)', cuando: 'Al registrar el financiamiento: el paciente acepta con Sí' },
  { clave: 'bienvenida', rotulo: 'Bienvenida', canal: 'WhatsApp (automático si el paciente aceptó por WhatsApp)', cuando: 'Al confirmar el financiamiento' },
  { clave: 'cuota_en_3_dias', rotulo: 'La cuota vence en 3 días', canal: 'WhatsApp automático y correo', cuando: 'Tres días antes del vencimiento, a las 12:00' },
  { clave: 'cuota_manana', rotulo: 'La cuota vence mañana', canal: 'WhatsApp automático y correo', cuando: 'La víspera del vencimiento, a las 19:00' },
  { clave: 'cuota_hoy', rotulo: 'La cuota vence hoy', canal: 'WhatsApp automático y correo', cuando: 'El día del vencimiento, a las 08:00' },
  { clave: 'cuota_vencida_d1', rotulo: 'Cuota vencida', canal: 'WhatsApp automático y correo', cuando: 'Un día después del vencimiento' },
  { clave: 'cargo_por_atraso_d4', rotulo: 'Cargo por atraso', canal: 'WhatsApp automático y correo', cuando: 'Cuatro días después del vencimiento, con el cargo ya cobrado' },
  { clave: 'pago_recibido', rotulo: 'Pago recibido', canal: 'Correo', cuando: 'Al aprobar un pago' },
  { clave: 'pago_rechazado', rotulo: 'Pago rechazado', canal: 'Correo', cuando: 'Al rechazar un pago' },
  { clave: 'cuenta_congelada', rotulo: 'Cuenta congelada', canal: 'WhatsApp automático y correo (apagado)', cuando: 'Al congelarse la cuenta por una cuota vencida' },
]

/**
 * Las variables que puede usar una plantilla (contrato §4).
 *
 * Desde el 2026-10-07 (`20261007000400_los_mensajes_dicen_la_moneda_y_los_bolivares`)
 * las de dinero traen su símbolo —la orden puede ir en dólares o en euros— y
 * las de cuotas y totales, los bolívares de hoy: el texto ya no lleva «$»
 * delante. Los ejemplos son los de una consulta de €100.
 */
export const VARIABLES_DE_PLANTILLA: ReadonlyArray<{ variable: string; que: string }> = [
  { variable: '{nombre}', que: 'El nombre del paciente' },
  { variable: '{clinica}', que: 'La clínica del financiamiento' },
  { variable: '{orden}', que: 'El número del financiamiento' },
  { variable: '{moneda}', que: 'La moneda de la orden: «dólar» o «euro» (para «la tasa BCV del {moneda}»)' },
  { variable: '{monto_consulta}', que: 'La consulta, con su símbolo: «€100»' },
  { variable: '{monto_cuota}', que: 'La cuota con su símbolo y sus bolívares de hoy: «€56,96 (Bs 56.063,47)»' },
  { variable: '{total}', que: 'El total con la comisión, con su símbolo: «€113,92»' },
  { variable: '{total_bs}', que: 'El total en bolívares a la tasa de hoy: «Bs 112.126,94»' },
  { variable: '{cargo_atraso}', que: 'El cargo por atraso, siempre en dólares: «$2»' },
  { variable: '{fecha}', que: 'El vencimiento de la cuota' },
  { variable: '{cuotas}', que: 'Las cuotas del financiamiento, con sus fechas' },
  { variable: '{whatsapp_helios}', que: 'El WhatsApp de Helios (Ajustes › Contacto)' },
  { variable: '{por_whatsapp}', que: 'Dónde mandar el comprobante: «por este chat» en WhatsApp, «por WhatsApp al 0414-…» en el correo' },
  { variable: '{cuentas_de_cobro}', que: 'Las cuentas de cobro activas, Pago Móvil y transferencia (Ajustes › Cuentas de cobro)' },
  { variable: '{tasa_bcv}', que: 'La tasa BCV del dólar del día' },
  { variable: '{tasa_bcv_euro}', que: 'La tasa BCV del euro del día' },
]

/** El nombre de una plantilla: el de la base si lo manda, si no el de la lista, si no la clave. */
export function rotuloDePlantilla(clave: string, rotuloDeLaBase?: string | null): string {
  return rotuloDeLaBase || PLANTILLAS.find((p) => p.clave === clave)?.rotulo || clave
}

/** Un aviso de la cola, o de su historial. */
export type Aviso = {
  id: string
  channel: CanalAviso
  templateKey: string
  templateLabel: string
  profileId: string | null
  patientName: string | null
  /** E.164, como lo guarda la base. */
  phone: string | null
  chargeId: string | null
  orderNumber: number | null
  dueDate: string | null
  /** El texto final, ya con las variables puestas. */
  renderedText: string
  status: EstadoAviso
  createdAt: string
  sentAt: string | null
  sentByName: string | null
  /** Solo los correos: a qué dirección, su id en Resend, lo último que dijo y cuántos intentos. */
  email: string | null
  providerId: string | null
  lastEvent: EventoDeCorreo | null
  attempts: number
}

/** Una fila de `admin_outbound_queue` o de `admin_outbound_history`. */
export function leerAviso(raw: unknown): Aviso {
  const r = comoFila(raw)
  const clave = texto(r.template_key)
  return {
    id: texto(r.id),
    channel: unoDe(CANALES, r.channel) ?? 'whatsapp_manual',
    templateKey: clave,
    templateLabel: rotuloDePlantilla(clave, textoONulo(r.template_label)),
    profileId: textoONulo(r.profile_id),
    patientName: textoONulo(r.patient_name),
    phone: textoONulo(r.phone_e164),
    chargeId: textoONulo(r.charge_id),
    orderNumber: numeroONulo(r.order_number),
    dueDate: textoONulo(r.due_date),
    renderedText: texto(r.rendered_text),
    // Un estado que no se conoce se enseña como pendiente: es el que pide mirarlo.
    status: unoDe(ESTADOS_AVISO, r.status) ?? 'pendiente',
    createdAt: texto(r.created_at),
    sentAt: textoONulo(r.sent_at),
    sentByName: textoONulo(r.sent_by_name),
    email: textoONulo(r.email),
    providerId: textoONulo(r.provider_id),
    lastEvent: unoDe(EVENTOS, r.last_event) ?? null,
    attempts: numero(r.attempts),
  }
}

// ── WhatsApp ───────────────────────────────────────────────────────────────

/**
 * El enlace que abre el chat con el texto ya escrito:
 * `https://wa.me/<dígitos>?text=<texto>`. Los dígitos, con el 58 delante,
 * como en la cobranza (`whatsappNumber`). `null` sin teléfono: un `wa.me/`
 * vacío abre WhatsApp sin chat y parece que funcionó.
 */
export function enlaceWhatsApp(telefono: string | null, textoDelMensaje: string): string | null {
  const numeroDeWhatsApp = whatsappNumber(telefono)
  if (!numeroDeWhatsApp) return null
  const mensaje = textoDelMensaje.trim()
  return mensaje
    ? `https://wa.me/${numeroDeWhatsApp}?text=${encodeURIComponent(mensaje)}`
    : `https://wa.me/${numeroDeWhatsApp}`
}

// ── La cola del día ────────────────────────────────────────────────────────

/** El puesto de una plantilla en la cola: las que no están en la lista, al final. */
function puestoDePlantilla(clave: string): number {
  const i = PLANTILLAS.findIndex((p) => p.clave === clave)
  return i < 0 ? PLANTILLAS.length : i
}

/** Los pendientes primero; a igual estado, lo que vence antes y después por nombre. */
function compararAvisos(a: Aviso, b: Aviso): number {
  const pa = a.status === 'pendiente' ? 0 : a.status === 'fallido' ? 1 : 2
  const pb = b.status === 'pendiente' ? 0 : b.status === 'fallido' ? 1 : 2
  return (
    pa - pb ||
    (a.dueDate ?? '9999-12-31').localeCompare(b.dueDate ?? '9999-12-31') ||
    (a.patientName ?? '').localeCompare(b.patientName ?? '', 'es') ||
    a.id.localeCompare(b.id)
  )
}

export type GrupoDeAvisos = {
  clave: string
  rotulo: string
  avisos: Aviso[]
  pendientes: number
}

/**
 * La cola agrupada por plantilla, en el orden de `PLANTILLAS`. Dentro de cada
 * grupo, los pendientes arriba. Un grupo sin avisos no sale.
 */
export function agruparPorPlantilla(avisos: ReadonlyArray<Aviso>): GrupoDeAvisos[] {
  const porClave = new Map<string, Aviso[]>()
  for (const a of avisos) porClave.set(a.templateKey, [...(porClave.get(a.templateKey) ?? []), a])

  return [...porClave.entries()]
    .sort(
      ([a], [b]) => puestoDePlantilla(a) - puestoDePlantilla(b) || a.localeCompare(b),
    )
    .map(([clave, delGrupo]) => {
      const ordenados = [...delGrupo].sort(compararAvisos)
      return {
        clave,
        rotulo: ordenados[0]?.templateLabel ?? rotuloDePlantilla(clave),
        avisos: ordenados,
        pendientes: ordenados.filter((a) => a.status === 'pendiente').length,
      }
    })
}

/**
 * Lo que se recorre en el modo cola: los pendientes, en el orden en que se
 * ven en la lista (grupo a grupo). Un aviso fallido también se puede
 * reintentar a mano, pero no entra solo: primero lo que nadie ha tocado.
 */
export function colaDeTrabajo(avisos: ReadonlyArray<Aviso>): Aviso[] {
  return agruparPorPlantilla(avisos).flatMap((g) => g.avisos.filter((a) => a.status === 'pendiente'))
}

export type RecuentoDeAvisos = Record<EstadoAviso, number> & { total: number }

export function contarAvisos(avisos: ReadonlyArray<Pick<Aviso, 'status'>>): RecuentoDeAvisos {
  const r: RecuentoDeAvisos = { total: avisos.length, pendiente: 0, enviado: 0, omitido: 0, fallido: 0 }
  for (const a of avisos) r[a.status]++
  return r
}

/**
 * Lo que falta para marcar un aviso, o `null` si se puede. Omitir exige una
 * nota (contrato §2.2): un aviso que no se manda sin decir por qué es un
 * paciente que no se enteró de su cuota.
 */
export function motivoParaNoMarcar(estado: EstadoAviso, nota: string): string | null {
  if (estado === 'pendiente') return 'Un aviso no se puede volver a poner pendiente.'
  if (estado === 'omitido' && nota.trim().length < 3) return 'Escribe por qué no se manda.'
  return null
}

// ── Correos ────────────────────────────────────────────────────────────────

/** Si el correo no llegó: rebotó o el paciente lo marcó como spam. */
export function correoRebotado(a: Pick<Aviso, 'lastEvent'>): boolean {
  return a.lastEvent === 'bounced' || a.lastEvent === 'complained'
}

/** Cómo va un correo, en una pastilla: lo último del proveedor manda sobre el estado de la cola. */
export function estadoDeCorreo(a: Pick<Aviso, 'status' | 'lastEvent'>): { label: string; tone: BadgeTone } {
  switch (a.lastEvent) {
    case 'delivered':
      return { label: 'Entregado', tone: 'success' }
    case 'bounced':
      return { label: 'Rebotado', tone: 'error' }
    case 'complained':
      return { label: 'Marcado como spam', tone: 'error' }
    case 'sent':
      return { label: 'Enviado', tone: 'neutral' }
    default:
      return a.status === 'pendiente' ? { label: 'En cola', tone: 'warning' } : ESTADO_AVISO[a.status]
  }
}

/**
 * Los correos rebotados que nadie ha corregido: los de un financiamiento cuyo
 * último correo sigue rebotado. Si después se reenvió el comprobante (a la
 * misma dirección o a una corregida) y ese no rebotó, el rebote está
 * resuelto. Los que no llevan financiamiento cuentan cada uno.
 */
export function rebotadosSinCorregir(correos: ReadonlyArray<Aviso>): Aviso[] {
  const ultimoPorFinanciamiento = new Map<string, Aviso>()
  const sueltos: Aviso[] = []
  for (const c of correos) {
    if (c.channel !== 'email') continue
    if (!c.chargeId) {
      if (correoRebotado(c)) sueltos.push(c)
      continue
    }
    const previo = ultimoPorFinanciamiento.get(c.chargeId)
    if (!previo || c.createdAt > previo.createdAt) ultimoPorFinanciamiento.set(c.chargeId, c)
  }
  return [...[...ultimoPorFinanciamiento.values()].filter(correoRebotado), ...sueltos].sort((a, b) =>
    b.createdAt.localeCompare(a.createdAt),
  )
}

/** Un correo con forma de correo. La base valida de verdad; esto evita el viaje. */
export function correoValido(correo: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(correo.trim())
}
