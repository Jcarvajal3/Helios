/**
 * Pruebas de la geometría de las líneas y de la escala con negativos.
 *
 *   npx tsx src/components/charts/lineas.test.ts
 *
 * Lo que importa: un hueco (`null`) corta la línea y NO la baja a cero, y una
 * escala con negativos deja el 0 en una marca y los extremos dentro.
 */
import { escalaConSigno } from './comun'
import {
  indiceCercano,
  limpio,
  puntosSueltos,
  trazo,
  ultimoConDato,
  xDe,
} from './geometria'

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

const identidad = (v: number) => v

console.log('── limpio ────────────────────────────────────────────────────')
igual(limpio(3), 3, 'un número pasa')
igual(limpio(0), 0, 'el cero es un dato')
igual(limpio(null), null, 'null es hueco')
igual(limpio(undefined), null, 'lo que falta es hueco')
igual(limpio(NaN), null, 'NaN es hueco, no un cero')
igual(limpio(Infinity), null, 'infinito es hueco')

console.log('\n── xDe ───────────────────────────────────────────────────────')
igual(xDe(0, 1), 50, 'un solo punto va en el centro')
igual(xDe(0, 5), 0, 'el primero, en el borde izquierdo')
igual(xDe(4, 5), 100, 'el último, en el borde derecho')
igual(xDe(2, 5), 50, 'el del medio, en el medio')

console.log('\n── trazo ─────────────────────────────────────────────────────')
igual(trazo([0, 50, 100], identidad), 'M0 100 L50 50 L100 0', 'tres puntos, sin huecos')
igual(
  trazo([10, null, 30, 40], identidad),
  'M0 90 M66.667 70 L100 60',
  'un hueco corta: vuelve a empezar con M, no baja a la base',
)
igual(trazo([null, null], identidad), '', 'todo hueco: nada que trazar')
igual(trazo([], identidad), '', 'sin puntos')
igual(trazo([25], identidad), 'M50 75', 'un punto solo')

console.log('\n── puntosSueltos ─────────────────────────────────────────────')
igual(puntosSueltos([1, null, 3, null]), [0, 2], 'los que no tienen vecino con dato')
igual(puntosSueltos([1, 2, null, 4]), [3], 'un tramo de dos no es suelto')
igual(puntosSueltos([5]), [0], 'uno solo es suelto')
igual(puntosSueltos([null, null]), [], 'los huecos no son puntos')

console.log('\n── ultimoConDato ─────────────────────────────────────────────')
igual(ultimoConDato([1, 2, null]), 1, 'se salta el hueco del final')
igual(ultimoConDato([0, null]), 0, 'un cero cuenta como dato')
igual(ultimoConDato([null, null]), -1, 'sin datos, -1')
igual(ultimoConDato([]), -1, 'vacío, -1')

console.log('\n── indiceCercano ─────────────────────────────────────────────')
igual(indiceCercano(0, 5), 0, 'borde izquierdo')
igual(indiceCercano(1, 5), 4, 'borde derecho')
igual(indiceCercano(0.6, 5), 2, 'redondea al más cercano')
igual(indiceCercano(-0.2, 5), 0, 'fuera por la izquierda se queda en el primero')
igual(indiceCercano(1.4, 5), 4, 'fuera por la derecha se queda en el último')
igual(indiceCercano(0.7, 1), 0, 'con un punto, siempre ese')

console.log('\n── escalaConSigno ────────────────────────────────────────────')
{
  const e = escalaConSigno(0, 437.2)
  igual(e.suelo, 0, 'sin negativos, arranca en cero')
  igual(e.marcas, [0, 150, 300, 450], 'y es escalaBonita tal cual')
}
{
  const e = escalaConSigno(-120, 437.2)
  comprueba(e.suelo <= -120, 'el mínimo cabe por encima del suelo', `suelo ${e.suelo}`)
  comprueba(e.tope >= 437.2, 'el máximo cabe bajo el tope', `tope ${e.tope}`)
  comprueba(e.marcas.includes(0), 'el cero cae en una marca', `marcas ${e.marcas.join(' / ')}`)
  const pasos = e.marcas.slice(1).map((m, i) => Number((m - e.marcas[i]).toFixed(6)))
  comprueba(new Set(pasos).size === 1, 'todas las marcas al mismo paso', `pasos ${pasos.join(', ')}`)
}
{
  const e = escalaConSigno(-50, 0)
  igual(e.tope, 0, 'todo negativo: el tope es el cero')
  comprueba(e.suelo <= -50, 'y el suelo baja lo que haga falta', `suelo ${e.suelo}`)
}
{
  const e = escalaConSigno(-3, 7, true)
  comprueba(e.marcas.every((m) => Number.isInteger(m)), 'entera: sin marcas con decimales', `marcas ${e.marcas.join(' / ')}`)
}
igual(escalaConSigno(0, 0).tope, 0, 'todo a cero: escala vacía (el gráfico pone una mínima)')
igual(escalaConSigno(NaN, NaN).marcas, [0], 'basura: escala vacía, sin reventar')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
