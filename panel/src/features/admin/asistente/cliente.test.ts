/**
 * Pruebas del cliente del asistente contra servidores de mentira: uno en
 * memoria (un `fetch` que devuelve un flujo trozo a trozo) y uno HTTP de
 * verdad en un puerto local, para que `fetch` y `ReadableStream` sean los del
 * entorno y no los nuestros.
 *
 *   npx tsx src/features/admin/asistente/cliente.test.ts
 *
 * Lo que no puede pasar: que una «ñ» partida entre dos trozos salga rota, que
 * «Parar» se lea como un fallo, o que un 429 se pinte como un error genérico.
 */
import { createServer } from 'node:http'

import { comoFila, comoLista, texto } from '@/lib/json'
import { preguntarAlAsistente, RUTA_DE_LA_FUNCION } from './cliente'
import type { Resultado } from './cliente'
import { alTerminarElFlujo, aplicarEvento, conFallo, parada, respuestaVacia } from './conversacion'
import type { MensajeAsistente } from './conversacion'
import type { EventoAsistente } from './protocolo'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const codificar = (s: string) => new TextEncoder().encode(s)

/** Un flujo que entrega esos trozos de bytes, uno por lectura. */
function flujoDe(trozos: Uint8Array[], abierto = false): ReadableStream<Uint8Array> {
  let i = 0
  return new ReadableStream<Uint8Array>({
    pull(control) {
      if (i < trozos.length) control.enqueue(trozos[i++])
      else if (!abierto) control.close()
      // Abierto: no cierra nunca, como un modelo que sigue pensando.
    },
  })
}

type Peticion = { url: string; init: RequestInit | undefined }

/** Un `fetch` de mentira que apunta lo que recibe y contesta `respuesta`. */
function fetchDeMentira(respuesta: (init: RequestInit | undefined) => Response | Promise<Response>) {
  const recibidas: Peticion[] = []
  const llamar: typeof fetch = async (entrada, init) => {
    const url = typeof entrada === 'string' ? entrada : entrada instanceof URL ? entrada.href : entrada.url
    recibidas.push({ url, init })
    return respuesta(init)
  }
  return { llamar, recibidas }
}

const BASE = {
  url: 'https://proyecto.supabase.co',
  token: 'jwt-de-prueba',
  apikey: 'clave-publica',
  conversacion: [{ rol: 'persona' as const, texto: '¿Cuánto se recuperó esta semana?' }],
  rutaActual: '/admin/cobranza?tramo=t2',
}

/** Hace la pregunta y aplica cada evento a una respuesta vacía, como el hook. */
async function conversar(llamar: typeof fetch, signal?: AbortSignal) {
  let m: MensajeAsistente = respuestaVacia('r1')
  const eventos: EventoAsistente[] = []
  const resultado: Resultado = await preguntarAlAsistente({
    ...BASE,
    signal,
    fetch: llamar,
    alEvento: (e) => {
      eventos.push(e)
      m = aplicarEvento(m, e)
    },
  })
  if (resultado.tipo === 'completa') m = alTerminarElFlujo(m)
  else if (resultado.tipo === 'parada') m = parada(m)
  else m = conFallo(m, resultado.fallo)
  return { resultado, eventos, m }
}

