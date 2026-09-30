/**
 * Pruebas de lo que el panel decide al pintar una respuesta: qué enlaces
 * existen, cómo se lee el texto, cómo se escriben las cifras y cuándo lo
 * tecleado en la paleta es una pregunta.
 *
 *   npx tsx src/features/admin/asistente/presentacion.test.ts
 *
 * Lo que no puede pasar: un botón que lleva a una pantalla que no existe, o
 * una cifra en euros escrita sin sus céntimos.
 */
import { enlaceValido, rutaConocida } from './enlaces'
import { pareceUnaPregunta } from './pregunta'
import { bloquesDe, trozosDe } from './texto'
import { FORMATO, esEntero, formatearCelda } from './unidades'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

console.log('── Enlaces ───────────────────────────────────────────────────')

igual(rutaConocida('/admin/cobranza'), true, 'una pantalla del catálogo existe')
igual(rutaConocida('/admin/cobranza/'), true, 'con la barra final, también')
igual(rutaConocida('/admin/inventada'), false, 'una ruta inventada no existe')
igual(rutaConocida('/admin/pacientes/0b6f6c1e-3d7a-4f3e-9d2a-1c2b3a4d5e6f'), true, 'la ficha de un paciente con su id')
igual(rutaConocida('/admin/pacientes/maria'), false, 'una ficha sin un id válido, no')
igual(rutaConocida('https://otro.sitio/admin/cobranza'), false, 'una dirección de fuera, no')
igual(
  enlaceValido({ titulo: 'Tramo 2', ruta: '/admin/cobranza?tramo=t2' }),
  { titulo: 'Tramo 2', ruta: '/admin/cobranza', search: { tramo: 't2' } },
  'una ruta con ?… pegado se parte en ruta y search',
)
igual(
  enlaceValido({ titulo: 'X', ruta: '/admin/cobranza?tramo=t2', search: { tramo: 't3' } }),
  { titulo: 'X', ruta: '/admin/cobranza', search: { tramo: 't3' } },
  'si trae search, manda sobre lo pegado a la ruta',
)
igual(enlaceValido({ titulo: 'X', ruta: '/admin/nada' }), null, 'un enlace a una ruta inexistente se descarta')

console.log('── Texto ─────────────────────────────────────────────────────')

igual(
  trozosDe('Se recuperaron **$1.250** esta semana'),
  [
    { texto: 'Se recuperaron ', negrita: false },
    { texto: '$1.250', negrita: true },
    { texto: ' esta semana', negrita: false },
  ],
  'la negrita se reconoce',
)
igual(
  trozosDe('Llegando **a medias'),
  [
    { texto: 'Llegando ', negrita: false },
    { texto: 'a medias', negrita: true },
  ],
  'una negrita todavía sin cerrar se pinta ya en negrita',
)
igual(
  bloquesDe('Primer párrafo.\nSigue.\n\n- uno\n- dos\n  continúa\n\n1. a\n2. b\n\n## Título').map((b) =>
    b.tipo === 'lista' ? `${b.ordenada ? 'ol' : 'ul'}:${b.elementos.length}` : b.tipo === 'parrafo' ? `p:${b.lineas.length}` : 'h',
  ),
  ['p:2', 'ul:2', 'ol:2', 'h'],
  'párrafos, listas con y sin número y títulos',
)
igual(
  bloquesDe('Texto\n- lista pegada').map((b) => b.tipo),
  ['parrafo', 'lista'],
  'una lista justo debajo de un párrafo abre su propio bloque',
)
igual(bloquesDe('\n\n'), [], 'sin texto no hay bloques')

console.log('── Unidades ──────────────────────────────────────────────────')

igual(FORMATO.eur.completo(1250.5), '$1.250,50', 'dólares con sus céntimos')
igual(FORMATO.numero.completo(12), '12', 'un recuento entero, sin decimales')
igual(FORMATO.numero.completo(2.35), '2,4', 'un número con decimales, con uno')
igual(FORMATO.pct.completo(7.25), '7,3 %', 'un porcentaje con decimales')
igual(esEntero('numero', [1, 2, 3]), true, 'un eje de pacientes es entero')
igual(esEntero('eur', [1, 2, 3]), false, 'uno de dólares, no')
igual(formatearCelda(null, 'eur'), '—', 'una celda vacía es una raya, no un cero')
igual(formatearCelda('La Quinta', undefined), 'La Quinta', 'un texto sale tal cual')
igual(formatearCelda(99.9, 'eur'), '$99,90', 'un monto en dólares')
igual(formatearCelda('2026-09-20', 'fecha'), '20/09/26', 'un día suelto, sin mover de zona')
igual(formatearCelda(12, 'texto'), '12', 'un número en una columna de texto, tal cual')

console.log('── ¿Es una pregunta? ─────────────────────────────────────────')

for (const t of ['¿cuánto se recuperó?', 'Cuánto se recuperó esta semana', 'por qué está congelada María', 'qué clínicas tienen más mora', 'mora de la quinta?', 'Quién debe más']) {
  igual(pareceUnaPregunta(t), true, `«${t}» es una pregunta`)
}
for (const t of ['María Pérez', '0414 123 4567', 'cartera vencida', 'cuantico', '?']) {
  igual(pareceUnaPregunta(t), false, `«${t}» no lo es`)
}

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
