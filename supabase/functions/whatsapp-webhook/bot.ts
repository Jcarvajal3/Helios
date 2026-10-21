// ═══════════════════════════════════════════════════════════════════════════
// Helios — El bot del médico (docs/00 §2.2 y §15.4, docs/01 §5.4)
//
// La conversación con una persona del personal, paso a paso. Cada paso se
// guarda en `whatsapp_sessions` (bot_session / bot_session_save); 30 minutos
// sin actividad la reinician. Todo lo que toca dinero o datos pasa por los
// `bot_*`, que actúan COMO esa persona con las reglas del panel.
//
//   Sin PIN desde el 2026-10-13 (Javier): el número registrado basta, y la
//   orden no es deuda hasta que el paciente responde Sí.
//
//   menú       Nuevo pago en cuotas · Mis pagos en cuotas · Ayuda
//              (o directamente una cédula, o «reenviar 1042»)
//   cedula     → nuevo: datos      disponible: moneda      no disponible: menú
//   datos      el formulario (en un mensaje aparte, para copiarlo) o solo las
//              respuestas en orden; pide solo lo que falte. Sin IA (2026-10-09)
//              → moneda (si no la dijo) → monto (si no lo dijo) → resumen
//   moneda     Dólares (USD) · Euros (EUR)   (o el monto con su moneda de
//              una vez: «€80 consulta»)
//   monto      «$80, Limpieza Dental», «80 consulta»; la moneda elegida manda
//              y el símbolo escrito se ignora (2026-10-13). Un botón de
//              moneda aquí la cambia y vuelve a pedir el monto
//   resumen    Confirmar (la orden sale al paciente) · Corregir (también la
//              moneda) · Cancelar
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
  etiquetaDe,
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
}

export type Rpc = <T>(fn: string, args: Record<string, unknown>) => Promise<T>

type Estado = 'menu' | 'cedula' | 'datos' | 'moneda' | 'monto' | 'resumen'

type Datos = {
  cedula?: string
  nuevo?: boolean
  /** Lo disponible en DÓLARES, como lo mide la base. */
  disponible?: number | null
  /** Dólares por euro hoy (`usd_per_eur`), o null si hoy no hay tasa del euro. */
  usdPorEur?: number | null
  /** La moneda de la orden; null mientras no se elija. */
  moneda?: Moneda | null
  /** Del paciente conocido, completos desde el 2026-10-21. */
  nombre?: string | null
  /** «0414-1234567». */
  telefono?: string | null
  email?: string | null
  paciente?: DatosDelPaciente
  monto?: number | null
  concepto?: string | null
  atendido?: string | null
  /** Las preguntas del último formulario enviado: el orden de las respuestas sin etiquetas. */
  pidiendo?: Clave[]
}

type Boton = { id: string; title: string }

/** Los datos del paciente revisados por la base: lo bueno, lo malo y lo que hay que pedir. */
type Revision = { paciente: DatosDelPaciente; malos: string[]; pidiendo: Clave[]; errores: Record<string, string> }

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

/** Un número positivo de la base, o null. */
function positivo(v: unknown): number | null {
  const x = Number(v)
  return v != null && Number.isFinite(x) && x > 0 ? x : null
}

/**
 * El ejemplo de cómo escribir el monto y el concepto, con el símbolo de la
 * moneda elegida: «$80, Limpieza Dental» o «€80, Limpieza Dental» (Javier,
 * 2026-10-13: «80 consulta» no se entendía). `leerMontoYConcepto` lo lee tal
 * cual (la coma no es decimal si no la sigue un dígito); el símbolo no
 * cambia la moneda elegida.
 */
