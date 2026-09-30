/**
 * Pruebas del modo cola.
 *
 *   npx tsx src/components/admin/ModoCola.test.ts
 *
 * La posición es aritmética y se prueba entera. Lo demás toca el navegador:
 * aquí solo se comprueba que sin `sessionStorage` (Node, modo privado) guardar
 * una cola no revienta la lista que la abre.
 */
import { abrirEnCola, posicionEnCola } from './ModoCola'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const ids = ['a', 'b', 'c', 'd']

console.log('── posicionEnCola ────────────────────────────────────────────')
igual(posicionEnCola(ids, 'a'), { posicion: 1, total: 4, siguiente: 'b' }, 'la primera: sin anterior')
igual(posicionEnCola(ids, 'c'), { posicion: 3, total: 4, anterior: 'b', siguiente: 'd' }, 'una del medio')
igual(posicionEnCola(ids, 'd'), { posicion: 4, total: 4, anterior: 'c' }, 'la última: sin siguiente')
igual(posicionEnCola(ids, 'z'), { posicion: 0, total: 0 }, 'una que no está: total 0 y no hay barra')
igual(posicionEnCola([], 'a'), { posicion: 0, total: 0 }, 'cola vacía')
igual(posicionEnCola(['a'], 'a'), { posicion: 1, total: 1 }, 'cola de una')

console.log('\n── Sin almacenamiento no revienta ───────────────────────────')
let reviento = false
try {
  abrirEnCola('pagos', ids)
} catch {
  reviento = true
}
igual(reviento, false, 'abrirEnCola sin sessionStorage no lanza')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
