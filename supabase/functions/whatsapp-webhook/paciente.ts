// ═══════════════════════════════════════════════════════════════════════════
// Helios — El bot del paciente (decisiones del 2026-10-06, docs/00 §15.6;
// textos del 2026-10-19; el lector de comprobantes, docs/03, del 2026-10-21)
//
// Cuando un paciente le escribe a Helios (y no es su respuesta a una
// confirmación), antes de que lo atienda una persona:
//
//   · un mensaje cualquiera → el menú con tres botones (Pagar mi cuota ·
//     Mi saldo y cuotas · Hablar con alguien), como mucho una vez cada
//     2 horas; si ya lo vio, se calla y lo ve el equipo en la app;
//   · Pagar mi cuota → la cuota que toca (las vencidas primero), en la moneda
//     de su orden (dólares o euros), y el bloque de pago: los bolívares de
//     hoy, las cuentas (solo bolívares: Pago Móvil o transferencia) y
//     «envíanos la foto del comprobante»;
//   · Mi saldo y cuotas → lo disponible para su próxima consulta, los pagos
//     en cuotas activos (cuotas pagadas y pendientes), lo que falta por
//     pagar y los terminados;
//   · Hablar con alguien → «alguien te escribe» y se calla 24 h;
//   · Ya pagué (botón de los recordatorios) → «envíanos la foto»;
//   · un «sí» o un «no» cuando su orden ya venció → que pida que se la
//     reenvíen;
//   · una foto o un documento (un comprobante) → acuse y se calla 24 h;
//   · alguien sin pagos en cuotas → un acuse y se calla 24 h;
//   · un teléfono de varios pacientes → pide la cédula antes de enseñar nada.
//
// El lector de comprobantes (docs/03), según su modo (`ctx.lector`):
//
//   · apagado → todo como arriba;
//   · sombra  → todo como arriba, y además la captura se encola para leerla
//               (sin crear pagos: se compara con lo que registra el equipo);
//   · activo  → la captura se encola, el acuse dice «lo estamos verificando»
//               y el bot NO se calla; si la captura no trae la referencia, la
//               base la pide y aquí se recibe (estado «referencia»); «Ya
//               pagué» ofrece escribir los datos del pago en vez de la foto
//               (estado «datos_pago»: banco, teléfono y referencia completa).
//   Con una persona atendiendo el chat, la captura se lee igual, en silencio.
//
// Lo que recuerda de cada número vive en `whatsapp_contacts`.
// ═══════════════════════════════════════════════════════════════════════════

import { leerCedula } from './datos.ts'
import { faltanDatosDePago, juntarDatosDePago, leerDatosDePago, quiereEscribirLosDatos } from './datos_pago.ts'
import type { DatosDePago } from './datos_pago.ts'
import { decisionDelTexto, normalizar } from './logica.ts'
import type { EventoDeMensaje } from './logica.ts'
import {
  BOTON_PAGAR,
  MAXIMO_CON_BOTONES,
  MENU_PACIENTE,
  mensajeAyuda,
  mensajeCedulaNoCoincide,
  mensajeComprobante,
  mensajeComprobanteLeyendo,
  mensajeDatosDePagoRecibidos,
  mensajeFaltanDatosDePago,
  mensajeFinanciamientos,
  mensajeGenerico,
  mensajeLoRevisaElEquipo,
  mensajePagar,
  mensajePedirCedula,
  mensajePedirDatosDePago,
  mensajeReferenciaRecibida,
  mensajeSinFinanciamientos,
  mensajeYaPague,
  mensajeYaPagueConDatos,
  tienePendientes,
} from './textos_paciente.ts'
import type { Boton, ResumenDelPaciente } from './textos_paciente.ts'

type Rpc = <T>(fn: string, args: Record<string, unknown>) => Promise<T>

type Perfil = { id: string; nombre: string | null; documento: string; documento_enmascarado: string | null }

