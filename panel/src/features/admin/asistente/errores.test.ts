/**
 * Pruebas de cómo se leen los fallos del asistente: el evento `error` en sus
 * dos formatos, los estados HTTP y lo que el aviso enseña de cada uno.
 *
 *   npx tsx src/features/admin/asistente/errores.test.ts
 *
 * Lo que no puede pasar: que un Gemini saturado se pinte como «no pudo
 * contestar» en rojo con el texto en inglés de Google dentro de la frase, o
 * que un 503 de la pasarela diga que el asistente no está configurado.
 */
import type { Fallo } from './conversacion'
import {
  avisoDelFallo,
  codigoPorTexto,
  falloDelFlujo,
  falloPorEstado,
  leerErrorDelFlujo,
  mensajeDelCuerpo,
  separarDetalle,
  seReintentaSolo,
} from './errores'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

console.log('── El formato nuevo ──────────────────────────────────────────')

igual(
  leerErrorDelFlujo({
    codigo: 'saturado',
    mensaje: 'El asistente está saturado en este momento. Vuelve a intentarlo en un minuto.',
    reintentar: true,
    detalle: 'Gemini 503 UNAVAILABLE: The model is overloaded.',
  }),
  {
    codigo: 'saturado',
    mensaje: 'El asistente está saturado en este momento. Vuelve a intentarlo en un minuto.',
    reintentar: true,
    detalle: 'Gemini 503 UNAVAILABLE: The model is overloaded.',
  },
  'saturado: la frase limpia y el detalle aparte',
)
igual(
  leerErrorDelFlujo({ codigo: 'cuota', mensaje: 'El asistente llegó a su cuota gratuita; prueba en un minuto.', reintentar: true }),
  { codigo: 'cuota', mensaje: 'El asistente llegó a su cuota gratuita; prueba en un minuto.', reintentar: true },
  'cuota sin detalle: no aparece la clave vacía',
)
igual(
  leerErrorDelFlujo({ codigo: 'conversacion_larga', mensaje: 'La conversación es demasiado larga.', reintentar: false }).codigo,
  'conversacion_larga',
  'conversación larga',
)
igual(
  leerErrorDelFlujo({ codigo: 'inventado', mensaje: 'El asistente está saturado en este momento.', reintentar: true }).codigo,
  'saturado',
  'un código que el panel no conoce se deduce de la frase',
)

console.log('── El formato viejo ──────────────────────────────────────────')

const viejoSaturado =
  'El asistente está saturado en este momento. Vuelve a intentarlo en un minuto (Gemini 503 UNAVAILABLE: The model is overloaded. Please try again later.).'
