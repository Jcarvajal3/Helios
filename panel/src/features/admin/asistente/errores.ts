import { booleano, comoFila, textoONulo } from '@/lib/json'
import type { CausaDelFallo, Fallo } from './conversacion'

// ═══════════════════════════════════════════════════════════════════════════
// Por qué no contestó el asistente, leído de lo que manda el servidor.
//
// Llega por dos caminos: un estado HTTP que no es 200 (la función ni empezó)
// o un evento `error` dentro del flujo (el modelo falló a media respuesta). Y
// el evento vive en dos formatos a la vez mientras la función nueva no esté
// desplegada en todas partes: el nuevo trae `codigo` y `detalle`; el viejo,
// solo la frase, con el detalle técnico entre paréntesis al final. Todo acaba
// en un `Fallo` con su causa. Módulo puro; se prueba en `errores.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Lo que dice la función del fallo, en el formato nuevo. */
export type CodigoDeError = 'saturado' | 'cuota' | 'configuracion' | 'conversacion_larga' | 'otro'

/** El evento `error` del flujo, ya leído, del formato que sea. */
export type ErrorDelAsistente = {
  codigo: CodigoDeError
  /** La frase para la persona, sin nada técnico. */
  mensaje: string
  reintentar: boolean
  /** El fallo del proveedor, ya enmascarado: solo para diagnosticar. */
  detalle?: string
}

const CODIGOS: ReadonlyArray<CodigoDeError> = ['saturado', 'cuota', 'configuracion', 'conversacion_larga', 'otro']

const SIN_MENSAJE = 'El asistente no pudo contestar.'

/** Cuánto se espera antes de volver a preguntar a un modelo ocupado. */
export const ESPERA_DEL_REINTENTO = 10_000

/**
 * El paréntesis técnico que el formato viejo pegaba al final de la frase:
 * «…en un minuto (Gemini 503 UNAVAILABLE: …).». La primera apertura manda, y
 * el detalle puede llevar paréntesis dentro («(clave)»).
 */
const DETALLE_PEGADO = /^(.*?)\s*\(((?:Gemini|Anthropic)\s.*)\)\.?\s*$/s

/** Separa de la frase el detalle técnico del formato viejo, si lo lleva. */
export function separarDetalle(mensaje: string): { mensaje: string; detalle?: string } {
  const partes = DETALLE_PEGADO.exec(mensaje)
  if (!partes) return { mensaje }
  const frase = partes[1].trim()
  if (frase === '') return { mensaje }
  return { mensaje: /[.!?…]$/.test(frase) ? frase : `${frase}.`, detalle: partes[2].trim() }
}

/**
 * El código que el formato viejo no traía, deducido de su frase y su detalle.
 * El orden importa: una clave mal puesta puede llegar con un 5xx en el detalle
 * y no por eso está saturado.
 */
export function codigoPorTexto(mensaje: string, detalle?: string): CodigoDeError {
  const t = `${mensaje} ${detalle ?? ''}`
  if (/demasiado larga/i.test(t)) return 'conversacion_larga'
  if (/configurad|no está disponible con esta cuenta|FAILED_PRECONDITION/i.test(t)) return 'configuracion'
  if (/cuota|RESOURCE_EXHAUSTED|\b429\b/i.test(t)) return 'cuota'
  if (/saturad|UNAVAILABLE|overloaded|\b5\d\d\b/i.test(t)) return 'saturado'
  return 'otro'
}

/**
 * El evento `error` del flujo, en cualquiera de los dos formatos. Un código
 * que este panel aún no conoce se trata como el formato viejo: se deduce.
 */
export function leerErrorDelFlujo(v: unknown): ErrorDelAsistente {
  const f = comoFila(v)
  const crudo = textoONulo(f.mensaje) ?? SIN_MENSAJE
  const reintentar = booleano(f.reintentar)
  const conocido = CODIGOS.find((c) => c === f.codigo)
  const separado = separarDetalle(crudo)
  const detalle = textoONulo(f.detalle) ?? separado.detalle
  const codigo = conocido ?? codigoPorTexto(separado.mensaje, detalle)
  return detalle
    ? { codigo, mensaje: separado.mensaje, reintentar, detalle }
    : { codigo, mensaje: separado.mensaje, reintentar }
}

const CAUSA_DEL_CODIGO: Record<CodigoDeError, CausaDelFallo> = {
  saturado: 'saturado',
  cuota: 'cuota',
  configuracion: 'sin-configurar',
  conversacion_larga: 'conversacion-larga',
  otro: 'servidor',
}

/** Un fallo con su detalle solo si lo hay: la clave vacía no viaja ni se guarda. */
function fallo(causa: CausaDelFallo, mensaje: string, reintentar: boolean, detalle?: string): Fallo {
  return detalle ? { causa, mensaje, reintentar, detalle } : { causa, mensaje, reintentar }
}

/** El evento `error` del flujo como fallo de la respuesta. */
export function falloDelFlujo(e: ErrorDelAsistente): Fallo {
  return fallo(CAUSA_DEL_CODIGO[e.codigo], e.mensaje, e.reintentar, e.detalle)
}

// ── Los estados HTTP ───────────────────────────────────────────────────────

const SIN_CONFIGURAR = 'El asistente todavía no está configurado.'

