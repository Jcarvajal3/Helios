/**
 * Pruebas del menú «⋯» y de la línea de datos de las fichas.
 *
 *   npx tsx src/components/admin/ficha/menu.test.ts
 *
 * Lo que se vigila: que las acciones que no aplican desaparezcan sin dejar
 * separadores huérfanos, y que la línea de datos no enseñe huecos.
 */
import type { ItemDeMenu } from '@/components/ui'
import { itemsDeMenu, lineaDeDatos } from './menu'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const nada = () => {}
const item = (label: string): ItemDeMenu => ({ label, onSelect: nada })

/** Los rótulos, con «—» por separador, para comparar de un vistazo. */
function forma(lista: ReadonlyArray<ItemDeMenu | 'separador'>): string {
  return lista.map((i) => (i === 'separador' ? '—' : i.label)).join(' ')
}

function espera(sale: ReadonlyArray<ItemDeMenu | 'separador'>, esperado: string, titulo: string) {
  const f = forma(sale)
  comprueba(f === esperado, titulo, `sale «${f}», se esperaba «${esperado}»`)
}

console.log('── itemsDeMenu ───────────────────────────────────────────────')
espera(itemsDeMenu([item('A'), 'separador', item('B')]), 'A — B', 'deja un separador entre dos grupos')
espera(itemsDeMenu([item('A'), null, false, undefined, item('B')]), 'A B', 'quita los huecos')
espera(itemsDeMenu(['separador', item('A')]), 'A', 'quita el separador del principio')
espera(itemsDeMenu([item('A'), 'separador']), 'A', 'quita el separador del final')
espera(
  itemsDeMenu([item('A'), 'separador', null, 'separador', item('B')]),
  'A — B',
  'dos separadores con un hueco en medio se quedan en uno',
)
espera(itemsDeMenu([item('A'), 'separador', false]), 'A', 'un grupo entero que no aplica no deja raya')
espera(itemsDeMenu([null, 'separador', false]), '', 'sin acciones, lista vacía')

console.log('── lineaDeDatos ──────────────────────────────────────────────')
comprueba(lineaDeDatos(['J-1', null, 'Caracas']) === 'J-1 · Caracas', 'une con punto medio y salta los nulos')
comprueba(lineaDeDatos(['', '  ', undefined, false]) === '', 'sin datos, cadena vacía')
comprueba(lineaDeDatos(['Solo']) === 'Solo', 'un dato, sin punto')

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
