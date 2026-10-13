// ═══════════════════════════════════════════════════════════════════════════
// Helios — El bot del médico (docs/00 §2.2 y §15.4, docs/01 §5.4)
//
// La conversación con una persona del personal, paso a paso. Cada paso se
// guarda en `whatsapp_sessions` (bot_session / bot_session_save); 30 minutos
// sin actividad la reinician. Todo lo que toca dinero o datos pasa por los
// `bot_*`, que actúan COMO esa persona con las reglas del panel.
//
//   (sin PIN)  pin_nuevo → pin_repetir → menú
//   menú       Nuevo pago en cuotas · Mis pagos en cuotas · Ayuda
//              (o directamente una cédula, o «reenviar 1042»)
//   cedula     → nuevo: datos      disponible: moneda      no disponible: menú
//   datos      el formulario (en un mensaje aparte, para copiarlo) o solo las
//              respuestas en orden; pide solo lo que falte. Sin IA (2026-10-09)
//              → moneda (si no la dijo) → monto (si no lo dijo) → resumen
//   moneda     Dólares (USD) · Euros (EUR)   (o el monto con su moneda de
//              una vez: «€80 consulta»)
//   monto      «80 consulta», «€80 consulta», «80 euros consulta»; un botón
//              de moneda aquí la cambia y vuelve a pedir el monto
//   resumen    Confirmar · Corregir (también la moneda) · Cancelar
//   pin        el PIN → la orden sale al paciente → menú
//
// La moneda (decisión del 2026-10-07): el médico cobra la consulta en
// dólares o en euros y la orden queda en esa moneda; el paciente la paga en
// bolívares, a la tasa BCV de esa moneda del día en que paga. La base mide
// lo disponible en dólares (`disponible_usd`); aquí se dice en la moneda
// elegida con `usd_per_eur`. Sin tasa del euro hoy, solo se cobra en dólares.
//
// Las respuestas salen por la cola (`helios_whatsapp_text`); el webhook las
// despacha en cuanto termina.
// ═══════════════════════════════════════════════════════════════════════════

import {
  CAMPOS_DEL_FORMULARIO,
  FORMULARIO,
  MINIMO_DEL_FORMULARIO,
  bolivares,
  diaCorto,
  dinero,
  dineroEn,
  enEuros,
  enPlural,
  faltantes,
  faltantesClaves,
  formularioDe,
  horaCaracas,
  juntar,
  leerCedula,
  leerFormulario,
  leerMoneda,
  leerMontoYConcepto,
  leerPorPosicion,
  monedaDe,
  nombreDeLaMoneda,
} from './datos.ts'
import type { Clave, DatosDelPaciente, Lectura, Moneda } from './datos.ts'
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

type Estado = 'menu' | 'pin_nuevo' | 'pin_repetir' | 'cedula' | 'datos' | 'moneda' | 'monto' | 'resumen' | 'pin'

type Datos = {
  pinHmac?: string
  cedula?: string
  nuevo?: boolean
  /** Lo disponible en DÓLARES, como lo mide la base. */
  disponible?: number | null
  /** Dólares por euro hoy (`usd_per_eur`), o null si hoy no hay tasa del euro. */
  usdPorEur?: number | null
  /** La moneda de la orden; null mientras no se elija. */
  moneda?: Moneda | null
  nombreEnmascarado?: string | null
  telefonoEnmascarado?: string | null
  emailEnmascarado?: string | null
  paciente?: DatosDelPaciente
  monto?: number | null
  concepto?: string | null
  atendido?: string | null
  /** Las preguntas del último formulario enviado: el orden de las respuestas sin etiquetas. */
  pidiendo?: Clave[]
}

type Boton = { id: string; title: string }

/** Al corregir un paciente nuevo, cada cambio lleva su etiqueta. */
const CORREGIR =
  'Envíame solo lo que quieras cambiar, con su etiqueta, por ejemplo:\nCorreo: nuevo@correo.com\nMonto: 90\nMoneda: euros'