/** El mensaje de un cuerpo de error, sea JSON (`mensaje`, `error`, `message`) o texto. */
export function mensajeDelCuerpo(cuerpo: string): string | null {
  const limpio = cuerpo.trim()
  if (limpio === '') return null
  try {
    const f = comoFila(JSON.parse(limpio))
    return textoONulo(f.mensaje) ?? textoONulo(f.error) ?? textoONulo(f.message) ?? textoONulo(f.msg)
  } catch {
    // Un texto suelto se enseña solo si es corto: una página HTML de error no.
    return limpio.length <= 300 && !limpio.startsWith('<') ? limpio : null
  }
}

/** Lo que el cuerpo trae como JSON: la frase de la función y su código. */
function leerCuerpo(cuerpo: string): { frase: string | null; codigo: string | null } {
  try {
    const f = comoFila(JSON.parse(cuerpo))
    // `error` es el código de la función; `code`, el de la pasarela de Supabase.
    return { frase: textoONulo(f.mensaje), codigo: textoONulo(f.error) ?? textoONulo(f.code) }
  } catch {
    return { frase: null, codigo: null }
  }
}

/** Los códigos con que la función dice que le falta configuración. */
const CODIGOS_SIN_CONFIGURAR = new Set(['sin_clave', 'no_configurado'])

/**
 * Un estado HTTP que no es 200, como fallo que se puede pintar.
 *
 * La función sin desplegar contesta 404; sin su clave, 503 con el código
 * `sin_clave`; sin la configuración de Supabase, 500 con `no_configurado`.
 * Las tres se leen igual: «todavía no está configurado». Un 503 a secas es
 * la pasarela que no arrancó la función: se reintenta.
 *
 * La frase para la persona solo sale del campo `mensaje`, que escribe la
 * función en castellano. Lo demás (el código, el `message` en inglés de la
 * pasarela) va al detalle técnico.
 */
export function falloPorEstado(estado: number, cuerpo: string): Fallo {
  const { frase, codigo } = leerCuerpo(cuerpo)
  const tecnico = mensajeDelCuerpo(cuerpo)
  const sinConfigurar =
    (codigo !== null && CODIGOS_SIN_CONFIGURAR.has(codigo)) ||
    (tecnico !== null && /configurad|_API_KEY/i.test(tecnico))
  const detalle = [`HTTP ${estado}`, codigo, tecnico !== null && tecnico !== frase ? `· ${tecnico.slice(0, 200)}` : null]
    .filter((p): p is string => p !== null)
    .join(' ')

  if (estado === 404 || sinConfigurar) return fallo('sin-configurar', SIN_CONFIGURAR, false, detalle)
  if (estado === 401 || estado === 403) {
    return fallo(
      'sin-permiso',
      frase ?? 'La sesión no tiene permiso para usar el asistente. Vuelve a iniciar sesión y prueba otra vez.',
      false,
    )
  }
  if (estado === 429) {
    return fallo('limite', frase ?? 'Has llegado al límite de preguntas de la última hora.', false)
  }
  return fallo('servidor', frase ?? SIN_MENSAJE, true, detalle)
}

// ── Cómo se enseña ─────────────────────────────────────────────────────────

/** Un modelo ocupado suele volver en segundos: se reintenta solo, una vez. */
export function seReintentaSolo(f: Fallo): boolean {
  return (f.causa === 'saturado' || f.causa === 'cuota') && f.reintentar
}

/** Lo que pinta el aviso de un fallo; las acciones que dependen del estado las decide el aviso. */
export type AvisoDelFallo = {
  /** Ámbar: el asistente no está disponible. Rojo: esta respuesta falló. */
  tono: 'warning' | 'error'
  titulo: string
  /** La línea bajo el título, o `null` si el título ya lo dice todo. */
  linea: string | null
  /** «Buscar en el panel»: lo mismo, sin el asistente. */
  buscar: boolean
  /** «Empezar una conversación nueva»: la de ahora ya no cabe. */
  empezarDeNuevo: boolean
}

const TITULO: Record<CausaDelFallo, string> = {
  saturado: 'El asistente está ocupado',
  cuota: 'El asistente está ocupado',
  'sin-configurar': 'El asistente no está configurado',
  'conversacion-larga': 'La conversación es demasiado larga',
  limite: 'Has llegado al límite de preguntas',
  'sin-permiso': 'No se pudo hacer la pregunta',
  cortada: 'La respuesta está incompleta',
  servidor: 'El asistente no pudo contestar',
  red: 'No hay conexión con el servidor',
}

/** Lo que no depende de la persona: el servicio o su configuración. */
const EN_AMBAR: ReadonlySet<CausaDelFallo> = new Set<CausaDelFallo>([
  'saturado',
  'cuota',
  'sin-configurar',
  'conversacion-larga',
  'limite',
])

/** «El asistente no pudo contestar.» y su título dicen lo mismo. */
const comoTitulo = (s: string) => s.trim().replace(/[.…]+$/, '').toLocaleLowerCase('es')

export function avisoDelFallo(f: Fallo): AvisoDelFallo {
  const titulo = TITULO[f.causa]
  // La frase de «demasiado larga» repite el botón; la de «sin configurar»
  // genérica repite el título.
  const repite =
    f.causa === 'conversacion-larga' ||
    f.mensaje === SIN_CONFIGURAR ||
    comoTitulo(f.mensaje) === comoTitulo(titulo)
  return {
    tono: EN_AMBAR.has(f.causa) ? 'warning' : 'error',
    titulo,
    linea: repite ? null : f.mensaje,
    buscar: f.causa === 'saturado' || f.causa === 'cuota',
    empezarDeNuevo: f.causa === 'conversacion-larga',
  }
}
