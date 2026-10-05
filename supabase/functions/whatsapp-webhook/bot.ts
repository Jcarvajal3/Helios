// ═══════════════════════════════════════════════════════════════════════════
// Helios — El bot del médico (docs/00 §2.2 y §15.4, docs/01 §5.4)
//
// La conversación con una persona del personal, paso a paso. Cada paso se
// guarda en `whatsapp_sessions` (bot_session / bot_session_save); 30 minutos
// sin actividad la reinician. Todo lo que toca dinero o datos pasa por los
// `bot_*`, que actúan COMO esa persona con las reglas del panel.
//
//   (sin PIN)  pin_nuevo → pin_repetir → menú
//   menú       Nuevo financiamiento · Mis financiamientos · Ayuda
//              (o directamente una cédula, o «reenviar 1042»)
//   cedula     → nuevo: datos      disponible: monto      no disponible: menú
//   datos      el formulario o texto libre (Gemini); pide solo lo que falte
//   monto      «80 consulta»
//   resumen    Confirmar · Corregir · Cancelar
//   pin        el PIN → la orden sale al paciente → menú
//
// Las respuestas salen por la cola (`helios_whatsapp_text`); el webhook las
// despacha en cuanto termina.
// ═══════════════════════════════════════════════════════════════════════════

import { extraerConGemini } from './gemini.ts'
import {
  FORMULARIO,
  diaCorto,
  dinero,
  faltantes,
  horaCaracas,
  juntar,
  leerCedula,
  leerFormulario,
  leerMontoYConcepto,
} from './datos.ts'
import type { DatosDelPaciente, Lectura } from './datos.ts'
import { normalizar } from './logica.ts'
import type { EventoDeMensaje } from './logica.ts'

/** La persona del personal dueña del número (helios_staff_whatsapp_row). */
export type Personal = {
  id: string
  phone_e164: string
  user_id: string
  staff_name: string | null
  role: 'gerente' | 'cajero' | null
  merchant_id: string
  merchant_name: string | null
  has_pin: boolean
  pin_locked: boolean
}

export type Rpc = <T>(fn: string, args: Record<string, unknown>) => Promise<T>

type Estado = 'menu' | 'pin_nuevo' | 'pin_repetir' | 'cedula' | 'datos' | 'monto' | 'resumen' | 'pin'

type Datos = {
  pinHmac?: string
  cedula?: string
  nuevo?: boolean
  disponible?: number | null
  nombreEnmascarado?: string | null
  telefonoEnmascarado?: string | null
  emailEnmascarado?: string | null
  paciente?: DatosDelPaciente
  monto?: number | null
  concepto?: string | null
  atendido?: string | null
}

type Boton = { id: string; title: string }

const MENU: Boton[] = [
  { id: 'menu:nuevo', title: 'Nuevo financiamiento' },
  { id: 'menu:mis', title: 'Mis financiamientos' },
  { id: 'menu:ayuda', title: 'Ayuda' },
]

const RESUMEN: Boton[] = [
  { id: 'orden:confirmar', title: 'Confirmar' },
  { id: 'orden:corregir', title: 'Corregir' },
  { id: 'orden:cancelar', title: 'Cancelar' },
]

const ESTADO_DE_LA_ORDEN: Record<string, string> = {
  pending: 'Esperando al paciente',
  confirmed: 'Confirmado',
  declined: 'Rechazado',
  expired: 'Vencido',
}

/** HMAC del PIN nuevo con el secreto del webhook: así no queda en claro en la sesión. */
async function huellaDelPin(pin: string, telefono: string): Promise<string> {
  const clave = new TextEncoder().encode(Deno.env.get('WHATSAPP_WEBHOOK_TOKEN') ?? 'helios')
  const k = await crypto.subtle.importKey('raw', clave, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const firma = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(`${telefono}:${pin}`))
  return Array.from(new Uint8Array(firma), (b) => b.toString(16).padStart(2, '0')).join('')
}

/** Lo mismo que `helios_pin_aceptable` en la base: 4 dígitos, sin los obvios. */
function pinAceptable(pin: string): boolean {
  return (
    /^\d{4}$/.test(pin) &&
    !/^(\d)\1{3}$/.test(pin) &&
    !'0123456789'.includes(pin) &&
    !'9876543210'.includes(pin)
  )
}

function nombreDePila(p: Personal): string {
  const n = (p.staff_name ?? '').trim()
  if (n === '' || n.includes('@')) return ''
  return n
}

