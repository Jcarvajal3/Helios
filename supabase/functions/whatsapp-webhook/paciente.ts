// ═══════════════════════════════════════════════════════════════════════════
// Helios — El bot del paciente (decisiones del 2026-10-06, docs/00 §15.6;
// textos del 2026-10-19)
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
// Lo que recuerda de cada número vive en `whatsapp_contacts`.
// ═══════════════════════════════════════════════════════════════════════════

import { leerCedula } from './datos.ts'
import { decisionDelTexto, normalizar } from './logica.ts'
import type { EventoDeMensaje } from './logica.ts'
import {
  BOTON_PAGAR,
  MAXIMO_CON_BOTONES,
  MENU_PACIENTE,
  mensajeAyuda,
  mensajeCedulaNoCoincide,
  mensajeComprobante,
  mensajeFinanciamientos,
  mensajeGenerico,
  mensajePagar,
  mensajePedirCedula,
  mensajeSinFinanciamientos,
  mensajeYaPague,
  tienePendientes,
} from './textos_paciente.ts'
import type { Boton, ResumenDelPaciente } from './textos_paciente.ts'

type Rpc = <T>(fn: string, args: Record<string, unknown>) => Promise<T>

type Perfil = { id: string; nombre: string | null; documento: string; documento_enmascarado: string | null }

type Contexto = {
  perfiles: Perfil[]
  elegido: string | null
  estado: 'cedula' | null
  humano: boolean
  menu_reciente: boolean
  /** Lo que se le contesta a un «sí» o un «no» si su orden ya venció (o null). */
  vencida_texto?: string | null
}

const HORAS_DE_PERSONA = 24
const ADJUNTOS = new Set(['image', 'document'])

/** Devuelve qué hizo (para `whatsapp_inbound.result`), o null si se calló (lo atiende una persona). */
export async function atenderAlPaciente({
  rpc,
  mensaje,
}: {
  rpc: Rpc
  mensaje: EventoDeMensaje
}): Promise<Record<string, unknown> | null> {
  const tel = mensaje.from
  const ctx = await rpc<Contexto>('bot_paciente_contexto', { p_phone: tel })
  const boton = mensaje.boton ?? ''
  const n = normalizar(mensaje.texto ?? '')

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

  const pidioAlgo = boton.startsWith('paciente:')

  // Lo atiende una persona: el bot no se mete, salvo que pulse un botón.
  if (ctx.humano && !pidioAlgo) return null

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

  // Un comprobante (o cualquier foto o documento): lo revisa una persona.
  if (ADJUNTOS.has(mensaje.type)) {
    await guardar({ humano: HORAS_DE_PERSONA })
    await enviar(mensajeComprobante(perfil?.nombre ?? null), perfil?.id ?? null)
    return { paso: 'comprobante' }
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

  // Lo que pidió.
  if (boton === 'paciente:ayuda' || ['ayuda', 'hablar con alguien'].includes(n)) {
    await guardar({ humano: HORAS_DE_PERSONA })
    await enviar(mensajeAyuda(perfil.nombre), perfil.id)
    return { paso: 'ayuda' }
  }

  if (boton === 'paciente:ya_pague' || ['ya pague', 'ya pague la cuota'].includes(n)) {
    await guardar({ humano: 0 })
    await enviar(mensajeYaPague(perfil.nombre), perfil.id)
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
}
