import type { Destino } from '@/features/admin/catalogo/tipos'
import { booleano, comoFila, numero, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// El contacto de Helios y el estado de la configuración (contrato §2.3, H11).
//
// Lo que el paciente lee en el comprobante y en cada aviso —a qué WhatsApp
// escribir, a qué cuentas transferir, quién le manda el correo— se configura
// en Ajustes. Mientras falte algo, Inicio lo dice con un enlace a donde se
// arregla.
//
// Módulo puro, probado en `contacto.test.ts`; las llamadas, en `api.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export type ContactoDeHelios = {
  whatsappNumber: string | null
  supportEmail: string | null
  supportHours: string | null
  senderName: string | null
  senderEmail: string | null
  updatedAt: string | null
  updatedByName: string | null
}

export function leerContacto(raw: unknown): ContactoDeHelios {
  const r = comoFila(raw)
  return {
    whatsappNumber: textoONulo(r.whatsapp_number),
    supportEmail: textoONulo(r.support_email),
    supportHours: textoONulo(r.support_hours),
    senderName: textoONulo(r.sender_name),
    senderEmail: textoONulo(r.sender_email),
    updatedAt: textoONulo(r.updated_at),
    updatedByName: textoONulo(r.updated_by_name),
  }
}

/** Lo que se escribe en el formulario: todo texto, vacío es «sin configurar». */
export type BorradorDeContacto = {
  whatsappNumber: string
  supportEmail: string
  supportHours: string
  senderName: string
  senderEmail: string
}

export function borradorDe(c: ContactoDeHelios | null): BorradorDeContacto {
  return {
    whatsappNumber: c?.whatsappNumber ?? '',
    supportEmail: c?.supportEmail ?? '',
    supportHours: c?.supportHours ?? '',
    senderName: c?.senderName ?? '',
    senderEmail: c?.senderEmail ?? '',
  }
}

/**
 * Un número de WhatsApp a E.164 venezolano: `0414 123 45 67`, `414-1234567`
 * o `+58 414 1234567` → `+584141234567`. `null` si no parece un número.
 * Helios puede usar un fijo con WhatsApp Business, así que no se exige móvil.
 */
export function normalizarWhatsApp(valor: string): string | null {
  const digitos = valor.replace(/\D/g, '')
  if (!digitos) return null
  const nacional = digitos.startsWith('58') ? digitos.slice(2) : digitos.replace(/^0/, '')
  return /^\d{10}$/.test(nacional) ? `+58${nacional}` : null
}

const CORREO = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/

export type CambioDeContacto =
  | { ok: true; payload: Record<string, string | null>; cambios: string[] }
  | { ok: false; motivo: string }

const NOMBRES: Record<keyof BorradorDeContacto, string> = {
  whatsappNumber: 'el WhatsApp',
  supportEmail: 'el correo de soporte',
  supportHours: 'el horario',
  senderName: 'el nombre del remitente',
  senderEmail: 'el correo del remitente',
}

/**
 * Lo que se manda a `admin_set_platform_contact` (claves en snake_case), o
 * por qué no. Solo los campos que cambiaron cuentan como cambio, pero se
 * manda todo: la fila es una sola.
 */
