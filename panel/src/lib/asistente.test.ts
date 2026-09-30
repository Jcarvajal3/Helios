/**
 * Pruebas de la lectura de `VITE_ASISTENTE`.
 *
 *   npx tsx src/lib/asistente.test.ts
 *
 * Lo que se vigila: que el asistente solo se encienda con un `1` explícito.
 * Sin la variable, o con cualquier otra cosa, se queda apagado: hasta la fase
 * 5 no hay Edge Function a la que preguntarle.
 */
import { leerAsistente } from './asistente'

let fallos = 0

function comprueba(ok: boolean, titulo: string) {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}`)
}

comprueba(leerAsistente('1'), '«1» lo enciende')
comprueba(leerAsistente(' 1 '), 'con espacios alrededor, también')
comprueba(!leerAsistente(undefined), 'sin la variable, apagado')
comprueba(!leerAsistente(''), 'vacía, apagado')
comprueba(!leerAsistente('0'), '«0», apagado')
comprueba(!leerAsistente('true'), '«true» no es «1»: apagado')
comprueba(!leerAsistente(1), 'un número no llega de Vite: apagado')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
