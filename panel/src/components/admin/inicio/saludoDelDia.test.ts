/**
 * Pruebas del saludo de Inicio.
 *
 *   npx tsx src/components/admin/inicio/saludoDelDia.test.ts
 *
 * Lo que se vigila: que cada hora de Caracas caiga en su momento del día, con
 * los bordes (las 5, las 12, las 19) en el momento que empieza, y que sin
 * nombre de pila el saludo se quede sin coma.
 */
import { momentoDelDia, saludo } from './saludoDelDia'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('── El momento del día ───────────────────────────────────────')
{
  comprueba(momentoDelDia(0) === 'noche', 'la medianoche es de noche')
  comprueba(momentoDelDia(4) === 'noche', 'a las 4 sigue siendo de noche')
  comprueba(momentoDelDia(5) === 'manana', 'a las 5 empieza la mañana')
  comprueba(momentoDelDia(11) === 'manana', 'a las 11 sigue siendo de mañana')
  comprueba(momentoDelDia(12) === 'tarde', 'a las 12 empieza la tarde')
  comprueba(momentoDelDia(18) === 'tarde', 'a las 18 sigue siendo de tarde')
  comprueba(momentoDelDia(19) === 'noche', 'a las 19 empieza la noche')
  comprueba(momentoDelDia(23) === 'noche', 'a las 23, de noche')
}

console.log('\n── El saludo ────────────────────────────────────────────────')
{
  comprueba(saludo(8, 'Javier') === 'Buenos días, Javier', 'por la mañana, con el nombre')
  comprueba(saludo(15, 'Javier') === 'Buenas tardes, Javier', 'por la tarde, con el nombre')
  comprueba(saludo(22, 'Javier') === 'Buenas noches, Javier', 'por la noche, con el nombre')
  comprueba(saludo(15, null) === 'Buenas tardes', 'sin nombre de pila, sin coma')
  comprueba(saludo(15, '   ') === 'Buenas tardes', 'un nombre en blanco es como ninguno', saludo(15, '   '))
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
