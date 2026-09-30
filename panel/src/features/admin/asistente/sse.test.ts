/**
 * Pruebas del lector de `text/event-stream` y de la validación del protocolo.
 *
 *   npx tsx src/features/admin/asistente/sse.test.ts
 *
 * Lo que no puede pasar: que un trozo cortado a mitad de línea pierda un
 * evento, que un `\r\n` partido entre dos trozos parta también el evento, o
 * que un gráfico con un punto ilegible se dibuje sin ese punto.
 */
import { crearLectorDeEventos, crearLectorSSE, interpretarEvento } from './sse'
import { leerEnlace, leerGrafico, leerTabla, FILAS_MAXIMAS } from './protocolo'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

/** Empuja los trozos uno a uno y junta todo lo que sale, fin incluido. */
function leerEnTrozos(trozos: string[]) {
  const lector = crearLectorSSE()
  return [...trozos.flatMap((t) => lector.empujar(t)), ...lector.terminar()]
}

console.log('── El lector SSE ─────────────────────────────────────────────')

const DOS = 'event: texto\ndata: {"delta":"Hola"}\n\nevent: fin\ndata: {"modelo":"m"}\n\n'
const esperado = [
  { tipo: 'texto', datos: '{"delta":"Hola"}' },
  { tipo: 'fin', datos: '{"modelo":"m"}' },
]

igual(leerEnTrozos([DOS]), esperado, 'dos eventos en un solo trozo')
igual(leerEnTrozos(DOS.split('')), esperado, 'los mismos eventos, letra a letra')
igual(
  leerEnTrozos([DOS.replace(/\n/g, '\r\n')]),
  esperado,
  'con saltos \\r\\n',
)
igual(
  leerEnTrozos(['event: texto\r', '\ndata: {"delta":"Hola"}\r', '\n\r', '\nevent: fin\r\ndata: {"modelo":"m"}\r\n\r\n']),
  esperado,
  'un \\r\\n partido entre dos trozos no parte el evento',
)
igual(
  leerEnTrozos([DOS.replace(/\n/g, '\r')]),
  esperado,
  'con saltos \\r a secas',
)
igual(
  leerEnTrozos([': mantener viva\n\nevent: texto\ndata: {"delta":"a"}\n\n']),
  [{ tipo: 'texto', datos: '{"delta":"a"}' }],
  'un comentario no es un evento',
)
igual(
  leerEnTrozos(['event: texto\ndata: línea 1\ndata: línea 2\n\n']),
  [{ tipo: 'texto', datos: 'línea 1\nlínea 2' }],
  'varias líneas de data se juntan con un salto',
)
igual(
  leerEnTrozos(['event: texto\ndata:sin espacio\n\n']),
  [{ tipo: 'texto', datos: 'sin espacio' }],
  'data sin espacio tras los dos puntos',
)
igual(leerEnTrozos(['event: texto\n\n']), [], 'un evento sin data no se entrega')
igual(
  leerEnTrozos(['data: {"a":1}\n\n']),
  [{ tipo: 'message', datos: '{"a":1}' }],
  'sin event, el tipo es message',
)
igual(
  leerEnTrozos(['event: fin\ndata: {"modelo":"m"}']),
  [{ tipo: 'fin', datos: '{"modelo":"m"}' }],
  'el último evento sin línea en blanco se entrega al terminar',
)
igual(
  leerEnTrozos(['event: texto\ndata: {"delta":"a"}\n\n', 'event: texto\n']),
  [{ tipo: 'texto', datos: '{"delta":"a"}' }],
  'un evento a medias al terminar, sin data, se descarta',
)

console.log('── Eventos validados ─────────────────────────────────────────')

const lector = crearLectorDeEventos()
const eventos = [
  ...lector.empujar('event: texto\ndata: {"delta":"Se recuperaron "}\n\nevent: herram'),
  ...lector.empujar('ienta\ndata: {"id":"t1","rotulo":"Leyendo la cartera vencida","estado":"consultando"}\n\n'),
  ...lector.empujar('event: desconocido\ndata: {}\n\nevent: texto\ndata: {roto\n\n'),
  ...lector.empujar('event: error\ndata: {"mensaje":"La API no contesta","reintentar":true}\n\n'),
  ...lector.terminar(),
]
igual(
  eventos,
  [
    { tipo: 'texto', delta: 'Se recuperaron ' },
    {
      tipo: 'herramienta',
      herramienta: { id: 't1', rotulo: 'Leyendo la cartera vencida', estado: 'consultando' },
    },
    { tipo: 'error', error: { codigo: 'otro', mensaje: 'La API no contesta', reintentar: true } },
  ],
  'un tipo desconocido y un JSON roto se ignoran sin tumbar lo demás',
)