type Contexto = {
  perfiles: Perfil[]
  elegido: string | null
  estado: 'cedula' | 'referencia' | 'datos_pago' | null
  humano: boolean
  menu_reciente: boolean
  /** Lo que se le contesta a un «sí» o un «no» si su orden ya venció (o null). */
  vencida_texto?: string | null
  /** El modo del lector de comprobantes; sin él (una base vieja), apagado. */
  lector?: 'apagado' | 'sombra' | 'activo'
  /** Lo que ya escribió de los datos de su pago (estado «datos_pago»). */
  borrador?: (DatosDePago & { intentos?: number }) | null
}

/** Lo que devuelven `bot_comprobante_nuevo` y `bot_comprobante_datos`. */
type Comprobante = { ok: boolean; id?: string | null; mode?: string; motivo?: string | null; outcome?: string | null }

const HORAS_DE_PERSONA = 24
const ADJUNTOS = new Set(['image', 'document'])
/** Veces que se piden los datos del pago antes de pasárselo al equipo. */
const INTENTOS_DE_DATOS = 2

/** El paciente de un teléfono sin preguntarle nada: el único, o el que ya eligió. */
function perfilConocido(ctx: Contexto): Perfil | null {
  if (ctx.perfiles.length === 1) return ctx.perfiles[0]
  return ctx.perfiles.find((p) => p.id === ctx.elegido) ?? null
}

