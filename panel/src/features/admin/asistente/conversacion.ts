import { comoFila, comoLista, texto, textoONulo } from '@/lib/json'
import { falloDelFlujo } from './errores'
import { leerEnlace, leerGrafico, leerHerramienta, leerTabla } from './protocolo'
import type { Enlace, EventoAsistente, Grafico, Herramienta, Tabla } from './protocolo'

// ═══════════════════════════════════════════════════════════════════════════
// La conversación con el asistente, sin React: cómo crece una respuesta con
// cada evento, qué se le reenvía al servidor y qué se guarda en la sesión.
//
// El servidor no guarda nada: el panel le manda la conversación entera en cada
// pregunta, solo con el texto final de cada respuesta. Se prueba en
// `conversacion.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Una pieza de una respuesta, en el orden en que llegó. El texto y lo que se
 * dibuja se intercalan: «esto es lo recuperado» y debajo el gráfico.
 */
export type Pieza =
  | { tipo: 'texto'; texto: string }
  | { tipo: 'enlace'; enlace: Enlace }
  | { tipo: 'grafico'; grafico: Grafico }
  | { tipo: 'tabla'; tabla: Tabla }

/**
 * Por qué no hay respuesta, o no entera. Cada causa se pinta distinto
 * (`avisoDelFallo`, en `errores.ts`):
 *
 *   saturado            el modelo está desbordado; suele volver en segundos.
 *   cuota               el modelo gastó su cuota del minuto o del día.
 *   sin-configurar      la función no existe, no tiene su clave o la tiene mal.
 *   conversacion-larga  la conversación ya no cabe: hay que empezar otra.
 *   sin-permiso         la sesión caducó o la persona ya no es admin.
 *   limite              demasiadas preguntas en la última hora.
 *   cortada             el flujo terminó sin su evento de fin.
 *   servidor            la función o la API del modelo fallaron.
 *   red                 no se pudo contactar con el servidor.
 */
export type CausaDelFallo =
  | 'saturado'
  | 'cuota'
  | 'sin-configurar'
  | 'conversacion-larga'
  | 'sin-permiso'
  | 'limite'
  | 'cortada'
  | 'servidor'
  | 'red'

export type Fallo = {
  causa: CausaDelFallo
  /** La frase para la persona. */
  mensaje: string
  reintentar: boolean
  /** Lo técnico (el código del proveedor, el estado HTTP): va plegado, nunca en la frase. */
  detalle?: string
}

export type EstadoRespuesta = 'escribiendo' | 'lista' | 'parada' | 'fallida'

export type MensajePersona = { id: string; rol: 'persona'; texto: string }

export type MensajeAsistente = {
  id: string
  rol: 'asistente'
  estado: EstadoRespuesta
  piezas: Pieza[]
  herramientas: Herramienta[]
  fallo?: Fallo
}

export type Mensaje = MensajePersona | MensajeAsistente

/** Lo que el servidor espera en `conversacion`. */
export type TurnoDelHistorial = { rol: 'persona' | 'asistente'; texto: string }

export function respuestaVacia(id: string): MensajeAsistente {
  return { id, rol: 'asistente', estado: 'escribiendo', piezas: [], herramientas: [] }
}

/** Lo que se pinta de una respuesta: cada pieza, o varios enlaces seguidos en una fila. */
export type Bloque =
  | { tipo: 'pieza'; pieza: Exclude<Pieza, { tipo: 'enlace' }> }
  | { tipo: 'enlaces'; enlaces: Enlace[] }

/**
 * Las piezas en bloques: los enlaces seguidos van juntos, en una fila de
 * botones, y no uno debajo de otro. Un texto entre dos enlaces los separa.
 */
export function bloquesDeRespuesta(piezas: ReadonlyArray<Pieza>): Bloque[] {
  const bloques: Bloque[] = []
  for (const p of piezas) {
    const ultimo = bloques.at(-1)
    if (p.tipo === 'enlace' && ultimo?.tipo === 'enlaces') ultimo.enlaces.push(p.enlace)
    else if (p.tipo === 'enlace') bloques.push({ tipo: 'enlaces', enlaces: [p.enlace] })
    else bloques.push({ tipo: 'pieza', pieza: p })
  }
  return bloques
}

