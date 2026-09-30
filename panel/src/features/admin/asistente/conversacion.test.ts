/**
 * Pruebas de la conversación: cómo crece una respuesta, qué se le reenvía al
 * servidor y qué sobrevive a una recarga.
 *
 *   npx tsx src/features/admin/asistente/conversacion.test.ts
 *
 * Lo que no puede pasar: que al servidor le lleguen dos preguntas seguidas
 * sin respuesta entre medias, o que una conversación guardada y rota tumbe el
 * panel al abrirlo.
 */
import {
  aplicarEvento,
  bloquesDeRespuesta,
  conFallo,
  escribirConversacion,
  historialParaEnviar,
  leerConversacion,
  MENSAJES_GUARDADOS,
  respuestaVacia,
  textoDeRespuesta,
  ultimaPregunta,
} from './conversacion'
import type { Mensaje, MensajeAsistente } from './conversacion'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

console.log('── Una respuesta, evento a evento ────────────────────────────')

let r: MensajeAsistente = respuestaVacia('a1')
r = aplicarEvento(r, { tipo: 'texto', delta: 'Se recuperaron ' })
r = aplicarEvento(r, { tipo: 'texto', delta: '$1.250.' })
r = aplicarEvento(r, { tipo: 'enlace', enlace: { titulo: 'Cartera vencida', ruta: '/admin/cobranza' } })
r = aplicarEvento(r, { tipo: 'texto', delta: ' Más detalle abajo.' })
igual(
  r.piezas.map((p) => p.tipo),
  ['texto', 'enlace', 'texto'],
  'el texto se junta hasta que llega otra pieza, y luego abre otra',
)
igual(textoDeRespuesta(r), 'Se recuperaron $1.250. Más detalle abajo.', 'el texto de la respuesta, sin lo dibujado')

r = aplicarEvento(r, { tipo: 'herramienta', herramienta: { id: 't1', rotulo: 'Leyendo', estado: 'consultando' } })
r = aplicarEvento(r, { tipo: 'herramienta', herramienta: { id: 't2', rotulo: 'Contando', estado: 'consultando' } })
r = aplicarEvento(r, { tipo: 'herramienta', herramienta: { id: 't1', rotulo: 'Leyendo', estado: 'hecho' } })
r = aplicarEvento(r, { tipo: 'fin', fin: { modelo: 'm', entrada: 1, salida: 1, cacheLeida: 0 } })
igual(r.estado, 'lista', 'fin: la respuesta queda lista')
igual(
  r.herramientas.map((h) => h.estado),
  ['hecho', 'error'],
  'fin: lo que seguía consultando ya no gira',
)

console.log('── Los bloques que se pintan ─────────────────────────────────')

{
  const a = { titulo: 'A', ruta: '/admin/cobranza' }
  const b = { titulo: 'B', ruta: '/admin/riesgo' }
  const c = { titulo: 'C', ruta: '/admin/dinero' }
  const bloques = bloquesDeRespuesta([
    { tipo: 'texto', texto: 'Mira esto.' },
    { tipo: 'enlace', enlace: a },
    { tipo: 'enlace', enlace: b },
    { tipo: 'texto', texto: 'Y además:' },
    { tipo: 'enlace', enlace: c },
  ])
  igual(
    bloques.map((x) => (x.tipo === 'enlaces' ? x.enlaces.map((e) => e.titulo).join('+') : x.pieza.tipo)),
    ['texto', 'A+B', 'texto', 'C'],
    'los enlaces seguidos van en una fila; un texto entre medias los separa',
  )
  igual(bloquesDeRespuesta([]), [], 'una respuesta sin piezas no tiene bloques')
}

console.log('── Lo que se reenvía al servidor ─────────────────────────────')

const persona = (id: string, texto: string): Mensaje => ({ id, rol: 'persona', texto })
const lista = (id: string, texto: string): MensajeAsistente => ({
  ...respuestaVacia(id),
  estado: 'lista',
  piezas: [{ tipo: 'texto', texto }],
})
const fallida: MensajeAsistente = conFallo(respuestaVacia('x'), {
  causa: 'red',
  mensaje: 'Sin red',
  reintentar: true,
})