export async function atenderAlPersonal({
  rpc,
  personal,
  mensaje,
}: {
  rpc: Rpc
  personal: Personal
  mensaje: EventoDeMensaje
}): Promise<unknown> {
  const tel = personal.phone_e164

  const enviar = (texto: string, botones: Boton[] = []) =>
    rpc('helios_whatsapp_text', {
      p_to: tel,
      p_text: texto.slice(0, botones.length > 0 ? 1024 : 4096),
      p_staff_user_id: personal.user_id,
      p_buttons: botones,
    })
  const guardar = (state: Estado, data: Datos = {}) =>
    rpc('bot_session_save', { p_phone: tel, p_state: state, p_data: data })

  /** Una RPC cuyo error de negocio se le enseña al médico tal cual (lo escribe la base). */
  async function probar<T>(fn: string, args: Record<string, unknown>): Promise<{ ok: true; data: T } | { ok: false; mensaje: string }> {
    try {
      return { ok: true, data: await rpc<T>(fn, args) }
    } catch (err) {
      const m = err instanceof Error ? err.message : String(err)
      return { ok: false, mensaje: m.replace(/^[a-z_]+: /, '') }
    }
  }

  const menu = async (saludo?: string) => {
    await guardar('menu')
    await enviar(saludo ?? '¿Qué quieres hacer?', MENU)
    return { paso: 'menu' }
  }

  const sesion = await rpc<{ state: Estado; data: Datos; nueva: boolean }>('bot_session', { p_phone: tel })
  let estado: Estado = sesion.state
  const datos: Datos = sesion.data ?? {}
  const texto = (mensaje.texto ?? '').trim()
  const boton = mensaje.boton ?? ''
  const n = normalizar(texto)

  // ── El PIN, antes que nada ────────────────────────────────────────────
  if (personal.pin_locked) {
    await enviar('Tu PIN está bloqueado por demasiados intentos. El equipo de Helios ve este chat: escríbenos aquí y lo reseteamos.')
    return { paso: 'pin_bloqueado' }
  }

  if (!personal.has_pin) {
    if (estado === 'pin_nuevo' && /^\d{4}$/.test(texto)) {
      if (!pinAceptable(texto)) {
        await enviar('Ese PIN es muy fácil de adivinar. Elige otro de 4 números (no 1234, 0000 ni parecidos):')
        return { paso: 'pin_nuevo' }
      }
      await guardar('pin_repetir', { pinHmac: await huellaDelPin(texto, tel) })
      await enviar('Escríbelo otra vez para confirmarlo:')
      return { paso: 'pin_repetir' }
    }
    if (estado === 'pin_repetir' && /^\d{4}$/.test(texto)) {
      if ((await huellaDelPin(texto, tel)) !== datos.pinHmac) {
        await guardar('pin_nuevo')
        await enviar('No coincide. Escribe de nuevo el PIN que quieres usar (4 números):')
        return { paso: 'pin_nuevo' }
      }
      const r = await probar('bot_set_pin', { p_phone: tel, p_pin: texto })
      if (!r.ok) {
        await guardar('pin_nuevo')
        await enviar(`${r.mensaje}. Escribe otro PIN de 4 números:`)
        return { paso: 'pin_nuevo' }
      }
      return menu('Listo, tu PIN quedó guardado. Te lo pediré cada vez que registres un financiamiento. Te recomendamos borrar los mensajes donde lo escribiste.\n\n¿Qué quieres hacer?')
    }
    await guardar('pin_nuevo')
    const hola = nombreDePila(personal)
    await enviar(
      `Hola${hola ? `, ${hola}` : ''}. Soy el asistente de Helios para ${personal.merchant_name ?? 'tu clínica'}.\n\n` +
        'Para empezar, crea un PIN de 4 números. Te lo pediré cada vez que registres un financiamiento. Escríbelo ahora:',
    )
    return { paso: 'pin_nuevo' }
  }

  // ── Volver al menú desde cualquier paso ───────────────────────────────
  if (['menu', 'cancelar', 'inicio', 'salir', 'hola', 'buenas', 'buenos dias', 'buenas tardes'].includes(n) || boton === 'orden:cancelar') {
    return menu(boton === 'orden:cancelar' || n === 'cancelar' ? 'Cancelado: no se envió nada. ¿Qué quieres hacer?' : undefined)
  }

  // ── Reenviar una orden: «reenviar 1042» ───────────────────────────────
  const reenviar = /^reenviar\s*#?\s*(\d+)$/.exec(n)
  if (reenviar) {
    const orden = await probar<{ id: string; status: string; order_number: number }>('bot_charge_by_order', {
      p_phone: tel,
      p_order_number: Number(reenviar[1]),
    })
    if (!orden.ok) {
      await enviar(orden.mensaje)
      return { paso: 'reenviar', error: orden.mensaje }
    }
    const confirmado = orden.data.status === 'confirmed'
    const r = await probar<Record<string, unknown>>(
      confirmado ? 'bot_resend_receipt' : 'bot_resend_confirmation',
      { p_phone: tel, p_charge_id: orden.data.id },
    )
    await enviar(
      !r.ok
        ? r.mensaje
        : confirmado
          ? `Listo, le reenviamos el comprobante de la orden #${orden.data.order_number} a su correo.`
          : `Listo, le reenviamos la pregunta al paciente de la orden #${orden.data.order_number}. Tiene 2 horas para responder Sí.`,
    )
    return { paso: 'reenviar', ok: r.ok }
  }

  // ── Mis financiamientos y ayuda (desde cualquier paso) ────────────────
  if (boton === 'menu:mis' || n === 'mis financiamientos' || (estado === 'menu' && n === '2')) {
    const r = await probar<Array<Record<string, unknown>>>('bot_recent_charges', { p_phone: tel, p_limit: 10 })
    if (!r.ok) {
      await enviar(r.mensaje)
      return { paso: 'mis', error: r.mensaje }
    }
    const lineas = r.data.map((f) => {
      const estadoTexto = ESTADO_DE_LA_ORDEN[String(f.status)] ?? String(f.status)
      const vence = f.status === 'pending' && f.expires_at ? ` (vence ${horaCaracas(String(f.expires_at))})` : ''
      return `#${f.order_number} · ${f.customer_name ?? 'Paciente'} · ${dinero(Number(f.merchant_sale_usd))} · ${estadoTexto}${vence}`
    })
    await guardar('menu')
    await enviar(
      lineas.length === 0
        ? 'No tienes financiamientos en los últimos 30 días.'
        : `Tus últimos financiamientos:\n${lineas.join('\n')}\n\nPara reenviarle algo a un paciente escribe, por ejemplo, «reenviar ${r.data[0].order_number}».`,
      MENU,
    )
    return { paso: 'mis', cuantos: lineas.length }
  }

  if (boton === 'menu:ayuda' || n === 'ayuda' || (estado === 'menu' && n === '3')) {
    await guardar('menu')
    await enviar(
      'Así funciona:\n' +
        '1. Pulsa «Nuevo financiamiento» y escribe la cédula del paciente.\n' +
        '2. Si es nuevo, envíame sus datos en un solo mensaje.\n' +
        '3. Revisa el resumen y confírmalo con tu PIN.\n' +
        '4. Al paciente le llega un WhatsApp: cuando responda Sí, el financiamiento queda confirmado y te aviso aquí.\n\n' +
        'Escribe «menú» para volver al inicio en cualquier momento. El equipo de Helios ve este chat: si algo no funciona, escríbenos aquí.',
      MENU,
    )
    return { paso: 'ayuda' }
  }

  // ── La cédula (o un atajo desde el menú) ──────────────────────────────
  const cedulaDirecta = estado === 'menu' ? leerCedula(texto) : null
  if (boton === 'menu:nuevo' || n === 'nuevo financiamiento' || n === 'nuevo' || (estado === 'menu' && n === '1')) {
    await guardar('cedula')
    await enviar('Escribe la cédula del paciente (por ejemplo V12345678):')
    return { paso: 'cedula' }
  }

  if (estado === 'cedula' || cedulaDirecta) {
    const cedula = cedulaDirecta ?? leerCedula(texto)
    if (!cedula) {
      await enviar('No entendí la cédula. Escríbela así: V12345678 o E1234567.')
      return { paso: 'cedula' }
    }
    const r = await probar<Record<string, unknown>>('bot_patient_eligibility', { p_phone: tel, p_document: cedula })
    if (!r.ok) {
      await guardar('menu')
      await enviar(r.mensaje, MENU)
      return { paso: 'cedula', error: r.mensaje }
    }
    const e = r.data
    if (e.estado === 'no_disponible') {
      return menu(String(e.mensaje ?? 'No podemos financiar a esta persona.'))
    }
    if (e.estado === 'nuevo') {
      await guardar('datos', { cedula, nuevo: true, disponible: Number(e.limite_usd ?? 0) || null, paciente: {} })
      await enviar(
        `${cedula} es un paciente nuevo. Puede financiar hasta ${dinero(Number(e.limite_usd ?? 0))}.\n\n` +
          'Envíame sus datos en un solo mensaje. Puedes copiar este formulario, llenarlo y enviarlo:\n\n' +
          FORMULARIO,
      )
      return { paso: 'datos' }
    }
    await guardar('monto', {
      cedula,
      nuevo: false,
      disponible: Number(e.disponible_usd ?? 0),
      nombreEnmascarado: (e.nombre_enmascarado as string) ?? null,
      telefonoEnmascarado: (e.telefono_enmascarado as string) ?? null,
      emailEnmascarado: (e.email_enmascarado as string) ?? null,
    })
    await enviar(
      `Paciente: ${e.nombre_enmascarado ?? cedula} · ${e.telefono_enmascarado ?? ''}\n` +
        `Puede financiar hasta ${dinero(Number(e.disponible_usd ?? 0))}.\n\n` +
        'Escribe el monto de la consulta y el concepto (por ejemplo: 80 consulta):',
    )
    return { paso: 'monto' }
  }

  // ── Los datos del paciente nuevo ──────────────────────────────────────
  if (estado === 'datos') {
    let lectura: Lectura | null = null
    const formulario = leerFormulario(texto)
    if (formulario.etiquetado || /^\s*[^:\n]{2,40}:\s*\S/.test(texto)) {
      lectura = formulario
    } else {
      const clave = Deno.env.get('GEMINI_API_KEY')
      if (clave) lectura = await extraerConGemini(texto, clave)
      if (!lectura) {
        await enviar('No pude leer los datos. Por favor copia este formulario, llénalo y envíamelo:\n\n' + FORMULARIO)
        return { paso: 'datos', leido: false }
      }
    }

    const paciente = juntar(datos.paciente ?? {}, lectura.paciente)
    const nuevo: Datos = {
      ...datos,
      paciente,
      monto: lectura.monto ?? datos.monto ?? null,
      concepto: lectura.concepto ?? datos.concepto ?? null,
      atendido: lectura.atendido ?? datos.atendido ?? null,
    }
    const falta = faltantes(paciente)
    if (falta.length > 0) {
      await guardar('datos', nuevo)
      await enviar(`Me falta:\n${falta.map((f) => `${f}:`).join('\n')}\n\nCópialo, llénalo y envíamelo.`)
      return { paso: 'datos', falta }
    }
    if (!nuevo.monto) {
      await guardar('monto', nuevo)
      await enviar('Ya tengo los datos. Ahora escribe el monto de la consulta y el concepto (por ejemplo: 80 consulta):')
      return { paso: 'monto' }
    }
    return resumen(nuevo)
  }

  // ── El monto ──────────────────────────────────────────────────────────
  if (estado === 'monto') {
    const mc = leerMontoYConcepto(texto)
    if (!mc) {
      await enviar('No entendí el monto. Escríbelo así: 80 consulta')
      return { paso: 'monto' }
    }
    return resumen({ ...datos, monto: mc.monto, concepto: mc.concepto ?? datos.concepto ?? null })
  }

  // ── El resumen ────────────────────────────────────────────────────────
  if (estado === 'resumen') {
    if (boton === 'orden:confirmar' || n === 'confirmar' || n === 'si') {
      await guardar('pin', datos)
      await enviar('Escribe tu PIN para enviar la orden al paciente:')
      return { paso: 'pin' }
    }
    if (boton === 'orden:corregir' || n === 'corregir') {
      if (datos.nuevo) {
        await guardar('datos', datos)
        await enviar('Envíame solo lo que quieras cambiar, por ejemplo:\nCorreo: nuevo@correo.com\nMonto ($): 90')
        return { paso: 'datos' }
      }
      await guardar('monto', datos)
      await enviar('Escribe otra vez el monto y el concepto (por ejemplo: 80 consulta):')
      return { paso: 'monto' }
    }
    await enviar('Usa los botones: Confirmar, Corregir o Cancelar.', RESUMEN)
    return { paso: 'resumen' }
  }

  // ── El PIN: la orden sale al paciente ─────────────────────────────────
  if (estado === 'pin') {
    if (!/^\d{4}$/.test(texto)) {
      await enviar('El PIN son 4 números. Escríbelo (o «cancelar»):')
      return { paso: 'pin' }
    }
    const paciente = datos.nuevo ? { document: datos.cedula, ...datos.paciente } : { document: datos.cedula }
    const r = await probar<Record<string, unknown>>('bot_create_charge', {
      p_phone: tel,
      p_pin: texto,
      p_patient: paciente,
      p_amount_usd: datos.monto,
      p_concept: datos.concepto ?? null,
      p_beneficiary_name: datos.atendido ?? null,
      p_idempotency_key: `wa:${mensaje.id}`,
    })
    if (!r.ok) {
      await guardar('menu')
      await enviar(`No se registró: ${r.mensaje}`, MENU)
      return { paso: 'pin', error: r.mensaje }
    }
    if (r.data.ok === false) {
      if (r.data.locked) {
        await guardar('menu')
        await enviar(String(r.data.message))
        return { paso: 'pin', bloqueado: true }
      }
      await enviar(`${r.data.message} Escribe tu PIN otra vez:`)
      return { paso: 'pin', intentos: r.data.attempts_left }
    }

    const f = r.data.charge as Record<string, unknown>
    const conf = (f.confirmation ?? {}) as Record<string, unknown>
    const quien = datos.nuevo ? `${datos.paciente?.first_name ?? 'el paciente'}` : (datos.nombreEnmascarado ?? 'el paciente')
    await guardar('menu')
    if (f.status === 'pending') {
      await enviar(
        `Listo. Orden #${f.order_number} enviada. Le escribimos a ${quien}` +
          `${conf.telefono_enmascarado ? ` al ${conf.telefono_enmascarado}` : ''} para que responda Sí.\n` +
          `Tiene hasta las ${horaCaracas(String(f.expires_at ?? ''))}. Te aviso aquí cuando responda.`,
        MENU,
      )
    } else {
      await enviar(`Listo. Financiamiento #${f.order_number} registrado.`, MENU)
    }
    return { paso: 'enviada', charge_id: f.id, status: f.status }
  }

  // ── El resumen antes de confirmar ─────────────────────────────────────
  async function resumen(d: Datos) {
    const p = await probar<Record<string, unknown>>('bot_preview_charge', {
      p_phone: tel,
      p_document: d.nuevo ? null : d.cedula,
      p_amount_usd: d.monto,
    })
    if (!p.ok) {
      await guardar('monto', d)
      await enviar(`${p.mensaje}\n\nEscribe otro monto (por ejemplo: 80 consulta):`)
      return { paso: 'monto', error: p.mensaje }
    }
    const v = p.data
    if (v.cabe === false) {
      await guardar('monto', d)
      await enviar(`Ese monto supera lo que puede financiar (${dinero(Number(v.disponible_usd ?? v.limite_usd ?? 0))}). Escribe otro monto:`)
      return { paso: 'monto', cabe: false }
    }

    const cuotas = (v.installments as Array<Record<string, unknown>>)
      .map((c) => `${dinero(Number(c.amount_usd))} el ${diaCorto(String(c.due_date))}`)
      .join(' y ')
    const pac = d.paciente ?? {}
    const quien = d.nuevo
      ? [
          `*${pac.first_name} ${pac.last_name}* · ${d.cedula}`,
          `Nacimiento: ${pac.birth_date} · Sexo: ${pac.sex}`,
          `Teléfono: ${pac.phone}  ← ahí le preguntamos si acepta`,
          `Correo: *${pac.email}*  ← ahí le llega el comprobante`,
          `Dirección: ${pac.address}, ${pac.city}, ${pac.state}`,
          `Referencia: ${pac.reference_name} (${pac.reference_relationship}) · ${pac.reference_phone}`,
        ].join('\n')
      : `*${d.nombreEnmascarado ?? d.cedula}* · ${d.cedula}\nTeléfono: ${d.telefonoEnmascarado ?? ''}  ← ahí le preguntamos si acepta`

    await guardar('resumen', d)
    await enviar(
      `Revisa antes de enviar:\n\n${quien}\n\n` +
        `Consulta: ${dinero(Number(v.base_usd))}${d.concepto ? ` (${d.concepto})` : ''}\n` +
        `Cargo por servicio de Helios (${v.consumer_fee_pct} %): ${dinero(Number(v.consumer_fee_usd))}\n` +
        `IVA del cargo por servicio: ${dinero(Number(v.consumer_fee_vat_usd))}\n` +
        `Cuotas: ${cuotas}\n\n` +
        'Al confirmar, le llega un WhatsApp al paciente y tiene 2 horas para responder Sí.',
      RESUMEN,
    )
    return { paso: 'resumen' }
  }

  // ── Cualquier otra cosa: el menú ──────────────────────────────────────
  return menu(sesion.nueva ? `Hola${nombreDePila(personal) ? `, ${nombreDePila(personal)}` : ''}. ¿Qué quieres hacer?` : 'No entendí. ¿Qué quieres hacer?')
}