/** El texto de una respuesta, con sus trozos juntos. */
export function textoDeRespuesta(m: MensajeAsistente): string {
  return m.piezas
    .map((p) => (p.tipo === 'texto' ? p.texto : ''))
    .join('')
    .trim()
}

/** Una herramienta nueva se añade; una que ya estaba cambia de estado. */
function conHerramienta(lista: Herramienta[], h: Herramienta): Herramienta[] {
  const i = lista.findIndex((x) => x.id === h.id)
  if (i === -1) return [...lista, h]
  return lista.map((x, j) => (j === i ? h : x))
}

/** El texto se pega a la última pieza si también es texto; si no, abre otra. */
function conTexto(piezas: Pieza[], delta: string): Pieza[] {
  const ultima = piezas.at(-1)
  if (ultima?.tipo === 'texto') {
    return [...piezas.slice(0, -1), { tipo: 'texto', texto: ultima.texto + delta }]
  }
  return delta === '' ? piezas : [...piezas, { tipo: 'texto', texto: delta }]
}

/** Cómo cambia una respuesta con cada evento del servidor. */
export function aplicarEvento(m: MensajeAsistente, e: EventoAsistente): MensajeAsistente {
  switch (e.tipo) {
    case 'texto':
      return { ...m, piezas: conTexto(m.piezas, e.delta) }
    case 'herramienta':
      return { ...m, herramientas: conHerramienta(m.herramientas, e.herramienta) }
    case 'enlace':
      return { ...m, piezas: [...m.piezas, { tipo: 'enlace', enlace: e.enlace }] }
    case 'grafico':
      return { ...m, piezas: [...m.piezas, { tipo: 'grafico', grafico: e.grafico }] }
    case 'tabla':
      return { ...m, piezas: [...m.piezas, { tipo: 'tabla', tabla: e.tabla }] }
    case 'fin':
      return { ...m, estado: 'lista', herramientas: sinConsultasEnCurso(m.herramientas) }
    case 'error':
      return conFallo(m, falloDelFlujo(e.error))
  }
}

/** Lo que seguía «consultando» al acabar ya no va a terminar. */
function sinConsultasEnCurso(lista: Herramienta[]): Herramienta[] {
  return lista.map((h) => (h.estado === 'consultando' ? { ...h, estado: 'error' } : h))
}

export function conFallo(m: MensajeAsistente, fallo: Fallo): MensajeAsistente {
  return { ...m, estado: 'fallida', fallo, herramientas: sinConsultasEnCurso(m.herramientas) }
}

/**
 * El flujo se cerró. Si no llegó el evento de fin ni un error, la respuesta
 * quedó a medias y se dice: lo que se lea podría estar incompleto.
 */
export function alTerminarElFlujo(m: MensajeAsistente): MensajeAsistente {
  if (m.estado !== 'escribiendo') return m
  return conFallo(m, {
    causa: 'cortada',
    mensaje: 'La respuesta se cortó antes de terminar.',
    reintentar: true,
  })
}

/** «Parar»: lo que ya llegó se queda, marcado como incompleto. */
export function parada(m: MensajeAsistente): MensajeAsistente {
  if (m.estado !== 'escribiendo') return m
  return { ...m, estado: 'parada', herramientas: sinConsultasEnCurso(m.herramientas) }
}

/**
 * Lo que se le manda al servidor: cada pregunta y el texto de cada respuesta.
 *
 * Una respuesta sin texto (fallida antes de escribir nada) no se manda, y con
 * ella tampoco la pregunta que la originó: el modelo vería dos preguntas
 * seguidas sin respuesta entre medias. Solo la última pregunta, la que se
 * está haciendo, va sin respuesta detrás.
 */
