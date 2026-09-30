/**
 * Pruebas de la geometría nueva de los gráficos: acumulados, escalones,
 * relleno bajo la línea, el anillo y el embudo.
 *
 *   npx tsx src/components/charts/geometria.test.ts
 *
 * Lo que importa: un acumulado no inventa valores en los huecos ni pierde la
 * suma al cruzarlos, y un anillo nunca pinta más de una vuelta ni menos de
 * nada.
 */
import {
  acumular,
  apilar,
  columnaBajo,
  fraccionDelAnillo,
  mayorCaida,
  puntoDelAnillo,
  relleno,
  trazo,
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

console.log('── acumular ──────────────────────────────────────────────────')
{
  const puntos = [
    { key: 'a', label: '1', values: [1, 10] },
    { key: 'b', label: '2', values: [2, 0] },
    { key: 'c', label: '3', values: [3, 5] },
  ]
  const hecho = acumular(puntos)
  igual(hecho.map((p) => p.values), [[1, 10], [3, 10], [6, 15]], 'cada serie suma por su lado')
  igual(hecho.map((p) => p.key), ['a', 'b', 'c'], 'conserva el resto del punto')
  igual(puntos[1].values, [2, 0], 'no toca los puntos que recibe')
}
igual(
  acumular([
    { values: [1] },
    { values: [null] },
    { values: [2] },
  ]).map((p) => p.values[0]),
  [1, null, 3],
  'un hueco sigue siendo hueco y la suma sigue después',
)
igual(
  acumular([{ values: [5] }, { values: [null] }, { values: [null] }]).map((p) => p.values[0]),
  [5, null, null],
  'los días que no han llegado no se rellenan con el total',
)
igual(
  acumular([{ values: [0.1] }, { values: [0.2] }]).map((p) => p.values[0]),
  [0.1, 0.3],
  'sin colas de coma flotante (0,1 + 0,2 = 0,3)',
)
igual(
  acumular([{ values: [NaN] }, { values: [4] }]).map((p) => p.values[0]),
  [null, 4],
  'NaN es hueco y no envenena la suma',
)
igual(acumular([]), [], 'sin puntos, nada')

console.log('\n── trazo en escalón ──────────────────────────────────────────')
igual(
  trazo([0, 50, 100], identidad, true),
  'M0 100 H50 V50 H100 V0',
  'se mantiene hasta el punto siguiente y sube ahí',
)
igual(
  trazo([10, null, 30, 40], identidad, true),
  'M0 90 M66.667 70 H100 V60',
  'el hueco corta también el escalón',
)
igual(
  trazo([0, 0, 0, 30], identidad, true),
  'M0 100 H33.333 H66.667 H100 V70',
  'un tramo plano no lleva subidas de cero',
)
igual(trazo([0, 50], identidad), 'M0 100 L100 50', 'sin escalón, la recta de siempre')

console.log('\n── relleno ───────────────────────────────────────────────────')
igual(
  relleno([0, 50, 100], identidad, 0),
  'M0 100 L0 100 L50 50 L100 0 L100 100 Z',
  'baja a la base por los dos lados y se cierra',
)
igual(
  relleno([20, 40, null, 10, 30], identidad, 0),
  'M0 100 L0 80 L25 60 L25 100 Z M75 100 L75 90 L100 70 L100 100 Z',
  'un polígono por tramo: el hueco corta el relleno',
)
igual(relleno([null, 40, null], identidad, 0), '', 'un punto suelto no tiene área')
igual(
  relleno([0, 50], identidad, 0, true),
  'M0 100 L0 100 H100 V50 L100 100 Z',
  'en escalón, el relleno sigue al escalón',
)
igual(
  relleno([60, 80], identidad, 25),
  'M0 75 L0 40 L100 20 L100 75 Z',
  'con negativos, el relleno llega a la línea del cero y no al fondo',
)

console.log('\n── columnaBajo ───────────────────────────────────────────────')
igual(columnaBajo(0, 4), 0, 'borde izquierdo, la primera')
igual(columnaBajo(0.26, 4), 1, 'cada columna ocupa su cuarto')
igual(columnaBajo(1, 4), 3, 'el borde derecho es de la última')
igual(columnaBajo(-0.5, 4), 0, 'fuera por la izquierda, la primera')

console.log('\n── apilar ────────────────────────────────────────────────────')
igual(
  apilar([50, 25], 100),
  { tramos: [{ serie: 0, base: 0, alto: 50 }, { serie: 1, base: 50, alto: 25 }], cima: 75 },
  'cada tramo empieza donde acaba el de abajo',
)
igual(
  apilar([0, 30], 60),
  { tramos: [{ serie: 1, base: 0, alto: 50 }], cima: 50 },
  'un cero no ocupa tramo y el siguiente arranca en la base',
)
igual(
  apilar([0.5, 50], 100),
  { tramos: [{ serie: 0, base: 0, alto: 1.5 }, { serie: 1, base: 1.5, alto: 50 }], cima: 51.5 },
  'un sumando diminuto mide al menos el suelo',
)
igual(
  apilar([80, 30], 100),
  { tramos: [{ serie: 0, base: 0, alto: 80 }, { serie: 1, base: 80, alto: 20 }], cima: 100 },
  'nada se sale por arriba',
)
igual(apilar([null, NaN, -3], 100), { tramos: [], cima: 0 }, 'sin dato, NaN o negativo: nada que pintar')
igual(apilar([10], 0), { tramos: [], cima: 0 }, 'con tope cero no hay escala')
igual(
  apilar([1, 2], 3).tramos.map((t) => t.alto),
  [33.333, 66.667],
  'sin colas de coma flotante',
)

console.log('\n── el anillo ─────────────────────────────────────────────────')
igual(fraccionDelAnillo(0.72), 0.72, 'una proporción pasa tal cual')
igual(fraccionDelAnillo(0), 0, 'el cero es un dato')
igual(fraccionDelAnillo(1.4), 1, 'nunca más de una vuelta')
igual(fraccionDelAnillo(-0.2), 0, 'nunca menos de nada')
igual(fraccionDelAnillo(null), null, 'sin dato, null')
igual(fraccionDelAnillo(NaN), null, 'NaN es sin dato, no un cero')
igual(puntoDelAnillo(0, 30, 36), { x: 36, y: 6 }, 'empieza a las 12')
igual(puntoDelAnillo(0.25, 30, 36), { x: 66, y: 36 }, 'un cuarto, a las 3')
igual(puntoDelAnillo(0.5, 30, 36), { x: 36, y: 66 }, 'la mitad, a las 6')

console.log('\n── mayorCaida ────────────────────────────────────────────────')
igual(mayorCaida([100, 60, 50, 10]), 1, 'a igual caída (40 y 40), la primera')
igual(mayorCaida([12, 5, 4]), 1, 'contada en pacientes')
igual(mayorCaida([100, 90, 50]), 2, 'en pacientes y no en porcentaje')
igual(mayorCaida([2, 2, 2]), -1, 'si nadie se cae, ninguna')
igual(mayorCaida([3, 5]), -1, 'si el escalón crece, tampoco')
igual(mayorCaida([]), -1, 'sin escalones, ninguna')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