igual(
  leerErrorDelFlujo({ mensaje: viejoSaturado, reintentar: true }),
  {
    codigo: 'saturado',
    mensaje: 'El asistente está saturado en este momento. Vuelve a intentarlo en un minuto.',
    reintentar: true,
    detalle: 'Gemini 503 UNAVAILABLE: The model is overloaded. Please try again later.',
  },
  'saturado: el paréntesis sale de la frase y pasa al detalle',
)
igual(
  leerErrorDelFlujo({ mensaje: 'El asistente llegó a su cuota gratuita; prueba en un minuto.', reintentar: true }).codigo,
  'cuota',
  'la cuota gratuita (429) es cuota',
)
igual(
  leerErrorDelFlujo({
    mensaje:
      'El asistente no está bien configurado: la clave no es válida (Gemini 400 INVALID_ARGUMENT: API key not valid (clave) passed).',
    reintentar: false,
  }),
  {
    codigo: 'configuracion',
    mensaje: 'El asistente no está bien configurado: la clave no es válida.',
    reintentar: false,
    detalle: 'Gemini 400 INVALID_ARGUMENT: API key not valid (clave) passed',
  },
  'configuración: un paréntesis dentro del detalle no parte nada',
)
igual(
  leerErrorDelFlujo({
    mensaje:
      'El asistente no está disponible con esta cuenta de Gemini: el nivel gratuito no se admite desde aquí (Gemini 400 FAILED_PRECONDITION: User location is not supported).',
    reintentar: false,
  }).codigo,
  'configuracion',
  'el nivel gratuito no admitido es configuración',
)
igual(
  leerErrorDelFlujo({ mensaje: 'La conversación es demasiado larga. Empieza una conversación nueva.', reintentar: false })
    .codigo,
  'conversacion_larga',
  'conversación larga, sin código',
)
igual(
  leerErrorDelFlujo({ mensaje: 'No se pudo conectar con el asistente. Vuelve a intentarlo.', reintentar: true }),
  { codigo: 'otro', mensaje: 'No se pudo conectar con el asistente. Vuelve a intentarlo.', reintentar: true },
  'lo demás es «otro»',
)
igual(
  leerErrorDelFlujo({}),
  { codigo: 'otro', mensaje: 'El asistente no pudo contestar.', reintentar: false },
  'sin nada: una frase propia y sin reintento',
)
igual(
  separarDetalle('El asistente no pudo completar la consulta (Gemini 500 INTERNAL: boom).'),
  { mensaje: 'El asistente no pudo completar la consulta.', detalle: 'Gemini 500 INTERNAL: boom' },
  'separarDetalle quita el paréntesis y cierra la frase con su punto',
)
igual(separarDetalle('Una frase (con un paréntesis normal).'), { mensaje: 'Una frase (con un paréntesis normal).' }, 'un paréntesis que no es del proveedor se queda')
igual(codigoPorTexto('Algo falló', 'Gemini 502 BAD_GATEWAY: x'), 'saturado', 'un 5xx del proveedor en el detalle es saturado')

console.log('── Del evento al fallo ───────────────────────────────────────')

igual(
  falloDelFlujo({ codigo: 'saturado', mensaje: 'Ocupado.', reintentar: true, detalle: 'Gemini 503' }),
  { causa: 'saturado', mensaje: 'Ocupado.', reintentar: true, detalle: 'Gemini 503' },
  'saturado → saturado, con su detalle',
)
igual(falloDelFlujo({ codigo: 'configuracion', mensaje: 'x', reintentar: false }).causa, 'sin-configurar', 'configuración → sin configurar')
igual(falloDelFlujo({ codigo: 'conversacion_larga', mensaje: 'x', reintentar: false }).causa, 'conversacion-larga', 'larga → conversación larga')
igual(falloDelFlujo({ codigo: 'otro', mensaje: 'x', reintentar: true }).causa, 'servidor', 'otro → servidor')

console.log('── Estados HTTP ──────────────────────────────────────────────')