export function historialParaEnviar(mensajes: ReadonlyArray<Mensaje>): TurnoDelHistorial[] {
  const turnos: TurnoDelHistorial[] = []
  mensajes.forEach((m, i) => {
    if (m.rol === 'asistente') {
      const t = textoDeRespuesta(m)
      if (t !== '') turnos.push({ rol: 'asistente', texto: t })
      return
    }
    const siguiente = mensajes.at(i + 1)
    const esLaUltima = siguiente === undefined
    const tuvoRespuesta = siguiente?.rol === 'asistente' && textoDeRespuesta(siguiente) !== ''
    if (esLaUltima || tuvoRespuesta) turnos.push({ rol: 'persona', texto: m.texto })
  })
  return turnos
}

/** La última pregunta de la conversación, la que se reintenta. */
export function ultimaPregunta(mensajes: ReadonlyArray<Mensaje>): MensajePersona | null {
  for (let i = mensajes.length - 1; i >= 0; i--) {
    const m = mensajes[i]
    if (m.rol === 'persona') return m
  }
  return null
}

// ── Lo que se guarda en la sesión ──────────────────────────────────────────

/**
 * Cuántos mensajes se guardan. Una conversación larga se sigue mandando
 * entera al servidor; esto solo acota lo que ocupa la pestaña.
 */
export const MENSAJES_GUARDADOS = 60

function leerPieza(v: unknown): Pieza | null {
  const f = comoFila(v)
  switch (f.tipo) {
    case 'texto':
      return typeof f.texto === 'string' ? { tipo: 'texto', texto: f.texto } : null
    case 'enlace': {
      const enlace = leerEnlace(f.enlace)
      return enlace ? { tipo: 'enlace', enlace } : null
    }
    case 'grafico': {
      const grafico = leerGrafico(f.grafico)
      return grafico ? { tipo: 'grafico', grafico } : null
    }
    case 'tabla': {
      const tabla = leerTabla(f.tabla)
      return tabla ? { tipo: 'tabla', tabla } : null
    }
    default:
      return null
  }
}

const ESTADOS: ReadonlyArray<EstadoRespuesta> = ['escribiendo', 'lista', 'parada', 'fallida']
const CAUSAS: ReadonlyArray<CausaDelFallo> = [
  'saturado',
  'cuota',
  'sin-configurar',
  'conversacion-larga',
  'sin-permiso',
  'limite',
  'cortada',
  'servidor',
  'red',
]

function leerFallo(v: unknown): Fallo | undefined {
  const f = comoFila(v)
  const causa = CAUSAS.find((c) => c === f.causa)
  const mensaje = textoONulo(f.mensaje)
  if (!causa || !mensaje) return undefined
  const detalle = textoONulo(f.detalle)
  const reintentar = f.reintentar === true
  return detalle ? { causa, mensaje, reintentar, detalle } : { causa, mensaje, reintentar }
}

function leerMensaje(v: unknown): Mensaje | null {
  const f = comoFila(v)
  const id = textoONulo(f.id)
  if (!id) return null
  if (f.rol === 'persona') {
    const t = texto(f.texto)
    return t === '' ? null : { id, rol: 'persona', texto: t }
  }
  if (f.rol !== 'asistente') return null

  const guardado = ESTADOS.find((e) => e === f.estado) ?? 'lista'
  const m: MensajeAsistente = {
    id,
    rol: 'asistente',
    estado: guardado,
    piezas: comoLista(f.piezas)
      .map(leerPieza)
      .filter((p): p is Pieza => p !== null),
    herramientas: comoLista(f.herramientas)
      .map(leerHerramienta)
      .filter((h): h is Herramienta => h !== null),
  }
  const fallo = leerFallo(f.fallo)
  const conSuFallo = fallo ? { ...m, fallo } : m
  // Una respuesta que se estaba escribiendo al recargar ya no va a seguir.
  return parada(conSuFallo)
}

/** La conversación guardada, validada. Lo que no encaja se descarta. */
export function leerConversacion(guardada: string | null): Mensaje[] {
  if (!guardada) return []
  try {
    return comoLista(JSON.parse(guardada))
      .map(leerMensaje)
      .filter((m): m is Mensaje => m !== null)
      .slice(-MENSAJES_GUARDADOS)
  } catch {
    return []
  }
}

export function escribirConversacion(mensajes: ReadonlyArray<Mensaje>): string {
  return JSON.stringify(mensajes.slice(-MENSAJES_GUARDADOS))
}
