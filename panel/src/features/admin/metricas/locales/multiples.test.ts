/**
 * Pruebas de los pequeños múltiplos del consumo por semana.
 *
 *   npx tsx src/features/admin/metricas/locales/multiples.test.ts
 *
 * Lo que se vigila: que todos los locales compartan la escala (redonda, y por
 * encima de la barra más alta), que la barra más alta quede escrita, que la
 * nota diga «empezó el…» para un local que arrancó dentro de la ventana y la
 * comparación a la misma altura para los demás, y que un cero sea un cero.
 */
import { RESPUESTA_SEMANA } from './__fixtures__/semana'
import { leerLocalesDeLaSemana } from './lectura'
import { pequenosMultiplos, textoDeCima } from './multiples'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const d = leerLocalesDeLaSemana(RESPUESTA_SEMANA)
const m = pequenosMultiplos(d)

igual(m.semanas.length, 8, 'ocho semanas')
igual(m.rango, 'de 3–9 ago a 21–27 sep', 'el rango, escrito')
igual(m.escala, { tope: 600, marcas: [0, 150, 300, 450, 600] }, 'una escala redonda común, por encima de la barra más alta')
igual(textoDeCima(m.cima), '$548,40 · La Quinta Bar, 21–27 sep', 'la barra más alta, escrita')
igual(m.filas.map((f) => f.merchantId), ['lq', 'em', 'nl'], 'en el orden de la tabla, sin la clínica que no vendió')
igual(
  m.filas.map((f) => f.nota),
  ['▲ 7 % a estas alturas', '▲ 20 % a estas alturas', 'empezó el 25 sep'],
  'la nota: la comparación a la misma altura, o cuándo empezó',
)
const em = m.filas.at(1)
igual(em?.barras.map((b) => b.valor), [0, 0, 0, 0, 0, 232, 303, 364], 'un cero es un cero')
igual(em?.barras.map((b) => b.destacada), [false, false, false, false, false, false, false, true], 'solo la elegida va destacada')
igual(em?.barras[7]?.fraccion, 364 / 600, 'la altura se mide contra el tope común')
igual(em?.ultimo, 364, 'lo de la semana elegida')
igual(
  em?.barras.slice(-3).map((b) => [b.consumos, b.personas]),
  [
    [9, 14],
    [11, 17],
    [13, 19],
  ],
  'cada barra lleva sus financiamientos y su gente, para el globo',
)

const cerrada = pequenosMultiplos({ ...d, anterior: { ...d.anterior, mismaAltura: false } })
igual(cerrada.filas[0]?.nota, '▲ 7 % frente a la anterior', 'con la semana cerrada, frente a la anterior')

const vacia = pequenosMultiplos({ ...d, series: { semanas: d.series.semanas, locales: [] } })
igual([vacia.filas.length, vacia.escala.tope, textoDeCima(vacia.cima)], [0, 0, null], 'sin financiamientos no hay escala ni cima')

if (fallos > 0) {
  console.error(`\n${fallos} prueba(s) fallaron`)
  process.exit(1)
}
console.log('\nTodo bien.')