/** Todas las preguntas del formulario, en orden. */
const TODO_EL_FORMULARIO: Clave[] = CAMPOS_DEL_FORMULARIO.map(([k]) => k)

const MENU: Boton[] = [
  { id: 'menu:nuevo', title: 'Nuevo pago en cuotas' },
  { id: 'menu:mis', title: 'Mis pagos en cuotas' },
  { id: 'menu:ayuda', title: 'Ayuda' },
]

const RESUMEN: Boton[] = [
  { id: 'orden:confirmar', title: 'Confirmar' },
  { id: 'orden:corregir', title: 'Corregir' },
  { id: 'orden:cancelar', title: 'Cancelar' },
]

const MONEDA: Boton[] = [
  { id: 'moneda:USD', title: 'Dólares (USD)' },
  { id: 'moneda:EUR', title: 'Euros (EUR)' },
]

/** Cuando hoy no hay tasa del euro: solo dólares. */
const SOLO_DOLARES: Boton[] = [
  { id: 'moneda:USD', title: 'Dólares (USD)' },
  { id: 'orden:cancelar', title: 'Cancelar' },
]

const ESTADO_DE_LA_ORDEN: Record<string, string> = {
  pending: 'Esperando al paciente',
  confirmed: 'Confirmado',
  declined: 'Rechazado',
  expired: 'Vencido',
}

/**
 * Los códigos con los que la base lanza sus errores de negocio, escritos para
 * quien los lee: `raise exception` a secas (P0001) y los `errcode` que usan
 * las RPC del bot. Cualquier otro es un fallo interno.
 */
const ERRORES_DE_NEGOCIO = new Set(['P0001', '22023', 'P0002', '42501', '28000', '55000'])

