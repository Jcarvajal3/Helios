/**
 * Pruebas de la lectura del entorno.
 *
 *   npx tsx src/lib/entorno.test.ts
 *
 * Lo que se vigila: que sin la variable sea producción (lo que pasa en
 * Vercel, donde no se pinta nada) y que un valor raro no encienda la
 * pastilla DEV.
 */
import { leerEntorno } from './entorno'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function espera(valor: unknown, sale: ReturnType<typeof leerEntorno>, titulo: string) {
  const real = leerEntorno(valor)
  comprueba(real === sale, titulo, real)
}

console.log('── Los tres valores ──────────────────────────────────────────')
espera('desarrollo', 'desarrollo', 'desarrollo')
espera('produccion', 'produccion', 'produccion')
espera('local', 'local', 'local')

console.log('── Escritos a mano ───────────────────────────────────────────')
espera('  Desarrollo ', 'desarrollo', 'se perdonan mayúsculas y espacios')

console.log('── Sin la variable: producción, sin pastilla ─────────────────')
espera(undefined, 'produccion', 'sin la variable')
espera('', 'produccion', 'vacía')
espera('dev', 'produccion', 'un valor que no es de la lista no enciende DEV')
espera('producción', 'produccion', 'con tilde tampoco es otra cosa')
espera(true, 'produccion', 'algo que no es texto')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
