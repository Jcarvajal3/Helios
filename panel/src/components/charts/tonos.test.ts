/**
 * Pruebas de los colores de los gráficos.
 *
 *   npx tsx src/components/charts/tonos.test.ts
 *
 * Los pasos de la rampa se validaron con `validate_palette.js --ordinal` en
 * oscuro sobre #161616 (los cinco tonos de área, de 2 a 6 pasos). Esto
 * comprueba que nadie los rompe sin darse cuenta: ningún hex, ningún lima, la
 * rampa ordenada de claro a oscuro y ninguna serie repetida.
 */
import { SERIE, colorDeTono, rampaApilada, rampaOrdinal, tonoDeSerie } from './tonos'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle: string) {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  comprueba(a === b, titulo, `dio ${a}, se esperaba ${b}`)
}

/** Cuánto tono del área lleva un paso, con signo: + hacia el blanco, − hacia la tarjeta. */
function claridad(color: string): number {
  if (color === SERIE.principal) return 0
  const m = /var\(--area\) (\d+)%, var\(--color-(on-surface|panel-card)\)/.exec(color)
  if (!m) return NaN
  const resto = 100 - Number(m[1])
  return m[2] === 'on-surface' ? resto : -resto
}

console.log('── SERIE ─────────────────────────────────────────────────────')
const todos = [
  ...Object.values(SERIE),
  ...rampaOrdinal(6),
  ...(['area', 'neutro', 'neutral', 'brand', 'success', 'warning', 'error'] as const).map(colorDeTono),
]
comprueba(!todos.some((c) => c.includes('#')), 'ni un hex', todos.filter((c) => c.includes('#')).join(', '))
comprueba(
  !todos.some((c) => c.includes('primary')),
  'ni un lima: es de la acción principal',
  todos.filter((c) => c.includes('primary')).join(', '),
)
igual(SERIE.principal, 'var(--area)', 'la protagonista es el tono del área')

console.log('\n── colorDeTono ───────────────────────────────────────────────')
igual(colorDeTono('area'), 'var(--area)', 'el área')
igual(colorDeTono('warning'), 'var(--color-warning)', 'el estado, con su token')
igual(colorDeTono('brand'), SERIE.contexto, 'la marca se pinta en gris: chocaba con Riesgo')
igual(colorDeTono('neutral'), SERIE.contexto, 'neutro es gris')

console.log('\n── rampaOrdinal ──────────────────────────────────────────────')
igual(rampaOrdinal(0), [], 'cero pasos, nada')
igual(rampaOrdinal(1), ['var(--area)'], 'un paso es el tono tal cual')
for (const n of [2, 3, 4, 5, 6, 8]) {
  const r = rampaOrdinal(n)
  const c = r.map(claridad)
  comprueba(r.length === n, `${n} pasos dan ${n} colores`, `dio ${r.length}`)
  comprueba(
    c.every((v, i) => i === 0 || v < c[i - 1]),
    `${n} pasos van de claro a oscuro`,
    `claridades ${c.join(' / ')}`,
  )
  comprueba(new Set(r).size === n, `${n} pasos, ninguno repetido`, r.join(' | '))
}
igual(rampaOrdinal(3)[1], 'var(--area)', 'con un número impar, el tono puro va en medio')
{
  const c = rampaOrdinal(6).map(claridad)
  comprueba(c[0] === 55 && c[5] === -50, 'con seis pasos llega a los extremos validados', c.join(' / '))
  const c8 = rampaOrdinal(8).map(claridad)
  comprueba(c8[0] === 55 && c8[7] === -50, 'con más, no se sale de ellos', c8.join(' / '))
}

console.log('\n── rampaApilada ──────────────────────────────────────────────')
igual(rampaApilada(0), [], 'cero tramos, nada')
igual(rampaApilada(1), ['var(--area)'], 'el tramo de abajo es el tono del área')
{
  const c = rampaApilada(3).map(claridad)
  comprueba(
    c[0] === 0 && c[1] > c[0] && c[2] > c[1],
    'cada tramo de encima, un paso más claro',
    c.join(' / '),
  )
  comprueba(c[2] <= 55, 'sin pasar del extremo claro validado', c.join(' / '))
  const r = rampaApilada(5)
  comprueba(!r.some((x) => x.includes('#') || x.includes('primary')), 'ni un hex ni un lima', r.join(' | '))
}

console.log('\n── tonoDeSerie ───────────────────────────────────────────────')
igual(tonoDeSerie(0, 1), 'var(--area)', 'una serie sola es la protagonista')
igual(tonoDeSerie(0, 2), 'var(--area)', 'con dos, la 0 es la protagonista por defecto')
igual(tonoDeSerie(1, 2), SERIE.contexto, 'y la otra, gris de contexto')
igual(tonoDeSerie(1, 2, 1), 'var(--area)', 'la protagonista puede ser la última')
igual(tonoDeSerie(0, 2, 1), SERIE.contexto, 'y entonces la primera es el contexto')
{
  const cuatro = [0, 1, 2, 3].map((i) => tonoDeSerie(i, 4, 3))
  const c = cuatro.map(claridad)
  comprueba(new Set(cuatro).size === 4, 'con cuatro, ninguna repetida', cuatro.join(' | '))
  comprueba(
    c[3] === 0 && c[2] > c[1] && c[1] > c[0],
    'las demás se apagan cuanto más lejos de la protagonista',
    c.join(' / '),
  )
  const medio = [0, 1, 2, 3].map((i) => tonoDeSerie(i, 4, 1))
  comprueba(new Set(medio).size === 4, 'con la protagonista en medio, tampoco se repiten', medio.join(' | '))
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