igual(
  interpretarEvento({ tipo: 'fin', datos: '{"modelo":"claude-opus-5","entrada":"120","salida":30}' }),
  { tipo: 'fin', fin: { modelo: 'claude-opus-5', entrada: 120, salida: 30, cacheLeida: 0 } },
  'fin: los tokens como número, aunque lleguen como texto',
)
igual(
  interpretarEvento({ tipo: 'error', datos: '{}' }),
  { tipo: 'error', error: { codigo: 'otro', mensaje: 'El asistente no pudo contestar.', reintentar: false } },
  'un error sin mensaje dice algo y no ofrece reintentar',
)
igual(
  interpretarEvento({ tipo: 'error', datos: '{"codigo":"cuota","mensaje":"Sin cuota.","reintentar":true,"detalle":"Gemini 429"}' }),
  { tipo: 'error', error: { codigo: 'cuota', mensaje: 'Sin cuota.', reintentar: true, detalle: 'Gemini 429' } },
  'un error del formato nuevo trae su código y su detalle',
)
igual(
  interpretarEvento({ tipo: 'herramienta', datos: '{"id":"t1","rotulo":"x","estado":"otro"}' }),
  null,
  'una herramienta con un estado desconocido se descarta',
)
igual(
  interpretarEvento({ tipo: 'texto', datos: '{"delta":5}' }),
  null,
  'un delta que no es texto se descarta',
)

console.log('── Enlaces, gráficos y tablas ────────────────────────────────')

igual(
  leerEnlace({ titulo: 'Cartera vencida', ruta: '/admin/cobranza', search: { tramo: 't2', x: { a: 1 }, 'mal clave': 1 } }),
  { titulo: 'Cartera vencida', ruta: '/admin/cobranza', search: { tramo: 't2' } },
  'enlace: del search solo pasan valores sueltos con clave limpia',
)
igual(leerEnlace({ titulo: 'Sin ruta' }), null, 'enlace sin ruta: se descarta')

const grafico = {
  tipo: 'barras',
  titulo: 'Recuperado por semana',
  unidad: 'eur',
  puntos: [
    { etiqueta: 'S1', valor: 10, valor2: 20 },
    { etiqueta: 'S2', valor: '12.5' },
  ],
  leyenda: { valor: 'Recuperado', valor2: 'Vencido' },
}
igual(
  leerGrafico(grafico),
  {
    tipo: 'barras',
    titulo: 'Recuperado por semana',
    unidad: 'eur',
    puntos: [
      { etiqueta: 'S1', valor: 10, valor2: 20 },
      { etiqueta: 'S2', valor: 12.5 },
    ],
    leyenda: { valor: 'Recuperado', valor2: 'Vencido' },
  },
  'gráfico: un número en texto se lee',
)
igual(
  leerGrafico({ ...grafico, puntos: [{ etiqueta: 'S1', valor: 10 }, { etiqueta: 'S2', valor: null }] }),
  null,
  'gráfico: un punto sin valor invalida el gráfico entero',
)
igual(leerGrafico({ ...grafico, unidad: 'usd' }), null, 'gráfico: una unidad desconocida se descarta')
igual(leerGrafico({ ...grafico, puntos: [] }), null, 'gráfico: sin puntos no hay gráfico')

const tabla = leerTabla({
  titulo: 'Clínicas con más mora',
  columnas: [
    { clave: 'local', rotulo: 'Clínica' },
    { clave: 'mora', rotulo: 'Mora', unidad: 'eur' },
    { rotulo: 'Sin clave' },
  ],
  filas: [
    { local: 'La Quinta', mora: 120.5, sobra: 'x' },
    { local: 'Sin mora', mora: null, activo: true },
  ],
})
igual(
  tabla,
  {
    titulo: 'Clínicas con más mora',
    columnas: [
      { clave: 'local', rotulo: 'Clínica' },
      { clave: 'mora', rotulo: 'Mora', unidad: 'eur' },
    ],
    filas: [
      { local: 'La Quinta', mora: 120.5 },
      { local: 'Sin mora', mora: null },
    ],
  },
  'tabla: solo las columnas declaradas, y lo que falta es null',
)
igual(
  leerTabla({
    titulo: 'Muchas',
    columnas: [{ clave: 'n', rotulo: 'N' }],
    filas: Array.from({ length: 80 }, (_, n) => ({ n })),
  })?.filas.length,
  FILAS_MAXIMAS,
  `tabla: nunca más de ${FILAS_MAXIMAS} filas`,
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
