import { leerEvento } from './protocolo'
import type { EventoAsistente } from './protocolo'

// ═══════════════════════════════════════════════════════════════════════════
// Partir un `text/event-stream` en eventos.
//
// La red no respeta los eventos: un trozo puede acabar a mitad de una línea,
// entre el `\r` y el `\n` de un salto o a mitad del JSON. El lector guarda lo
// que queda a medias y solo entrega un evento cuando llega la línea en blanco
// que lo cierra, como dice la especificación de Server-Sent Events.
//
// Módulo puro, sin `fetch` ni React: se prueba en `sse.test.ts`. Los bytes los
// convierte a texto quien llama, con un `TextDecoder` en modo `stream`, para
// que una «ñ» partida entre dos trozos no salga rota.
// ═══════════════════════════════════════════════════════════════════════════

/** Un evento tal como viene, antes de mirar sus datos. */
export type EventoCrudo = { tipo: string; datos: string }

export type LectorSSE = {
  /** Añade un trozo y devuelve los eventos que ese trozo cerró. */
  empujar: (trozo: string) => EventoCrudo[]
  /** Fin del flujo: entrega el evento que quedara sin línea en blanco. */
  terminar: () => EventoCrudo[]
}

export function crearLectorSSE(): LectorSSE {
  let pendiente = ''
  let tipo = ''
  let datos: string[] = []

  /** Cierra el evento en curso. Sin `data` no hay evento (así lo dice la norma). */
  function despachar(salida: EventoCrudo[]) {
    if (datos.length > 0) salida.push({ tipo: tipo || 'message', datos: datos.join('\n') })
    tipo = ''
    datos = []
  }

  function procesarLinea(linea: string, salida: EventoCrudo[]) {
    if (linea === '') return despachar(salida)
    // Un comentario: el servidor los manda para que el proxy no corte la
    // conexión mientras el modelo piensa.
    if (linea.startsWith(':')) return

    const dosPuntos = linea.indexOf(':')
    const campo = dosPuntos === -1 ? linea : linea.slice(0, dosPuntos)
    let valor = dosPuntos === -1 ? '' : linea.slice(dosPuntos + 1)
    if (valor.startsWith(' ')) valor = valor.slice(1)

    if (campo === 'event') tipo = valor
    else if (campo === 'data') datos.push(valor)
    // `id` y `retry` no se usan: el panel no reconecta a mitad de respuesta.
  }

  function empujar(trozo: string): EventoCrudo[] {
    const salida: EventoCrudo[] = []
    pendiente += trozo
    let inicio = 0
    for (let i = 0; i < pendiente.length; i++) {
      const c = pendiente[i]
      if (c !== '\n' && c !== '\r') continue
      // Un `\r` al final del trozo puede ser la primera mitad de un `\r\n`:
      // se espera al siguiente trozo para saberlo.
      if (c === '\r' && i === pendiente.length - 1) break
      procesarLinea(pendiente.slice(inicio, i), salida)
      if (c === '\r' && pendiente[i + 1] === '\n') i++
      inicio = i + 1
    }
    pendiente = pendiente.slice(inicio)
    return salida
  }

  function terminar(): EventoCrudo[] {
    const salida: EventoCrudo[] = []
    const resto = pendiente.replace(/\r$/, '')
    pendiente = ''
    if (resto !== '') procesarLinea(resto, salida)
    despachar(salida)
    return salida
  }

  return { empujar, terminar }
}

/** El JSON de `data`, o `undefined` si no se puede leer. */
function leerJson(datos: string): unknown {
  try {
    return JSON.parse(datos)
  } catch {
    return undefined
  }
}

/**
 * Un evento crudo, validado contra el protocolo. Un JSON roto o un evento que
 * no encaja devuelven `null`: se ignoran sin tumbar la respuesta entera.
 */
export function interpretarEvento(crudo: EventoCrudo): EventoAsistente | null {
  const datos = leerJson(crudo.datos)
  if (datos === undefined) return null
  return leerEvento(crudo.tipo, datos)
}

/**
 * El lector completo: texto en, eventos del asistente fuera, ya validados.
 * Es lo que usa el cliente.
 */
export function crearLectorDeEventos(): {
  empujar: (trozo: string) => EventoAsistente[]
  terminar: () => EventoAsistente[]
} {
  const lector = crearLectorSSE()
  const validar = (crudos: EventoCrudo[]) =>
    crudos.map(interpretarEvento).filter((e): e is EventoAsistente => e !== null)
  return {
    empujar: (trozo) => validar(lector.empujar(trozo)),
    terminar: () => validar(lector.terminar()),
  }
}
