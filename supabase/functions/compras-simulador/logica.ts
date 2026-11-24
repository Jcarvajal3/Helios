// ═══════════════════════════════════════════════════════════════════════════
// Helios — Lógica del simulador de compras (sin red ni Deno: la prueba
// `simulador.test.ts` la corre con una base de mentira).
//
// Corre EL MISMO flujo de compras que el bot de WhatsApp (whatsapp-webhook/
// compras/flujo.ts) con un transporte que escribe en la base del simulador
// (`sim_compra_*`). Nunca llama a `helios_whatsapp_*` ni a 360dialog.
// ═══════════════════════════════════════════════════════════════════════════

import { ES_ESTADO_COMPRA, atenderCompraMedico, esAtajoDeCompra } from '../whatsapp-webhook/compras/flujo.ts'
import type { PersonalCompra, RpcCompra } from '../whatsapp-webhook/compras/flujo.ts'
import type { ResolverEnlace } from '../whatsapp-webhook/compras/enlaces.ts'
import type { ProveedorCatalogo } from '../whatsapp-webhook/compras/tipos.ts'
import { crearTransporteSimulador } from '../whatsapp-webhook/compras/transporte_simulador.ts'
import { normalizar } from '../whatsapp-webhook/logica.ts'
import type { EventoDeMensaje } from '../whatsapp-webhook/logica.ts'

export type Peticion =
  | { accion: 'diagnostico' }
  | {
      accion: 'turno'
      phone: string
      texto?: string
      respuesta?: { id: string; title: string }
      adjunto?: { receipt_path: string }
    }
  | { accion: 'reiniciar'; phone: string }

export type Respuesta =
  | { ok: true; estado?: string; proveedor: 'mock' | 'rainforest'; proveedor_listo: boolean }
  | { ok: false; error: string }

const TELEFONO = /^\+\d{8,15}$/
const RUTA_COMPROBANTE = /^compras\/simulador\/[0-9a-f-]{36}\.(jpg|jpeg|png|webp|pdf)$/i
const MIME: Record<string, string> = {
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  png: 'image/png',
  webp: 'image/webp',
  pdf: 'application/pdf',
}

/** Valida el cuerpo de la petición; el texto del error es para el panel. */
export function leerPeticion(body: unknown): Peticion | { error: string } {
  if (typeof body !== 'object' || body === null) return { error: 'Cuerpo inválido' }
  const b = body as Record<string, unknown>
  if (b.accion === 'diagnostico') return { accion: 'diagnostico' }
  if (b.accion !== 'turno' && b.accion !== 'reiniciar') return { error: 'Acción desconocida' }
  const phone = typeof b.phone === 'string' ? b.phone.trim() : ''
  if (!TELEFONO.test(phone)) return { error: 'El teléfono debe estar en formato E.164 (+58…)' }
  if (b.accion === 'reiniciar') return { accion: 'reiniciar', phone }

  const texto = typeof b.texto === 'string' ? b.texto.slice(0, 2000) : undefined
  let respuesta: { id: string; title: string } | undefined
  if (b.respuesta !== undefined) {
    const r = b.respuesta as Record<string, unknown> | null
    if (!r || typeof r.id !== 'string' || typeof r.title !== 'string' || r.id === '') return { error: 'Respuesta inválida' }
    respuesta = { id: r.id.slice(0, 256), title: r.title.slice(0, 200) }
  }
  let adjunto: { receipt_path: string } | undefined
  if (b.adjunto !== undefined) {
    const a = b.adjunto as Record<string, unknown> | null
    if (!a || typeof a.receipt_path !== 'string' || !RUTA_COMPROBANTE.test(a.receipt_path)) {
      return { error: 'El comprobante debe estar en compras/simulador/<uuid>.<ext>' }
    }
    adjunto = { receipt_path: a.receipt_path }
  }
  return { accion: 'turno', phone, texto, respuesta, adjunto }
}