igual(
  falloPorEstado(503, ''),
  { causa: 'servidor', mensaje: 'El asistente no pudo contestar.', reintentar: true, detalle: 'HTTP 503' },
  '503 sin código: la pasarela, se reintenta (ya no es «sin configurar»)',
)
igual(
  falloPorEstado(503, '{"code":"BOOT_ERROR","message":"Function failed to start (please check logs)"}'),
  {
    causa: 'servidor',
    mensaje: 'El asistente no pudo contestar.',
    reintentar: true,
    detalle: 'HTTP 503 BOOT_ERROR · Function failed to start (please check logs)',
  },
  '503 de la pasarela: el inglés va al detalle, no a la frase',
)
igual(
  falloPorEstado(503, '{"error":"sin_clave","mensaje":"El asistente todavía no está configurado: falta la clave."}'),
  { causa: 'sin-configurar', mensaje: 'El asistente todavía no está configurado.', reintentar: false, detalle: 'HTTP 503 sin_clave' },
  '503 sin_clave: sin configurar, sin reintento',
)
igual(falloPorEstado(404, '').causa, 'sin-configurar', '404: la función no está desplegada')
igual(
  falloPorEstado(500, '{"error":"no_configurado","mensaje":"La función no tiene la configuración de Supabase."}').causa,
  'sin-configurar',
  '500 no_configurado: sin configurar',
)
igual(falloPorEstado(500, '{"error":"Falta GEMINI_API_KEY"}').causa, 'sin-configurar', '500 que habla de la clave: sin configurar')
igual(
  falloPorEstado(500, '{"error":"bitacora","mensaje":"No se pudo registrar la pregunta. Vuelve a intentarlo."}'),
  {
    causa: 'servidor',
    mensaje: 'No se pudo registrar la pregunta. Vuelve a intentarlo.',
    reintentar: true,
    detalle: 'HTTP 500 bitacora',
  },
  '500 de la función: su frase, y el código al detalle',
)
igual(
  falloPorEstado(401, '{"error":"sin_sesion","mensaje":"Hace falta iniciar sesión."}'),
  { causa: 'sin-permiso', mensaje: 'Hace falta iniciar sesión.', reintentar: false },
  '401: sin permiso, con el mensaje de la función',
)
igual(
  falloPorEstado(429, '{"error":"limite","mensaje":"Has hecho 30 preguntas en la última hora; el límite es 30"}'),
  { causa: 'limite', mensaje: 'Has hecho 30 preguntas en la última hora; el límite es 30', reintentar: false },
  '429 propio: el límite por hora, sin reintento',
)
igual(
  falloPorEstado(502, '<html>…</html>'),
  { causa: 'servidor', mensaje: 'El asistente no pudo contestar.', reintentar: true, detalle: 'HTTP 502' },
  '502 con HTML: una frase propia y el estado al detalle',
)
igual(mensajeDelCuerpo('  '), null, 'un cuerpo vacío no es un mensaje')

console.log('── Lo que enseña el aviso ────────────────────────────────────')

const saturado: Fallo = { causa: 'saturado', mensaje: 'El asistente está saturado.', reintentar: true }
igual(
  avisoDelFallo(saturado),
  { tono: 'warning', titulo: 'El asistente está ocupado', linea: 'El asistente está saturado.', buscar: true, empezarDeNuevo: false },
  'saturado: ámbar, «ocupado» y «Buscar en el panel»',
)
igual(avisoDelFallo({ causa: 'cuota', mensaje: 'x', reintentar: true }).buscar, true, 'cuota: también «Buscar en el panel»')
igual(seReintentaSolo(saturado), true, 'saturado se reintenta solo')
igual(seReintentaSolo({ causa: 'cuota', mensaje: 'x', reintentar: false }), false, 'sin permiso del servidor para reintentar, no')
igual(seReintentaSolo({ causa: 'servidor', mensaje: 'x', reintentar: true }), false, 'un fallo cualquiera no se reintenta solo')
igual(
  avisoDelFallo({ causa: 'sin-configurar', mensaje: 'El asistente todavía no está configurado.', reintentar: false }),
  { tono: 'warning', titulo: 'El asistente no está configurado', linea: null, buscar: false, empezarDeNuevo: false },
  'sin configurar genérico: el título basta',
)
igual(
  avisoDelFallo({ causa: 'conversacion-larga', mensaje: 'La conversación es demasiado larga.', reintentar: false }),
  { tono: 'warning', titulo: 'La conversación es demasiado larga', linea: null, buscar: false, empezarDeNuevo: true },
  'conversación larga: el botón de empezar de nuevo, sin repetir la frase',
)
igual(avisoDelFallo({ causa: 'servidor', mensaje: 'El asistente no pudo contestar.', reintentar: true }).linea, null, 'la frase que repite el título no se escribe dos veces')
igual(avisoDelFallo({ causa: 'red', mensaje: 'x', reintentar: true }).tono, 'error', 'red: rojo')
igual(avisoDelFallo({ causa: 'cortada', mensaje: 'x', reintentar: true }).tono, 'error', 'cortada: rojo')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
