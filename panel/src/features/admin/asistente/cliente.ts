import type { Fallo, TurnoDelHistorial } from './conversacion'
import { falloPorEstado } from './errores'
import type { EventoAsistente } from './protocolo'
import { crearLectorDeEventos } from './sse'

// ═══════════════════════════════════════════════════════════════════════════
// La llamada a la función `admin-asistente`: una petición POST y la respuesta
// leída trozo a trozo mientras llega.
//
// Sin React ni Supabase: la URL, el token y hasta `fetch` llegan por
// parámetro, para poder probarlo contra un servidor de mentira
// (`cliente.test.ts`). El hook `useAsistente` le pone la sesión.
// ═══════════════════════════════════════════════════════════════════════════

export const RUTA_DE_LA_FUNCION = '/functions/v1/admin-asistente'

export type PeticionAlAsistente = {
  /** La URL del proyecto de Supabase, sin barra final. */
  url: string
  /** El JWT de quien pregunta: las consultas corren con SUS permisos. */
  token: string
  /** La clave pública del proyecto, que la pasarela de funciones exige. */
  apikey: string
  conversacion: TurnoDelHistorial[]
  /** Dónde está la persona: da contexto a «¿y esto?». */
  rutaActual?: string
  signal?: AbortSignal
  alEvento: (evento: EventoAsistente) => void
  fetch?: typeof fetch
}

/**
 * Cómo acabó la llamada, sin contar lo que ya se entregó por `alEvento`:
 *
 *   completa  el flujo terminó; si llegó el evento de fin lo dice el mensaje.
 *   parada    la persona pulsó «Parar».
 *   fallida   no hubo respuesta que leer, y el fallo explica por qué.
 */
export type Resultado = { tipo: 'completa' } | { tipo: 'parada' } | { tipo: 'fallida'; fallo: Fallo }

const FALLO_DE_RED: Fallo = {
  causa: 'red',
  mensaje: 'No se pudo contactar con el servidor. Comprueba la conexión.',
  reintentar: true,
}

function esAborto(error: unknown, signal: AbortSignal | undefined): boolean {
  return signal?.aborted === true || (error instanceof DOMException && error.name === 'AbortError')
}

/**
 * Hace la pregunta y entrega cada evento según llega. Nunca lanza: todo final
 * posible vuelve como `Resultado`.
 */
export async function preguntarAlAsistente(p: PeticionAlAsistente): Promise<Resultado> {
  const llamar = p.fetch ?? fetch
  let respuesta: Response
  try {
    respuesta = await llamar(`${p.url}${RUTA_DE_LA_FUNCION}`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${p.token}`,
        apikey: p.apikey,
        'Content-Type': 'application/json',
        Accept: 'text/event-stream',
      },
      body: JSON.stringify({ conversacion: p.conversacion, rutaActual: p.rutaActual }),
      signal: p.signal,
    })
  } catch (error) {
    return esAborto(error, p.signal) ? { tipo: 'parada' } : { tipo: 'fallida', fallo: FALLO_DE_RED }
  }

  if (!respuesta.ok) {
    const cuerpo = await respuesta.text().catch(() => '')
    return { tipo: 'fallida', fallo: falloPorEstado(respuesta.status, cuerpo) }
  }
  if (!respuesta.body) {
    return { tipo: 'fallida', fallo: falloPorEstado(500, '') }
  }

  const lector = crearLectorDeEventos()
  const decodificador = new TextDecoder()
  const flujo = respuesta.body.getReader()
  try {
    for (;;) {
      const { done, value } = await flujo.read()
      if (done) break
      lector.empujar(decodificador.decode(value, { stream: true })).forEach(p.alEvento)
    }
    lector.empujar(decodificador.decode()).forEach(p.alEvento)
    lector.terminar().forEach(p.alEvento)
    return { tipo: 'completa' }
  } catch (error) {
    if (esAborto(error, p.signal)) return { tipo: 'parada' }
    return { tipo: 'fallida', fallo: FALLO_DE_RED }
  } finally {
    flujo.releaseLock()
  }
}
