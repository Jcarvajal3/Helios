/**
 * Pruebas de la lectura de montos.
 *
 *   npx tsx src/lib/montos.test.ts
 *
 * Sin framework, como el resto. Los casos que más importan son los dos que
 * motivaron el módulo: «1.250.400,00», que con `replace(',', '.')` daba NaN,
 * y «10.000», que `Number` leía como diez.
 */
import { formatoMontoEditable, leerMonto } from './montos'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle: string) {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function caso(texto: string, esperado: number | null, porque = '') {
  const dio = leerMonto(texto)
  const ok = esperado === null ? dio === null : dio !== null && Math.abs(dio - esperado) < 1e-9
  comprueba(ok, `«${texto}» → ${esperado}${porque ? ` (${porque})` : ''}`, `dio ${dio}`)
}

console.log('── Formato venezolano ───────────────────────────────────────')
caso('1.250.400,00', 1250400, 'el que daba NaN')
caso('1.250.400,5', 1250400.5)
caso('1.310,25', 1310.25)
caso('960,00', 960)
caso('1250,5', 1250.5)
caso('0,5', 0.5)
caso(',5', 0.5, 'a medio teclear')
caso('12,', 12, 'a medio teclear')
caso('1.234.567,89', 1234567.89)

console.log('\n── Punto y coma a la vez: el de la derecha es el decimal ────')
caso('1,250.50', 1250.5, 'formato inglés')
caso('1,234,567.89', 1234567.89)
caso('1.250,50', 1250.5)

console.log('\n── Solo puntos ──────────────────────────────────────────────')
caso('10.000', 10000, 'el que Number leía como diez')
caso('1.250', 1250, 'tres dígitos detrás: miles')
caso('12.500', 12500)
caso('123.456', 123456)
caso('1.250.400', 1250400, 'varios puntos: miles')
caso('1250.50', 1250.5, 'dos dígitos: decimal')
caso('1250.5', 1250.5)
caso('12.5', 12.5)
caso('1.2345', 1.2345, 'cuatro dígitos: decimal')
caso('1234.567', 1234.567, 'delante no cabe en un grupo de miles')
caso('0.125', 0.125, 'un cero delante no es un grupo de miles')
caso('.125', 0.125)
caso('12.', 12)

console.log('\n── Enteros ──────────────────────────────────────────────────')
caso('0', 0)
caso('00', 0)
caso('1250', 1250)
caso('007', 7)

console.log('\n── Símbolos, espacios y signo ───────────────────────────────')
caso('$ 12,50', 12.5)
caso('12,50 $', 12.5)
caso('$12,50', 12.5)
caso('Bs 1.250.400,00', 1250400)
caso('Bs. 1.250,00', 1250)
caso('1.250,00 Bs.', 1250)
caso('BS 20', 20, 'en mayúsculas')
caso('$12.50', 12.5)
caso('12 USD', 12)
caso('  1 250 400,00  ', 1250400, 'espacio de miles')
caso('1 250,00', 1250, 'espacio duro')
caso('-3,5', -3.5)
caso('- 3,5', -3.5)
caso('-$ 3,5', -3.5)
caso('$-3,5', -3.5)
caso('-1.250', -1250)
caso('+30.012,11', 30012.11, 'el más del extracto')
comprueba(Object.is(leerMonto('-0'), 0), '«-0» da 0 y no -0', `dio ${leerMonto('-0')}`)

console.log('\n── Vacío e inválido: null, nunca un cero ────────────────────')
caso('', null)
caso('   ', null)
caso('$', null)
caso('Bs.', null)
caso('-', null)
caso(',', null)
caso('.', null)
caso('doce', null)
caso('12abc', null)
caso('1e5', null, 'notación científica')
caso('12-', null, 'el signo detrás')
caso('--5', null)
caso('1,2,3', null, 'dos comas no son un decimal')
caso('12,345,678', null, 'comas de miles sin decimal: ambiguo')
caso('1.25,00', null, 'miles mal agrupados')
caso('1.2.3,4', null)
caso('1..2', null)
caso('1.234,56,7', null, 'el decimal dos veces')
caso('1,234.56.7', null)
caso('12.34.567', null, 'grupo de dos')
caso('1234.567.890', null, 'primer grupo de cuatro')
caso('NaN', null)
caso('Infinity', null)

console.log('\n── formatoMontoEditable ─────────────────────────────────────')
const editables: Array<[number | null | undefined, string]> = [
  [1250400.5, '1250400,5'],
  [12, '12'],
  [12.5, '12,5'],
  [0, '0'],
  [-0, '0'],
  [-3.25, '-3,25'],
  [1.125, '1,125'],
  [0.1 + 0.2, '0,3'],
  [null, ''],
  [undefined, ''],
  [NaN, ''],
  [Infinity, ''],
]
for (const [n, esperado] of editables) {
  const dio = formatoMontoEditable(n)
  comprueba(dio === esperado, `${n} → «${esperado}»`, `dio «${dio}»`)
}

console.log('\n── Ida y vuelta: lo que se rellena se lee igual ─────────────')
for (const n of [0, 1, 1.125, 2.5, 12.34, 999.999, 1000, 1250.5, 1250400, 1234567.89, -7.5, 0.005]) {
  const vuelta = leerMonto(formatoMontoEditable(n))
  comprueba(vuelta === n, `${n} ida y vuelta`, `volvió ${vuelta}`)
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