/** Devuelve qué hizo (para `whatsapp_inbound.result`), o null si se calló (lo atiende una persona). */
export async function atenderAlPaciente({
  rpc,
  mensaje,
  despertarAlLector = () => {},
}: {
  rpc: Rpc
  mensaje: EventoDeMensaje
  /** Una captura quedó encolada: que el lector la lea ya. */
  despertarAlLector?: () => void
}): Promise<Record<string, unknown> | null> {
  const tel = mensaje.from
  const ctx = await rpc<Contexto>('bot_paciente_contexto', { p_phone: tel })
  const boton = mensaje.boton ?? ''
  const n = normalizar(mensaje.texto ?? '')
  const lector = ctx.lector ?? 'apagado'
  const esAdjunto = ADJUNTOS.has(mensaje.type)

  const enviar = (texto: string, perfil: string | null, botones: Boton[] = []) =>
    rpc('helios_whatsapp_patient_text', { p_to: tel, p_text: texto, p_profile_id: perfil, p_buttons: botones })
  const guardar = (g: { menu?: boolean; humano?: number; estado?: string; perfil?: string }) =>
    rpc('bot_paciente_guardar', {
      p_phone: tel,
      p_menu: g.menu ?? null,
      p_humano_horas: g.humano ?? null,
      p_estado: g.estado ?? null,
      p_profile_id: g.perfil ?? null,
    })
  const borrador = (d: DatosDePago & { intentos?: number }) =>
    rpc('bot_paciente_borrador', { p_phone: tel, p_draft: d })

  /** Encola la captura para el lector (si está encendido) y lo despierta. */
  const encolar = async (perfilId: string, enSilencio: boolean): Promise<Comprobante | null> => {
    if (lector === 'apagado' || !mensaje.adjunto) return null
    const r = await rpc<Comprobante>('bot_comprobante_nuevo', {
      p_wa_message_id: mensaje.id,
      p_phone: tel,
      p_profile_id: perfilId,
      p_media_id: mensaje.adjunto.id,
      p_mime: mensaje.adjunto.mime,
      p_quiet: enSilencio,
    })
    if (r.ok) despertarAlLector()
    return r
  }

  const pidioAlgo = boton.startsWith('paciente:')

  // Lo atiende una persona: el bot no se mete, salvo que pulse un botón. Una
  // captura se lee igual, sin escribirle: así su pago también se coteja.
  if (ctx.humano && !pidioAlgo) {
    const quien = esAdjunto ? perfilConocido(ctx) : null
    if (quien) await encolar(quien.id, true)
    return null
  }

  // Un «sí» o un «no» a una orden que ya venció: que pida que se la reenvíen.
  if (!pidioAlgo && ctx.vencida_texto && decisionDelTexto(mensaje.texto)) {
    await enviar(ctx.vencida_texto, null)
    return { paso: 'vencida' }
  }

  // ¿Quién es?
  let perfil: Perfil | null = null
  if (ctx.perfiles.length === 1) {
    perfil = ctx.perfiles[0]
  } else if (ctx.perfiles.length > 1) {
    perfil = ctx.perfiles.find((p) => p.id === ctx.elegido) ?? null
    if (!perfil && ctx.estado === 'cedula') {
      const cedula = leerCedula(mensaje.texto ?? '')
      perfil = ctx.perfiles.find((p) => p.documento === cedula) ?? null
      if (perfil) {
        await guardar({ estado: '', perfil: perfil.id, menu: true })
        await enviar(mensajeGenerico(perfil.nombre), perfil.id, MENU_PACIENTE)
        return { paso: 'identificado' }
      }
      await enviar(mensajeCedulaNoCoincide(), null)
      return { paso: 'cedula', coincide: false }
    }
  }

  // Un comprobante (o cualquier foto o documento). Con el lector activo lo
  // lee el bot; si no, lo revisa una persona (en sombra, además, se lee).
  if (esAdjunto) {
    const r = perfil ? await encolar(perfil.id, false) : null
    if (r?.ok && r.mode === 'activo') {
      // Ya no hace falta lo que estaba escribiendo.
      if (ctx.estado === 'datos_pago' || ctx.estado === 'referencia') await guardar({ estado: '' })
      await enviar(mensajeComprobanteLeyendo(perfil?.nombre ?? null), perfil?.id ?? null)
      return { paso: 'comprobante', lector: 'activo', lectura: r.id ?? null }
    }
    await guardar({ humano: HORAS_DE_PERSONA })
    await enviar(mensajeComprobante(perfil?.nombre ?? null), perfil?.id ?? null)
    return r ? { paso: 'comprobante', lector: r.mode ?? lector, lectura: r.id ?? null, motivo: r.motivo ?? null } : { paso: 'comprobante' }
  }

  // Alguien sin pagos en cuotas con Helios: lo atiende el equipo.
  if (ctx.perfiles.length === 0) {
    await guardar({ humano: HORAS_DE_PERSONA })
    await enviar(mensajeSinFinanciamientos(), null)
    return { paso: 'sin_paciente' }
  }

  // Un teléfono de varios pacientes: primero la cédula.
  if (!perfil) {
    await guardar({ estado: 'cedula' })
    await enviar(mensajePedirCedula(), null)
    return { paso: 'cedula' }
  }

  // Lo que el bot está esperando (con el lector activo). Un botón lo deja.
  const esperando = ctx.estado === 'referencia' || ctx.estado === 'datos_pago'
  if (esperando && pidioAlgo) {
    await guardar({ estado: '' })
  } else if (esperando && lector === 'activo' && mensaje.texto) {
    if (ctx.estado === 'referencia') {
      const r = await rpc<Comprobante>('bot_comprobante_referencia', { p_phone: tel, p_text: mensaje.texto })
      if (r.ok) {
        if (r.outcome === 'registrado') await enviar(mensajeReferenciaRecibida(perfil.nombre), perfil.id)
        else if (r.outcome === 'para_el_equipo') await enviar(mensajeLoRevisaElEquipo(perfil.nombre), perfil.id)
        // Un duplicado ya lo contestó la base.
        return { paso: 'referencia', outcome: r.outcome ?? null }
      }
      // Ninguna lectura la esperaba ya: sigue como cualquier mensaje.
    } else {
      return await recibirDatosDePago()
    }
  }

  // Escribir los datos del pago en vez de mandar la captura (D8).
  if (lector === 'activo' && !pidioAlgo && quiereEscribirLosDatos(mensaje.texto ?? '')) {
    await guardar({ estado: 'datos_pago', humano: 0 })
    await borrador({})
    await enviar(mensajePedirDatosDePago(), perfil.id)
    return { paso: 'pedir_datos' }
  }

  // Lo que pidió.
  if (boton === 'paciente:ayuda' || ['ayuda', 'hablar con alguien'].includes(n)) {
    await guardar({ humano: HORAS_DE_PERSONA })
    await enviar(mensajeAyuda(perfil.nombre), perfil.id)
    return { paso: 'ayuda' }
  }

  if (boton === 'paciente:ya_pague' || ['ya pague', 'ya pague la cuota'].includes(n)) {
    // Cuenta como menú visto: la referencia que escriba después no le
    // devuelve el menú, la lee el equipo. La foto sí tiene su acuse.
    await guardar({ humano: 0, menu: true })
    await enviar(lector === 'activo' ? mensajeYaPagueConDatos(perfil.nombre) : mensajeYaPague(perfil.nombre), perfil.id)
    return { paso: 'ya_pague' }
  }

  const quierePagar = boton === 'paciente:pagar' || ['pagar', 'pagar cuota', 'pagar mi cuota'].includes(n)
  const quiereVer =
    boton === 'paciente:financiamientos' ||
    ['mi saldo y cuotas', 'mi saldo', 'saldo', 'disponible', 'mis pagos en cuotas', 'pagos en cuotas', 'mis pagos', 'ver financiamientos', 'financiamientos', 'total pendiente'].includes(n)
  if (quierePagar) {
    const r = await rpc<ResumenDelPaciente>('bot_paciente_resumen', { p_profile_id: perfil.id })
    await guardar({ humano: 0 })
    await enviar(mensajePagar(r), perfil.id)
    return { paso: 'pagar' }
  }
  if (quiereVer) {
    const r = await rpc<ResumenDelPaciente>('bot_paciente_resumen', { p_profile_id: perfil.id })
    const texto = mensajeFinanciamientos(r)
    await guardar({ humano: 0 })
    // Con botón solo si cabe: un mensaje con botones admite 1024 caracteres.
    const botones = tienePendientes(r) && texto.length <= MAXIMO_CON_BOTONES ? [BOTON_PAGAR] : []
    await enviar(texto, perfil.id, botones)
    return { paso: 'financiamientos' }
  }

  // Cualquier otra cosa: el menú, como mucho una vez cada 2 horas.
  if (ctx.menu_reciente) return null
  await guardar({ menu: true })
  await enviar(mensajeGenerico(perfil.nombre), perfil.id, MENU_PACIENTE)
  return { paso: 'menu' }

  /**
   * Los datos del pago escritos (estado «datos_pago»): se juntan con lo que
   * ya había; si falta algo se pide (dos veces como mucho, luego al equipo);
   * completos, se le pasan a la base, que espera al aviso del BNC.
   */
  async function recibirDatosDePago(): Promise<Record<string, unknown>> {
    const p = perfil as Perfil
    const antes = ctx.borrador ?? {}
    const d = juntarDatosDePago(antes, leerDatosDePago(mensaje.texto ?? ''))
    const faltan = faltanDatosDePago(d)

    if (faltan.length > 0) {
      const intentos = (antes.intentos ?? 0) + 1
      if (intentos > INTENTOS_DE_DATOS) {
        await guardar({ estado: '', humano: HORAS_DE_PERSONA })
        await enviar(mensajeLoRevisaElEquipo(p.nombre), p.id)
        return { paso: 'datos_pago', al_equipo: true }
      }
      await borrador({ ...d, intentos })
      await enviar(mensajeFaltanDatosDePago(faltan), p.id)
      return { paso: 'datos_pago', faltan }
    }

    const r = await rpc<Comprobante>('bot_comprobante_datos', {
      p_wa_message_id: mensaje.id,
      p_phone: tel,
      p_profile_id: p.id,
      p_bank: d.banco,
      p_payer_phone: d.telefono,
      p_reference: d.referencia,
    })
    await guardar({ estado: '' })

    const esperaAlBanco = r.ok && ['registrado', 'esperando', 'duplicado', 'repetido'].includes(r.outcome ?? '')
    if (esperaAlBanco) {
      await enviar(mensajeDatosDePagoRecibidos(p.nombre), p.id)
    } else {
      // No se pudo (el tope, nada que pagar, varios avisos, un monto que no
      // salda cuotas): lo ve una persona.
      await guardar({ humano: HORAS_DE_PERSONA })
      await enviar(mensajeLoRevisaElEquipo(p.nombre), p.id)
    }
    return { paso: 'datos_pago', outcome: r.outcome ?? null, motivo: r.motivo ?? null }
  }
}