igual(
  historialParaEnviar([persona('1', '¿Cuánto?'), lista('2', '$10'), persona('3', '¿Y ayer?')]),
  [
    { rol: 'persona', texto: '¿Cuánto?' },
    { rol: 'asistente', texto: '$10' },
    { rol: 'persona', texto: '¿Y ayer?' },
  ],
  'cada pregunta con su respuesta, y la última sola',
)
igual(
  historialParaEnviar([persona('1', 'Primera'), fallida, persona('3', 'Segunda')]),
  [{ rol: 'persona', texto: 'Segunda' }],
  'una pregunta cuya respuesta falló sin texto no se reenvía',
)
igual(
  ultimaPregunta([persona('1', 'Primera'), lista('2', 'x'), persona('3', 'Segunda'), fallida])?.texto,
  'Segunda',
  'la pregunta que se reintenta es la última',
)

console.log('── Lo que se guarda en la sesión ─────────────────────────────')

const escribiendo: MensajeAsistente = {
  ...respuestaVacia('4'),
  piezas: [{ tipo: 'texto', texto: 'A medias' }],
  herramientas: [{ id: 't', rotulo: 'Leyendo', estado: 'consultando' }],
}
const guardada = escribirConversacion([persona('1', 'Hola'), lista('2', 'Buenas'), persona('3', '¿Y?'), escribiendo])
const leida = leerConversacion(guardada)
igual(leida.length, 4, 'se recupera entera')
const ultima = leida.at(-1)
igual(
  ultima?.rol === 'asistente' ? [ultima.estado, ultima.herramientas[0]?.estado] : null,
  ['parada', 'error'],
  'lo que se estaba escribiendo al recargar queda parado',
)
igual(leerConversacion('{roto'), [], 'un JSON roto: conversación vacía')
igual(leerConversacion(null), [], 'nada guardado: conversación vacía')
igual(
  leerConversacion(JSON.stringify([{ id: '1', rol: 'otro', texto: 'x' }, { rol: 'persona', texto: 'sin id' }, { id: '2', rol: 'persona', texto: 'bien' }])),
  [{ id: '2', rol: 'persona', texto: 'bien' }],
  'lo que no encaja se descarta y lo demás se queda',
)
igual(
  leerConversacion(
    JSON.stringify([
      {
        id: '1',
        rol: 'asistente',
        estado: 'lista',
        piezas: [
          { tipo: 'grafico', grafico: { tipo: 'barras', titulo: 'x', unidad: 'eur', puntos: [] } },
          { tipo: 'texto', texto: 'queda' },
        ],
        herramientas: [],
      },
    ]),
  ).map((m) => (m.rol === 'asistente' ? m.piezas.length : -1)),
  [1],
  'una pieza inválida se descarta al leer',
)
{
  const ocupada = conFallo(respuestaVacia('9'), {
    causa: 'saturado',
    mensaje: 'Ocupado.',
    reintentar: true,
    detalle: 'Gemini 503 UNAVAILABLE',
  })
  const releida = leerConversacion(escribirConversacion([persona('8', '¿Cuánto?'), ocupada])).at(-1)
  igual(
    releida?.rol === 'asistente' ? releida.fallo : null,
    { causa: 'saturado', mensaje: 'Ocupado.', reintentar: true, detalle: 'Gemini 503 UNAVAILABLE' },
    'un fallo de las causas nuevas sobrevive a la recarga, con su detalle',
  )
}
const muchas = Array.from({ length: MENSAJES_GUARDADOS + 10 }, (_, i) => persona(String(i), `p${i}`))
igual(leerConversacion(escribirConversacion(muchas)).length, MENSAJES_GUARDADOS, `se guardan como mucho ${MENSAJES_GUARDADOS} mensajes`)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
