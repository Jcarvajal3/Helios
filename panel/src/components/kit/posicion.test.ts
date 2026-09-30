/**
 * Pruebas de dónde se pinta lo que flota.
 *
 *   npx tsx src/components/kit/posicion.test.ts
 *
 * Lo que se vigila: que la capa se quede en su lado si cabe, que se dé la
 * vuelta solo cuando en su lado no cabe y en el otro sí, que se desplace lo
 * justo para no salirse por los lados, y que una capa más grande que la
 * ventana empiece por arriba a la izquierda.
 */
import { calcularPosicion } from './posicion'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const vista = { ancho: 1440, alto: 900 }
const capa = { ancho: 320, alto: 160 }
const ancla = (top: number, left: number) => ({ top, left, width: 20, height: 20 })

function caso(
  titulo: string,
  entrada: Parameters<typeof calcularPosicion>[0],
  espera: { top?: number; left?: number; lado?: 'arriba' | 'abajo' },
) {
  const sale = calcularPosicion(entrada)
  const ok =
    (espera.top === undefined || sale.top === espera.top) &&
    (espera.left === undefined || sale.left === espera.left) &&
    (espera.lado === undefined || sale.lado === espera.lado)
  comprueba(ok, titulo, JSON.stringify(sale))
}

const base = { capa, vista, separacion: 8 }

console.log('── El lado ───────────────────────────────────────────────────')
caso('abajo, si cabe', { ...base, ancla: ancla(100, 500), lado: 'abajo', alineacion: 'inicio' }, {
  top: 128,
  lado: 'abajo',
})
caso(
  'abajo sin sitio, se da la vuelta',
  { ...base, ancla: ancla(800, 500), lado: 'abajo', alineacion: 'inicio' },
  { top: 632, lado: 'arriba' },
)
caso('arriba, si cabe', { ...base, ancla: ancla(400, 500), lado: 'arriba', alineacion: 'inicio' }, {
  top: 232,
  lado: 'arriba',
})
caso(
  'arriba sin sitio, se da la vuelta',
  { ...base, ancla: ancla(40, 500), lado: 'arriba', alineacion: 'inicio' },
  { top: 68, lado: 'abajo' },
)
caso(
  'sin sitio en ningún lado, se queda en el suyo y se pega al borde',
  { ...base, capa: { ancho: 320, alto: 880 }, ancla: ancla(450, 500), lado: 'abajo', alineacion: 'inicio' },
  { top: 12, lado: 'abajo' },
)

console.log('── La alineación y los bordes ────────────────────────────────')
caso('inicio: alineada con el disparador', { ...base, ancla: ancla(100, 500), lado: 'abajo', alineacion: 'inicio' }, {
  left: 500,
})
caso('fin: acaba donde acaba el disparador', { ...base, ancla: ancla(100, 500), lado: 'abajo', alineacion: 'fin' }, {
  left: 200,
})
caso('centro: centrada sobre el disparador', { ...base, ancla: ancla(100, 500), lado: 'abajo', alineacion: 'centro' }, {
  left: 350,
})
caso(
  'pegada al borde derecho, se desplaza hacia dentro',
  { ...base, ancla: ancla(100, 1400), lado: 'abajo', alineacion: 'inicio' },
  { left: 1112 },
)
caso(
  'pegada al borde izquierdo, se desplaza hacia dentro',
  { ...base, ancla: ancla(100, 0), lado: 'abajo', alineacion: 'centro' },
  { left: 8 },
)
caso(
  'más ancha que la ventana, empieza por la izquierda',
  { ...base, capa: { ancho: 2000, alto: 160 }, ancla: ancla(100, 500), lado: 'abajo', alineacion: 'inicio' },
  { left: 8 },
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