async function pruebas() {
  console.log('── Una respuesta entera, en trozos ───────────────────────────')
  {

    const sse =
      'event: herramienta\ndata: {"id":"t1","rotulo":"Leyendo lo recuperado","estado":"consultando"}\n\n' +
      'event: herramienta\ndata: {"id":"t1","rotulo":"Leyendo lo recuperado","estado":"hecho"}\n\n' +
      'event: texto\ndata: {"delta":"Esta semana se recuperó "}\n\n' +
      'event: texto\ndata: {"delta":"$1.250 en año y señal."}\n\n' +
      'event: enlace\ndata: {"titulo":"Cartera vencida","ruta":"/admin/cobranza"}\n\n' +
      'event: fin\ndata: {"modelo":"claude-opus-5","entrada":900,"salida":40,"cacheLeida":800}\n\n'
    // Trozos de 7 bytes: parten líneas, el JSON y la «ñ» (dos bytes) por la mitad.
    const bytes = codificar(sse)
    const trozos: Uint8Array[] = []
    for (let i = 0; i < bytes.length; i += 7) trozos.push(bytes.slice(i, i + 7))

    const { llamar, recibidas } = fetchDeMentira(
      () => new Response(flujoDe(trozos), { status: 200, headers: { 'Content-Type': 'text/event-stream' } }),
    )
    const { resultado, m } = await conversar(llamar)

    igual(resultado, { tipo: 'completa' }, 'termina completa')
    igual(m.estado, 'lista', 'con el evento de fin, la respuesta queda lista')
    igual(
      m.piezas,
      [
        { tipo: 'texto', texto: 'Esta semana se recuperó $1.250 en año y señal.' },
        { tipo: 'enlace', enlace: { titulo: 'Cartera vencida', ruta: '/admin/cobranza' } },
      ],
      'el texto llega entero y sin romper la «ñ» ni el «$»',
    )
    igual(m.herramientas, [{ id: 't1', rotulo: 'Leyendo lo recuperado', estado: 'hecho' }], 'la consulta cambia de estado, no se duplica')

    const p = recibidas[0]
    igual(p.url, `${BASE.url}${RUTA_DE_LA_FUNCION}`, 'llama a la función admin-asistente')
    igual(p.init?.method, 'POST', 'por POST')
    const cabeceras = new Headers(p.init?.headers)
    igual(cabeceras.get('Authorization'), 'Bearer jwt-de-prueba', 'con el JWT de la sesión')
    igual(cabeceras.get('apikey'), 'clave-publica', 'con la clave pública')
    igual(
      typeof p.init?.body === 'string' ? JSON.parse(p.init.body) : null,
      { conversacion: BASE.conversacion, rutaActual: BASE.rutaActual },
      'manda la conversación y la ruta actual',
    )

  }

  console.log('── Sin evento de fin ─────────────────────────────────────────')
  {
    const { llamar } = fetchDeMentira(
      () => new Response(flujoDe([codificar('event: texto\ndata: {"delta":"A medias"}\n\n')])),
    )
    const { m } = await conversar(llamar)
    igual([m.estado, m.fallo?.causa, m.fallo?.reintentar], ['fallida', 'cortada', true], 'se dice que se cortó, y se puede reintentar')
    igual(m.piezas.length, 1, 'lo que llegó se conserva')
  }

  console.log('── Un error dentro del flujo ─────────────────────────────────')
  {
    const { llamar } = fetchDeMentira(
      () =>
        new Response(
          flujoDe([codificar('event: error\ndata: {"mensaje":"La API del modelo no contesta.","reintentar":true}\n\n')]),
        ),
    )
    const { m } = await conversar(llamar)
    igual(m.fallo, { causa: 'servidor', mensaje: 'La API del modelo no contesta.', reintentar: true }, 'el mensaje del servidor, con reintento')
  }
  {
    const { llamar } = fetchDeMentira(
      () =>
        new Response(
          flujoDe([
            codificar(
              'event: error\ndata: {"codigo":"saturado","mensaje":"El asistente está saturado.","reintentar":true,"detalle":"Gemini 503 UNAVAILABLE: x"}\n\n',
            ),
          ]),
        ),
    )
    const { m } = await conversar(llamar)
    igual(
      m.fallo,
      { causa: 'saturado', mensaje: 'El asistente está saturado.', reintentar: true, detalle: 'Gemini 503 UNAVAILABLE: x' },
      'el formato nuevo: saturado, con el detalle aparte',
    )
  }

  console.log('── Parar ─────────────────────────────────────────────────────')
  {
    const control = new AbortController()
    const { llamar } = fetchDeMentira(
      (init) =>
        new Response(
          new ReadableStream<Uint8Array>({
            start(c) {
              c.enqueue(codificar('event: herramienta\ndata: {"id":"t1","rotulo":"Leyendo","estado":"consultando"}\n\n'))
              init?.signal?.addEventListener('abort', () =>
                c.error(new DOMException('Parado', 'AbortError')),
              )
            },
          }),
        ),
    )
    const promesa = conversar(llamar, control.signal)
    setTimeout(() => control.abort(), 20)
    const { resultado, m } = await promesa
    igual(resultado, { tipo: 'parada' }, 'Parar no es un fallo')
    igual([m.estado, m.herramientas[0]?.estado], ['parada', 'error'], 'la consulta en curso deja de girar')
  }

  console.log('── Estados HTTP ──────────────────────────────────────────────')
  {
    const limite = 'Has hecho 30 preguntas en la última hora; el límite es 30'
    const { llamar } = fetchDeMentira(() => new Response(JSON.stringify({ mensaje: limite }), { status: 429 }))
    const { m } = await conversar(llamar)
    igual(m.fallo, { causa: 'limite', mensaje: limite, reintentar: false }, '429: el mensaje del límite, sin reintento')
  }
  {
    // El resto de estados se prueba sin red en `errores.test.ts`.
    const { llamar } = fetchDeMentira(() => new Response('', { status: 503 }))
    const { m } = await conversar(llamar)
    igual([m.fallo?.causa, m.fallo?.reintentar], ['servidor', true], '503 sin código: la pasarela, con reintento')
  }

  {
    const { llamar } = fetchDeMentira(() => {
      throw new TypeError('Failed to fetch')
    })
    const { m } = await conversar(llamar)
    igual([m.fallo?.causa, m.fallo?.reintentar], ['red', true], 'sin red: fallo de red con reintento')
  }

  console.log('── Un servidor HTTP de verdad ────────────────────────────────')
  {
    const servidor = createServer((peticion, respuesta) => {
      let cuerpo = ''
      peticion.on('data', (c: Buffer) => (cuerpo += c.toString()))
      peticion.on('end', () => {
        const turnos = comoLista(comoFila(JSON.parse(cuerpo)).conversacion)
        const pregunta = texto(comoFila(turnos.at(-1)).texto)
        respuesta.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' })
        respuesta.write(': latido\n\n')
        respuesta.write('event: texto\ndata: {"delta":"Preguntaste: ')
        setTimeout(() => {
          respuesta.write(`${JSON.stringify(pregunta).slice(1, -1)}"}\n\n`)
          respuesta.end('event: fin\ndata: {"modelo":"m","entrada":1,"salida":1,"cacheLeida":0}\n\n')
        }, 10)
      })
    })
    await new Promise<void>((listo) => servidor.listen(0, '127.0.0.1', listo))
    const direccion = servidor.address()
    const port = typeof direccion === 'object' && direccion ? direccion.port : 0
    const resultado = await (async () => {
      let m = respuestaVacia('r')
      const r = await preguntarAlAsistente({
        ...BASE,
        url: `http://127.0.0.1:${port}`,
        alEvento: (e) => (m = aplicarEvento(m, e)),
      })
      return { r, m: r.tipo === 'completa' ? alTerminarElFlujo(m) : m }
    })()
    servidor.close()
    igual(resultado.r, { tipo: 'completa' }, 'contesta por HTTP')
    igual(
      resultado.m.piezas,
      [{ tipo: 'texto', texto: 'Preguntaste: ¿Cuánto se recuperó esta semana?' }],
      'el texto llega entero a través de la red',
    )
  }
}

await pruebas()
console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