export function cambioDeContacto(antes: ContactoDeHelios | null, b: BorradorDeContacto): CambioDeContacto {
  const whatsapp = b.whatsappNumber.trim() === '' ? null : normalizarWhatsApp(b.whatsappNumber)
  if (b.whatsappNumber.trim() !== '' && whatsapp === null) {
    return { ok: false, motivo: 'El WhatsApp no parece un número venezolano: escríbelo como 0414 1234567.' }
  }
  for (const campo of ['supportEmail', 'senderEmail'] as const) {
    const v = b[campo].trim()
    if (v !== '' && !CORREO.test(v)) return { ok: false, motivo: `Revisa ${NOMBRES[campo]}: no parece un correo.` }
  }
  if (b.senderEmail.trim() !== '' && b.senderName.trim() === '') {
    return { ok: false, motivo: 'Con correo de remitente hace falta también el nombre con el que firma.' }
  }

  const despues: Record<keyof BorradorDeContacto, string | null> = {
    whatsappNumber: whatsapp,
    supportEmail: b.supportEmail.trim() || null,
    supportHours: b.supportHours.trim() || null,
    senderName: b.senderName.trim() || null,
    senderEmail: b.senderEmail.trim().toLowerCase() || null,
  }
  const previo = borradorDe(antes)
  const cambios = (Object.keys(despues) as Array<keyof BorradorDeContacto>)
    .filter((k) => (despues[k] ?? '') !== (previo[k].trim() || ''))
    .map((k) => NOMBRES[k])

  if (cambios.length === 0) return { ok: false, motivo: 'No has cambiado nada.' }

  return {
    ok: true,
    cambios,
    payload: {
      whatsapp_number: despues.whatsappNumber,
      support_email: despues.supportEmail,
      support_hours: despues.supportHours,
      sender_name: despues.senderName,
      sender_email: despues.senderEmail,
    },
  }
}

// ── Configuración incompleta ───────────────────────────────────────────────

export type EstadoDeConfiguracion = {
  whatsapp: boolean
  cuentasDeCobro: number
  resend: boolean
  remitente: boolean
  /** La API de WhatsApp (360dialog) tiene su clave: sin ella, todo WhatsApp va a la cola manual. */
  whatsappApi: boolean
  /** La API apunta al sandbox de 360dialog: los mensajes no les llegan a los pacientes. */
  whatsappSandbox: boolean
}

export function leerEstadoDeConfiguracion(raw: unknown): EstadoDeConfiguracion {
  const r = comoFila(raw)
  return {
    whatsapp: booleano(r.whatsapp),
    cuentasDeCobro: numero(r.cuentas_de_cobro),
    resend: booleano(r.resend),
    remitente: booleano(r.remitente),
    // Una base vieja que no lo manda no se da por rota.
    whatsappApi: r.whatsapp_api === undefined ? true : booleano(r.whatsapp_api),
    whatsappSandbox: booleano(r.whatsapp_sandbox),
  }
}

export type Faltante = {
  id: 'whatsapp' | 'cuentas' | 'resend' | 'remitente' | 'whatsapp_api' | 'whatsapp_sandbox'
  /** Qué falta, en una frase. */
  texto: string
  /** Qué pasa mientras falte. */
  efecto: string
  /** Dónde se arregla; `null` si no es desde el panel. */
  arreglo: { rotulo: string; destino: Destino } | null
}

const A_CONTACTO: Destino = { to: '/admin/ajustes', search: { tab: 'contacto' } }

/**
 * Lo que falta configurar, en el orden en que le duele al paciente: sin
 * cuentas no sabe a dónde pagar, sin WhatsApp no sabe a quién avisar, y sin
 * correo no le llega el comprobante.
 */
