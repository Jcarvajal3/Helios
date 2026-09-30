/**
 * Pruebas de cómo se nombra la cuenta.
 *
 *   npx tsx src/components/layouts/cuenta.test.ts
 *
 * Lo que se vigila: que Inicio salude por el nombre de pila y nunca por un
 * correo, y que el disco del pie lleve dos letras que se reconozcan.
 */
import { iniciales, nombreDePila } from './cuenta'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function espera<T>(real: T, esperado: T, titulo: string) {
  comprueba(real === esperado, titulo, String(real))
}

console.log('── Nombre de pila ────────────────────────────────────────────')
espera(nombreDePila('Javier Carvajal'), 'Javier', 'la primera palabra')
espera(nombreDePila('  maría josé pérez '), 'María', 'con mayúscula inicial y sin espacios')
espera(nombreDePila('Ana'), 'Ana', 'un nombre solo')
espera(nombreDePila('javier@helios'), null, 'un correo no es un nombre')
espera(nombreDePila(''), null, 'vacío')
espera(nombreDePila(null), null, 'sin nombre guardado')
espera(nombreDePila(undefined), null, 'sin el dato')

console.log('── Iniciales ─────────────────────────────────────────────────')
espera(iniciales('Javier Carvajal'), 'JC', 'nombre y apellido')
espera(iniciales('javier.carvajal@helios'), 'JC', 'de un correo, lo de antes de la arroba')
espera(iniciales('Ana'), 'AN', 'un nombre solo')
espera(iniciales('   '), '?', 'nada que leer')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