/** El mensaje que habría llegado por WhatsApp, con un id nuevo por turno (la clave de idempotencia). */
export function armarMensaje(p: Extract<Peticion, { accion: 'turno' }>, id: string): EventoDeMensaje {
  const from = p.phone.replace(/\D/g, '')
  if (p.adjunto) {
    const archivo = p.adjunto.receipt_path.split('/').pop() ?? 'adjunto'
    const ext = (archivo.split('.').pop() ?? 'jpg').toLowerCase()
    return {
      kind: 'message',
      id,
      from,
      type: ext === 'pdf' ? 'document' : 'image',
      texto: null,
      boton: null,
      adjunto: { id: archivo.replace(/\.[^.]+$/, ''), mime: MIME[ext] ?? 'image/jpeg' },
      raw: { receipt_path: p.adjunto.receipt_path },
    }
  }
  return {
    kind: 'message',
    id,
    from,
    type: 'text',
    texto: p.respuesta?.title ?? (p.texto?.trim() || null),
    boton: p.respuesta?.id ?? null,
    adjunto: null,
    raw: {},
  }
}

export type OpcionesTurno = {
  rpc: RpcCompra
  personal: PersonalCompra
  peticion: Extract<Peticion, { accion: 'turno' }>
  /** Un uuid nuevo por turno. */
  idDelTurno: string
  proveedorDe: (nombre: string) => ProveedorCatalogo | null
  resolverEnlace?: ResolverEnlace
  ahora?: () => Date
}

/** Un turno del médico en el simulador: registra lo que dijo, corre el flujo y deja las respuestas en la base. */
export async function ejecutarTurno(o: OpcionesTurno): Promise<{ estado: string }> {
  const { rpc, personal, peticion } = o
  const phone = personal.phone_e164
  const transporte = crearTransporteSimulador({ rpc, phone })
  const mensaje = armarMensaje(peticion, o.idDelTurno)

  // Lo que dijo el médico, en la forma canónica del payload (contrato §4).
  if (mensaje.adjunto) {
    await rpc('sim_compra_mensaje', {
      p_phone: phone,
      p_direction: 'in',
      p_kind: 'image',
      p_body: '',
      p_payload: { receipt_path: peticion.adjunto?.receipt_path },
    })
  } else if (mensaje.texto || mensaje.boton) {
    await rpc('sim_compra_mensaje', {
      p_phone: phone,
      p_direction: 'in',
      p_kind: 'text',
      p_body: mensaje.texto ?? '',
      p_payload: mensaje.boton ? { reply_id: mensaje.boton } : {},
    })
  }

  const menu = async (saludo?: string) => {
    await transporte.guardarSesion('menu', {})
    await transporte.enviar(saludo ?? '¿Qué quieres hacer?', [
      { id: 'menu:comprar', title: 'Comprar en Amazon' },
      { id: 'compra:mis', title: 'Mis compras' },
    ])
    return { paso: 'menu' }
  }

  const sesion = await transporte.obtenerSesion()
  if (!mensaje.texto && !mensaje.boton && !mensaje.adjunto) {
    // Sin nada que decir: se abre el menú de compras.
    await menu('Hola. Soy el asistente de Helios para comprar en Amazon. ¿Qué quieres hacer?')
  } else {
    // En el simulador el menú ES el de compras: un texto libre es una búsqueda.
    const librePorBuscar =
      !ES_ESTADO_COMPRA(sesion.state) && !mensaje.boton && !!mensaje.texto && !esAtajoDeCompra(mensaje.texto, '') && !PALABRAS_DE_MENU.has(normalizar(mensaje.texto))
    await atenderCompraMedico({
      rpc,
      personal,
      mensaje,
      sesion: { ...sesion, state: librePorBuscar ? 'compra_buscar' : sesion.state },
      transporte,
      volverAlMenu: menu,
      proveedorDe: o.proveedorDe,
      resolverEnlace: o.resolverEnlace,
      ahora: o.ahora,
    })
  }
  const despues = await transporte.obtenerSesion()
  return { estado: despues.state }
}

const PALABRAS_DE_MENU = new Set(['menu', 'cancelar', 'inicio', 'salir', 'hola', 'buenas', 'buenos dias', 'buenas tardes', 'empezar', 'volver al menu'])

/** El proveedor del catálogo está listo si es mock, o rainforest con su clave. */
export function proveedorListo(proveedor: string, hayClave: boolean): boolean {
  return proveedor === 'mock' || (proveedor === 'rainforest' && hayClave)
}