export function faltantesDeConfiguracion(e: EstadoDeConfiguracion): Faltante[] {
  const faltan: Faltante[] = []
  if (e.cuentasDeCobro <= 0) {
    faltan.push({
      id: 'cuentas',
      texto: 'No hay ninguna cuenta de cobro activa.',
      efecto: 'El comprobante y los avisos no dicen a dónde pagar.',
      arreglo: { rotulo: 'Configurar las cuentas', destino: { to: '/admin/ajustes', search: { tab: 'cobro' } } },
    })
  }
  if (!e.whatsapp) {
    faltan.push({
      id: 'whatsapp',
      texto: 'Falta el WhatsApp de Helios.',
      efecto: 'El comprobante dice «Helios te escribirá por WhatsApp» y la clínica no tiene a qué número remitir al paciente.',
      arreglo: { rotulo: 'Poner el WhatsApp', destino: A_CONTACTO },
    })
  }
  if (!e.whatsappApi) {
    faltan.push({
      id: 'whatsapp_api',
      texto: 'La API de WhatsApp no está configurada.',
      efecto:
        'Ningún WhatsApp sale solo: la confirmación del paciente, los recordatorios y el bot pasan a la cola de Avisos de hoy para mandarlos a mano. La clave va en el Vault de Supabase, no en el panel.',
      arreglo: { rotulo: 'Ver los avisos de hoy', destino: { to: '/admin/avisos' } },
    })
  } else if (e.whatsappSandbox) {
    faltan.push({
      id: 'whatsapp_sandbox',
      texto: 'La API de WhatsApp está en modo de pruebas (sandbox).',
      efecto:
        'Los mensajes salen hacia el sandbox de 360dialog y no les llegan a los pacientes ni a los médicos. La dirección va en el Vault de Supabase, no en el panel.',
      arreglo: null,
    })
  }
  if (!e.remitente) {
    faltan.push({
      id: 'remitente',
      texto: 'Falta el remitente de los correos.',
      efecto: 'Los comprobantes no tienen con qué nombre y dirección salir.',
      arreglo: { rotulo: 'Poner el remitente', destino: A_CONTACTO },
    })
  }
  if (!e.resend) {
    faltan.push({
      id: 'resend',
      texto: 'Falta la clave de Resend.',
      efecto: 'Los correos se quedan en cola sin salir. La clave va en el Vault de Supabase, no en el panel.',
      arreglo: null,
    })
  }
  return faltan
}

// ── Cuentas de cobro ───────────────────────────────────────────────────────

/** Lo que hace falta de una cuenta de cobro para ordenarla. */
type CuentaOrdenable = { id: string; isActive: boolean; sortOrder: number | null; createdAt: string }

/**
 * Las cuentas en el orden en que las ven los pacientes: las activas primero,
 * por su orden (las que no tienen, al final) y a igual orden la más vieja;
 * después las retiradas, de la más nueva a la más vieja.
 */
export function ordenarCuentas<T extends CuentaOrdenable>(cuentas: ReadonlyArray<T>): T[] {
  const activas = cuentas
    .filter((c) => c.isActive)
    .sort(
      (a, b) =>
        (a.sortOrder ?? Number.MAX_SAFE_INTEGER) - (b.sortOrder ?? Number.MAX_SAFE_INTEGER) ||
        a.createdAt.localeCompare(b.createdAt),
    )
  const retiradas = cuentas.filter((c) => !c.isActive).sort((a, b) => b.createdAt.localeCompare(a.createdAt))
  return [...activas, ...retiradas]
}

/** El orden que le toca a una cuenta nueva: detrás de la última activa. */
export function siguienteOrden(cuentas: ReadonlyArray<CuentaOrdenable>): number {
  const ordenes = cuentas.filter((c) => c.isActive).map((c) => c.sortOrder ?? 0)
  return ordenes.length === 0 ? 1 : Math.max(...ordenes) + 1
}

/**
 * Subir o bajar una cuenta activa un puesto: los dos órdenes nuevos, o
 * `null` si ya está en el extremo. Se intercambian con la vecina; si las dos
 * tenían el mismo orden (o ninguno), se renumeran por su puesto.
 */
export function moverCuenta<T extends CuentaOrdenable>(
  cuentas: ReadonlyArray<T>,
  id: string,
  sentido: -1 | 1,
): Array<{ cuenta: T; sortOrder: number }> | null {
  const activas = ordenarCuentas(cuentas).filter((c) => c.isActive)
  const i = activas.findIndex((c) => c.id === id)
  const j = i + sentido
  const esta = i < 0 ? undefined : activas.at(i)
  const vecina = i < 0 || j < 0 ? undefined : activas.at(j)
  if (!esta || !vecina) return null
  const ordenEsta = esta.sortOrder ?? i + 1
  const ordenVecina = vecina.sortOrder ?? j + 1
  if (ordenEsta === ordenVecina) {
    return [
      { cuenta: esta, sortOrder: j + 1 },
      { cuenta: vecina, sortOrder: i + 1 },
    ]
  }
  return [
    { cuenta: esta, sortOrder: ordenVecina },
    { cuenta: vecina, sortOrder: ordenEsta },
  ]
}