/** HMAC del PIN nuevo con el secreto del webhook: así no queda en claro en la sesión. */
async function huellaDelPin(pin: string, telefono: string): Promise<string> {
  // Sin secreto el webhook ya responde 401 (index.ts) y no llega aquí; sin
  // clave de respaldo, por si algún día se llama desde otro sitio.
  const secreto = Deno.env.get('WHATSAPP_WEBHOOK_TOKEN')
  if (!secreto) throw new Error('Falta WHATSAPP_WEBHOOK_TOKEN')
  const clave = new TextEncoder().encode(secreto)
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

/** Un número positivo de la base, o null. */
function positivo(v: unknown): number | null {
  const x = Number(v)
  return v != null && Number.isFinite(x) && x > 0 ? x : null
}

/** Lo disponible en la moneda elegida, o null si no se sabe (sin tasa del euro). */
function disponibleEn(d: Datos, m: Moneda): number | null {
  if (d.disponible == null) return null
  if (m === 'USD') return d.disponible
  return d.usdPorEur ? enEuros(d.disponible, d.usdPorEur) : null
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

  /**
   * Una RPC cuyo error de negocio se le enseña al médico tal cual (lo escribe
   * la base). Un error interno (una restricción, un fallo de Postgres) no: el
   * médico lee un aviso genérico y el detalle queda en el log.
   */
  async function probar<T>(fn: string, args: Record<string, unknown>): Promise<{ ok: true; data: T } | { ok: false; mensaje: string }> {
    try {
      return { ok: true, data: await rpc<T>(fn, args) }
    } catch (err) {
      const m = err instanceof Error ? err.message : String(err)
      const code = (err as { code?: unknown } | null)?.code
      if (typeof code === 'string' && ERRORES_DE_NEGOCIO.has(code)) {
        return { ok: false, mensaje: m.replace(/^[a-z_]+: /, '') }
      }
      console.error('bot', fn, code, m)
      return { ok: false, mensaje: 'No pudimos completarlo. Inténtalo de nuevo en un momento.' }
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
  /** La moneda pedida con un botón («moneda:EUR») o escrita sola («euros», «$»). */
  const monedaPedida: Moneda | null = boton.startsWith('moneda:') ? monedaDe(boton.slice('moneda:'.length)) : leerMoneda(texto)

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
      return menu('Listo, tu PIN quedó guardado. Te lo pediré cada vez que registres un pago en cuotas. Te recomendamos borrar los mensajes donde lo escribiste.\n\n¿Qué quieres hacer?')
    }
    await guardar('pin_nuevo')
    const hola = nombreDePila(personal)
    await enviar(
      `Hola${hola ? `, ${hola}` : ''}. Soy el asistente de Helios para ${personal.merchant_name ?? 'tu clínica'}.\n\n` +
        'Para empezar, crea un PIN de 4 números. Te lo pediré cada vez que registres un pago en cuotas. Escríbelo ahora:',
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

  // ── Mis pagos en cuotas y ayuda (desde cualquier paso) ────────────────
  if (boton === 'menu:mis' || ['mis pagos en cuotas', 'mis pagos', 'mis financiamientos'].includes(n) || (estado === 'menu' && n === '2')) {
    const r = await probar<Array<Record<string, unknown>>>('bot_recent_charges', { p_phone: tel, p_limit: 10 })
    if (!r.ok) {
      await enviar(r.mensaje)
      return { paso: 'mis', error: r.mensaje }
    }
    const lineas = r.data.map((f) => {
      const estadoTexto = ESTADO_DE_LA_ORDEN[String(f.status)] ?? String(f.status)
      const vence = f.status === 'pending' && f.expires_at ? ` (vence ${horaCaracas(String(f.expires_at))})` : ''
      // Cada orden en su moneda (sin comisión: es lo que recibe la clínica).
      const consulta =
        f.merchant_sale_cur != null
          ? dineroEn(Number(f.merchant_sale_cur), monedaDe(f.currency))
          : dinero(Number(f.merchant_sale_usd))
      return `#${f.order_number} · ${f.customer_name ?? 'Paciente'} · ${consulta} · ${estadoTexto}${vence}`
    })
    await guardar('menu')
    await enviar(
      lineas.length === 0
        ? 'No tienes pagos en cuotas en los últimos 30 días.'
        : `Tus últimos pagos en cuotas:\n${lineas.join('\n')}\n\nPara reenviarle algo a un paciente escribe, por ejemplo, «reenviar ${r.data[0].order_number}».`,
      MENU,
    )
    return { paso: 'mis', cuantos: lineas.length }
  }

  if (boton === 'menu:ayuda' || n === 'ayuda' || (estado === 'menu' && n === '3')) {
    await guardar('menu')
    await enviar(
      'Así funciona:\n' +
        '1. Pulsa «Nuevo pago en cuotas» y escribe la cédula del paciente.\n' +
        '2. Si es nuevo, envíame sus datos en un solo mensaje.\n' +
        '3. Elige si cobras la consulta en dólares o en euros y escribe el monto.\n' +
        '4. Revisa el resumen y confírmalo con tu PIN.\n' +
        '5. Al paciente le llega un WhatsApp: cuando responda Sí, la orden queda confirmada y te aviso aquí.\n\n' +
        'El paciente paga siempre en bolívares, a la tasa BCV del día en que paga.\n\n' +
        'Escribe «menú» para volver al inicio en cualquier momento. El equipo de Helios ve este chat: si algo no funciona, escríbenos aquí.',
      MENU,
    )
    return { paso: 'ayuda' }
  }

  // ── La cédula (o un atajo desde el menú) ──────────────────────────────
  const cedulaDirecta = estado === 'menu' ? leerCedula(texto) : null
  if (boton === 'menu:nuevo' || ['nuevo pago en cuotas', 'nuevo pago', 'nuevo financiamiento', 'nuevo'].includes(n) || (estado === 'menu' && n === '1')) {
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
      return menu(String(e.mensaje ?? 'Esta persona no puede pagar en cuotas con Helios.'))
    }
    const usdPorEur = positivo(e.usd_per_eur)
    if (e.estado === 'nuevo') {
      const limite = Number(e.limite_usd ?? 0)
      await guardar('datos', {
        cedula,
        nuevo: true,
        disponible: limite || null,
        usdPorEur,
        paciente: {},
        pidiendo: TODO_EL_FORMULARIO,
      })
      // Aún no eligió moneda: lo disponible, en las dos.
      const enEur = usdPorEur && limite > 0 ? ` (${dineroEn(enEuros(limite, usdPorEur), 'EUR')} si la cobras en euros)` : ''
      await enviar(
        `${cedula} es un paciente nuevo. Tiene disponible para pagar en cuotas hasta ${dinero(limite)}${enEur}.\n\n` +
          'Envíame sus datos en un solo mensaje. En el siguiente te dejo las preguntas. ' +
          '*No hace falta copiarlas*: puedes responder solo con los datos, uno por línea y en el mismo orden. ' +
          'Si prefieres, cópialas y llénalas.',
      )
      // Aparte, para que se copie de un toque.
      await enviar(FORMULARIO)
      return { paso: 'datos' }
    }
    return seguir(
      {
        cedula,
        nuevo: false,
        disponible: Number(e.disponible_usd ?? 0),
        usdPorEur,
        moneda: null,
        nombreEnmascarado: (e.nombre_enmascarado as string) ?? null,
        telefonoEnmascarado: (e.telefono_enmascarado as string) ?? null,
        emailEnmascarado: (e.email_enmascarado as string) ?? null,
      },
      `Paciente: ${e.nombre_enmascarado ?? cedula} · ${e.telefono_enmascarado ?? ''}\n\n`,
    )
  }

  // ── Los datos del paciente nuevo ──────────────────────────────────────
  if (estado === 'datos') {
    let lectura: Lectura | null = null
    const formulario = leerFormulario(texto)
    if (formulario.etiquetado || /^\s*[^:\n]{2,40}:\s*\S/.test(texto)) {
      lectura = formulario
    } else {
      // Solo las respuestas, en el orden de lo último que se pidió.
      const pidiendo = datos.pidiendo ?? TODO_EL_FORMULARIO
      if (pidiendo.length === 0) {
        // Corrigiendo: sin etiqueta no se sabe qué dato cambia.
        await enviar(CORREGIR)
        return { paso: 'datos', leido: false }
      }
      const completo = pidiendo.length === TODO_EL_FORMULARIO.length
      lectura = leerPorPosicion(texto, pidiendo, completo ? MINIMO_DEL_FORMULARIO : pidiendo.length)
      if (!lectura) {
        const cuantas = completo ? `de ${MINIMO_DEL_FORMULARIO} a ${pidiendo.length}` : String(pidiendo.length)
        await enviar(
          `No pude leer los datos: espero ${cuantas} respuestas, una por línea y en el orden de las preguntas. ` +
            'No hace falta copiar las preguntas del siguiente mensaje: basta con los datos, uno por línea y en ese orden.',
        )
        await enviar(completo ? FORMULARIO : formularioDe(pidiendo))
        return { paso: 'datos', leido: false }
      }
    }

    const paciente = juntar(datos.paciente ?? {}, lectura.paciente)
    const nuevo: Datos = {
      ...datos,
      paciente,
      monto: lectura.monto ?? datos.monto ?? null,
      moneda: lectura.moneda ?? datos.moneda ?? null,
      concepto: lectura.concepto ?? datos.concepto ?? null,
      atendido: lectura.atendido ?? datos.atendido ?? null,
    }
    const falta = faltantes(paciente)
    if (falta.length > 0) {
      const pidiendo = faltantesClaves(paciente)
      await guardar('datos', { ...nuevo, pidiendo })
      await enviar(
        'Me falta lo del siguiente mensaje. No hace falta copiar las preguntas: ' +
          'envíame solo los datos, uno por línea y en ese orden.',
      )
      await enviar(formularioDe(pidiendo))
      return { paso: 'datos', falta }
    }
    return seguir(nuevo, 'Ya tengo los datos. ')
  }

  // ── La moneda ─────────────────────────────────────────────────────────
  if (estado === 'moneda') {
    if (monedaPedida) return seguir({ ...datos, moneda: monedaPedida })
    // El monto con su moneda de una vez («€80 consulta»); sin moneda, se vuelve a preguntar.
    const mc = leerMontoYConcepto(texto)
    if (mc) return seguir({ ...datos, monto: mc.monto, moneda: mc.moneda, concepto: mc.concepto ?? datos.concepto ?? null })
    await enviar('Elige la moneda en la que cobras la consulta:', MONEDA)
    return { paso: 'moneda' }
  }

  // ── El monto ──────────────────────────────────────────────────────────
  if (estado === 'monto') {
    // Un botón de moneda aquí (desde «Corregir») la cambia: el monto se vuelve a pedir.
    if (monedaPedida) return seguir({ ...datos, moneda: monedaPedida, monto: null })
    const mc = leerMontoYConcepto(texto)
    if (!mc) {
      await enviar('No entendí el monto. Escríbelo así: 80 consulta')
      return { paso: 'monto' }
    }
    return seguir({
      ...datos,
      monto: mc.monto,
      moneda: mc.moneda ?? datos.moneda ?? null,
      concepto: mc.concepto ?? datos.concepto ?? null,
    })
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
        await guardar('datos', { ...datos, pidiendo: [] })
        await enviar(CORREGIR)
        return { paso: 'datos' }
      }
      await guardar('monto', datos)
      await enviar(
        `Escribe otra vez el monto en ${enPlural(datos.moneda ?? 'USD')} y el concepto (por ejemplo: 80 consulta), ` +
          'o elige otra moneda:',
        MONEDA,
      )
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
      p_amount: datos.monto,
      p_concept: datos.concepto ?? null,
      p_beneficiary_name: datos.atendido ?? null,
      p_idempotency_key: `wa:${mensaje.id}`,
      p_currency: datos.moneda ?? 'USD',
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
      await enviar(`Listo. Orden #${f.order_number} registrada.`, MENU)
    }
    return { paso: 'enviada', charge_id: f.id, status: f.status }
  }

  // ── Con los datos del paciente listos: moneda, monto y resumen ────────
  /**
   * Pide lo que falte, en orden (la moneda, luego el monto) o, si está todo,
   * enseña el resumen. `antes` va delante de la pregunta («Ya tengo los
   * datos. »).
   */
  async function seguir(d: Datos, antes = '') {
    if (!d.moneda) {
      await guardar('moneda', d)
      await enviar(`${antes}¿En qué moneda cobras esta consulta?`, MONEDA)
      return { paso: 'moneda' }
    }
    if (d.moneda === 'EUR' && !d.usdPorEur) {
      // Sin la tasa del euro de hoy no se puede cobrar en euros. El monto se
      // descarta: 80 euros no son 80 dólares.
      await guardar('moneda', { ...d, moneda: null, monto: null })
      await enviar(
        `${antes}Hoy todavía no tenemos la tasa BCV del euro, así que por ahora no se puede cobrar en euros. ¿La cobras en dólares?`,
        SOLO_DOLARES,
      )
      return { paso: 'moneda', sin_tasa_del_euro: true }
    }
    if (!d.monto) {
      await guardar('monto', d)
      const disponible = disponibleEn(d, d.moneda)
      await enviar(
        antes +
          (disponible != null ? `Tiene disponible para pagar en cuotas hasta ${dineroEn(disponible, d.moneda)}.\n\n` : '') +
          `Escribe el monto de la consulta en ${enPlural(d.moneda)} y el concepto (por ejemplo: 80 consulta):`,
      )
      return { paso: 'monto' }
    }
    return resumen(d)
  }

  // ── El resumen antes de confirmar ─────────────────────────────────────
  async function resumen(d: Datos) {
    const moneda = d.moneda ?? 'USD'
    const p = await probar<Record<string, unknown>>('bot_preview_charge', {
      p_phone: tel,
      p_document: d.nuevo ? null : d.cedula,
      p_amount: d.monto,
      p_currency: moneda,
    })
    if (!p.ok) {
      await guardar('monto', d)
      await enviar(`${p.mensaje}\n\nEscribe otro monto en ${enPlural(moneda)} (por ejemplo: 80 consulta):`)
      return { paso: 'monto', error: p.mensaje }
    }
    const v = p.data
    const m = monedaDe(v.currency ?? moneda)
    /** Un monto en la moneda de la orden (`*_cur`); si la base no lo trae, en dólares. */
    const en = (cur: unknown, usd: unknown) => (cur != null ? dineroEn(Number(cur), m) : dinero(Number(usd ?? 0)))

    if (v.cabe === false) {
      await guardar('monto', d)
      await enviar(
        `Ese monto supera lo disponible (${en(v.disponible_cur ?? v.limite_cur, v.disponible_usd ?? v.limite_usd)}). ` +
          `Escribe otro monto en ${enPlural(m)}:`,
      )
      return { paso: 'monto', cabe: false }
    }

    // Cada cuota en la moneda de la orden y, de referencia, en bolívares de hoy.
    const cuotas = (v.installments as Array<Record<string, unknown>>)
      .map((c, i) => {
        const bs = c.amount_ves != null ? ` (${bolivares(Number(c.amount_ves))} a la tasa de hoy)` : ''
        return `${i + 1}. ${en(c.amount_cur, c.amount_usd)} el ${diaCorto(String(c.due_date))}${bs}`
      })
      .join('\n')
    const pac = d.paciente ?? {}
    const quien = d.nuevo
      ? [
          `*${pac.first_name} ${pac.last_name}* · ${d.cedula}`,
          `Nacimiento: ${pac.birth_date} · Sexo: ${pac.sex}`,
          `Teléfono: ${pac.phone}  ← ahí le preguntamos si acepta`,
          `Correo: *${pac.email}*  ← ahí le llega el comprobante`,
          `Dirección: ${[pac.address, pac.city, pac.state].filter(Boolean).join(', ')}`,
        ].join('\n')
      : `*${d.nombreEnmascarado ?? d.cedula}* · ${d.cedula}\nTeléfono: ${d.telefonoEnmascarado ?? ''}  ← ahí le preguntamos si acepta`

    await guardar('resumen', d)
    await enviar(
      `Revisa antes de enviar:\n\n${quien}\n\n` +
        `Consulta: ${en(v.base_cur, v.base_usd)}${d.concepto ? ` (${d.concepto})` : ''}\n` +
        `Comisión de servicio (${v.consumer_fee_pct}%): ${en(v.consumer_fee_cur, v.consumer_fee_usd)}\n` +
        `IVA de la comisión: ${en(v.consumer_fee_vat_cur, v.consumer_fee_vat_usd)}\n` +
        `Cuotas:\n${cuotas}\n\n` +
        `El paciente paga en bolívares a la tasa BCV del ${nombreDeLaMoneda(m)} del día en que pague.\n` +
        'Al confirmar, le llega un WhatsApp al paciente y tiene 2 horas para responder Sí.',
      RESUMEN,
    )
    return { paso: 'resumen' }
  }

  // ── Cualquier otra cosa: el menú ──────────────────────────────────────
  return menu(sesion.nueva ? `Hola${nombreDePila(personal) ? `, ${nombreDePila(personal)}` : ''}. ¿Qué quieres hacer?` : 'No entendí. ¿Qué quieres hacer?')
}