function ejemploDeMonto(m: Moneda): string {
  return `${dineroEn(80, m)}, Limpieza Dental`
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
  const saludo = () => {
    const hola = nombreDePila(personal)
    return `Hola${hola ? `, ${hola}` : ''}. Soy el asistente de Helios para ${personal.merchant_name ?? 'tu clínica'}. ¿Qué quieres hacer?`
  }
  let estado: Estado = sesion.state
  const datos: Datos = sesion.data ?? {}
  const texto = (mensaje.texto ?? '').trim()
  const boton = mensaje.boton ?? ''
  const n = normalizar(texto)
  /** La moneda pedida con un botón («moneda:EUR») o escrita sola («euros», «$»). */
  const monedaPedida: Moneda | null = boton.startsWith('moneda:') ? monedaDe(boton.slice('moneda:'.length)) : leerMoneda(texto)

  // ── Volver al menú desde cualquier paso ───────────────────────────────
  // «Empezar» es el botón de la bienvenida (plantilla `helios_cuenta_activa`).
  if (['menu', 'cancelar', 'inicio', 'salir', 'hola', 'buenas', 'buenos dias', 'buenas tardes', 'empezar'].includes(n) || boton === 'orden:cancelar') {
    if (boton === 'orden:cancelar' || n === 'cancelar') return menu('Cancelado: no se envió nada. ¿Qué quieres hacer?')
    return menu(sesion.nueva ? saludo() : undefined)
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
        '4. Revisa el resumen y confírmalo.\n' +
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
    await enviar('Escribe la cédula del paciente (por ejemplo 12345678; sin letra la tomo como V):')
    return { paso: 'cedula' }
  }

  if (estado === 'cedula' || cedulaDirecta) {
    const cedula = cedulaDirecta ?? leerCedula(texto)
    if (!cedula) {
      // Un formulario aquí: el médico creía que ya le había pedido los datos.
      const formulario = texto.split(/\r?\n/).filter((l) => l.trim() !== '').length >= 3
      await enviar(
        formulario
          ? 'Antes de sus datos necesito la cédula del paciente. Escríbela sola, por ejemplo 12345678 (sin letra la tomo como V); después te pido lo demás.'
          : 'No entendí la cédula. Escribe solo sus números, por ejemplo 12345678 (sin letra la tomo como V), o E1234567 si es extranjero.',
      )
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
        nombre: (e.nombre as string) ?? null,
        telefono: (e.telefono as string) ?? null,
        email: (e.email as string) ?? null,
      },
      `Paciente: ${e.nombre ?? cedula} · ${e.telefono ?? ''}\n\n`,
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
      // La moneda ya elegida manda sobre el símbolo del monto (2026-10-13);
      // solo una línea «Moneda:» la cambia.
      moneda: lectura.monedaElegida ?? datos.moneda ?? lectura.moneda ?? null,
      concepto: lectura.concepto ?? datos.concepto ?? null,
      atendido: lectura.atendido ?? datos.atendido ?? null,
    }
    return revisarYSeguir(nuevo, 'Ya tengo los datos. ')
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
      await enviar(`No entendí el monto. Escríbelo así: ${ejemploDeMonto(datos.moneda ?? 'USD')}`)
      return { paso: 'monto' }
    }
    return seguir({
      ...datos,
      monto: mc.monto,
      // La moneda elegida manda: «$80» con euros elegidos son €80 (Javier,
      // 2026-10-13). El símbolo solo cuenta si aún no hay moneda.
      moneda: datos.moneda ?? mc.moneda ?? null,
      concepto: mc.concepto ?? datos.concepto ?? null,
    })
  }

  // ── El resumen ────────────────────────────────────────────────────────
  if (estado === 'resumen') {
    if (boton === 'orden:confirmar' || n === 'confirmar' || n === 'si') {
      return enviarLaOrden(datos)
    }
    if (boton === 'orden:corregir' || n === 'corregir') {
      if (datos.nuevo) {
        await guardar('datos', { ...datos, pidiendo: [] })
        await enviar(CORREGIR)
        return { paso: 'datos' }
      }
      await guardar('monto', datos)
      await enviar(
        `Escribe otra vez el monto en ${enPlural(datos.moneda ?? 'USD')} y el concepto (ejemplo: ${ejemploDeMonto(datos.moneda ?? 'USD')}), ` +
          'o elige otra moneda:',
        MONEDA,
      )
      return { paso: 'monto' }
    }
    await enviar('Usa los botones: Confirmar, Corregir o Cancelar.', RESUMEN)
    return { paso: 'resumen' }
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
          `Escribe el monto de la consulta en ${enPlural(d.moneda)} y el concepto (ejemplo: ${ejemploDeMonto(d.moneda)}):`,
      )
      return { paso: 'monto' }
    }
    return resumen(d)
  }

  // ── Confirmado: la orden sale al paciente ─────────────────────────────
  async function enviarLaOrden(d: Datos) {
    const paciente = d.nuevo ? { document: d.cedula, ...d.paciente } : { document: d.cedula }
    const r = await probar<Record<string, unknown>>('bot_create_charge', {
      p_phone: tel,
      p_patient: paciente,
      p_amount: d.monto,
      p_concept: d.concepto ?? null,
      p_beneficiary_name: d.atendido ?? null,
      p_idempotency_key: `wa:${mensaje.id}`,
      p_currency: d.moneda ?? 'USD',
    })
    if (!r.ok) {
      if (d.nuevo) {
        const rev = await revisar(d)
        if (rev.pidiendo.length > 0) return { ...(await pedir(d, rev, 'No se registró la orden. ')), error: r.mensaje }
      }
      // Otro motivo (el monto, el límite…): los datos se quedan en el resumen.
      await guardar('resumen', d)
      await enviar(`No se registró: ${r.mensaje}. Tus datos siguen aquí: corrige o cancela.`, RESUMEN)
      return { paso: 'resumen', error: r.mensaje }
    }
    await guardar('menu')

    const f = r.data.charge as Record<string, unknown>
    const conf = (f.confirmation ?? {}) as Record<string, unknown>
    const quien = d.nuevo ? `${d.paciente?.first_name ?? 'el paciente'}` : (d.nombre ?? 'el paciente')
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

  // ── Los datos del paciente nuevo, revisados ───────────────────────────
  /**
   * Lo que la base rechazaría (`bot_check_patient`, las mismas reglas que el
   * registro) se quita y se pide otra vez junto con lo que falte; lo demás se
   * queda. Así el bot nunca da por bueno un dato que luego falla, y el médico
   * solo corrige lo que está mal. Con todo bien, sigue (moneda, monto, resumen).
   */
  async function revisarYSeguir(d: Datos, antes = '') {
    const rev = await revisar(d)
    if (rev.pidiendo.length === 0) return seguir({ ...d, paciente: rev.paciente }, antes)
    return pedir(d, rev)
  }

  async function revisar(d: Datos): Promise<Revision> {
    const paciente: DatosDelPaciente = { ...(d.paciente ?? {}) }
    const r = await probar<Record<string, string>>('bot_check_patient', { p_phone: tel, p_patient: paciente })
    const errores = r.ok && r.data ? r.data : {}
    const malos: string[] = []
    for (const [k, motivo] of Object.entries(errores)) {
      const clave = k as keyof DatosDelPaciente
      const valor = paciente[clave]
      delete paciente[clave]
      const pista =
        clave === 'birth_date' && !/mayor de edad/i.test(motivo)
          ? ' Escríbela, por ejemplo, 29/05/1998 o 29 de mayo de 1998.'
          : clave === 'phone'
            ? ' Tiene que ser un celular, por ejemplo 0414 1234567.'
            : clave === 'sex'
              ? ' Escribe F o M.'
              : ''
      malos.push(`• ${etiquetaDe(clave)}: «${valor}». ${motivo}.${pista}`)
    }
    return { paciente, malos, pidiendo: faltantesClaves(paciente), errores }
  }

  /** Pide lo que falte o esté mal, con las preguntas de solo eso aparte. */
  async function pedir(d: Datos, rev: Revision, aviso = '') {
    await guardar('datos', { ...d, paciente: rev.paciente, pidiendo: rev.pidiendo })
    const uno = rev.pidiendo.length === 1
    await enviar(
      aviso +
        (rev.malos.length > 0
          ? `${rev.malos.length === 1 ? 'Hay un dato que revisar' : 'Hay datos que revisar'}:\n${rev.malos.join('\n')}\n\n`
          : '') +
        `Envíame solo ${uno ? 'el dato' : 'los datos'} del siguiente mensaje: lo demás ya lo tengo. ` +
        (uno ? 'No hace falta copiar la pregunta.' : 'No hace falta copiar las preguntas: uno por línea y en ese orden.'),
    )
    await enviar(formularioDe(rev.pidiendo))
    return { paso: 'datos', falta: rev.pidiendo, errores: rev.errores }
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
      await enviar(`${p.mensaje}\n\nEscribe otro monto en ${enPlural(moneda)} (ejemplo: ${ejemploDeMonto(moneda)}):`)
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
      : [
          `*${d.nombre ?? d.cedula}* · ${d.cedula}`,
          `Teléfono: ${d.telefono ?? ''}  ← ahí le preguntamos si acepta`,
          ...(d.email ? [`Correo: *${d.email}*  ← ahí le llega el comprobante`] : []),
        ].join('\n')

    await guardar('resumen', d)
    await enviar(
      `Revisa antes de enviar:\n\n${quien}\n\n` +
        `Consulta: ${en(v.base_cur, v.base_usd)}${d.concepto ? ` (${d.concepto})` : ''}\n` +
        // «(Lo paga el paciente)» en las dos líneas (Javier, 2026-10-13): que
        // ningún médico crea que se la descuentan.
        `Comisión Helios (${v.consumer_fee_pct}%): ${en(v.consumer_fee_cur, v.consumer_fee_usd)} (Lo paga el paciente)\n` +
        `IVA de la Comisión Helios: ${en(v.consumer_fee_vat_cur, v.consumer_fee_vat_usd)} (Lo paga el paciente)\n` +
        `Cuotas:\n${cuotas}\n\n` +
        `El paciente paga en bolívares a la tasa BCV del ${nombreDeLaMoneda(m)} del día en que pague.\n` +
        'Al confirmar, le llega un WhatsApp al paciente y tiene 2 horas para responder Sí.',
      RESUMEN,
    )
    return { paso: 'resumen' }
  }

  // ── Cualquier otra cosa: el menú ──────────────────────────────────────
  return menu(sesion.nueva ? saludo() : 'No entendí. ¿Qué quieres hacer?')
}
