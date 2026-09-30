/**
 * Pruebas de la geometría de la curva de cobro.
 *
 *   npx tsx src/features/admin/metricas/cohortes/curva.test.ts
 *
 * Lo que se vigila: que el día en que vence caiga donde toca en el eje, que
 * un día sin cerrar corte la línea (no la baje a cero), que la cifra escrita
 * sea la del último día con dato, y que nada se salga del lienzo.
 */
import { DETALLE_CRUDO } from './datosDePrueba'
import { curvaVacia, marcasDeDias, tramoDe, trazoDeCurva, ultimoDe, xDeDia, yDePct } from './curva'
import { leerDetalleDeCohorte } from './lectura'
import type { CurvaDeCuota } from './tipos'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const [c1, c2] = leerDetalleDeCohorte(DETALLE_CRUDO).curvas

console.log('── Los ejes ───────────────────────────────────────────────────')
const t = tramoDe(c1)
igual(t, { desde: -6, hasta: 14 }, 'de seis días antes a catorce después')
igual(xDeDia(-6, t), 0, 'el primer día, a la izquierda')
igual(xDeDia(0, t), 30, 'el día en que vence, al 30 % del ancho')
igual(xDeDia(14, t), 100, 'el último, a la derecha')
igual(marcasDeDias(t), [-6, 0, 7, 14], 'las marcas: el primero, vence, una semana y el último')
igual(tramoDe({ numero: 1, semanasMedia: [], puntos: [] }), { desde: -6, hasta: 14 }, 'una curva vacía, el tramo de siempre')
igual([yDePct(-3), yDePct(50), yDePct(104)], [0, 50, 100], 'el porcentaje no se sale del lienzo')

console.log('\n── Las líneas ─────────────────────────────────────────────────')
igual(
  trazoDeCurva(c1, 'esta'),
  'M0 99.04 L5 93.19 L10 88.06 L15 84.08 L20 82.39',
  'esta semana: solo los días cerrados',
)
{
  const conHueco: CurvaDeCuota = {
    ...c1,
    puntos: c1.puntos.map((p) => (p.dia === -4 ? { ...p, estaPct: null } : p)),
  }
  igual(
    trazoDeCurva(conHueco, 'esta'),
    'M0 99.04 L5 93.19 M15 84.08 L20 82.39',
    'un día sin dato corta la línea en vez de bajarla a cero',
  )
}
igual(ultimoDe(c1, 'esta'), { dia: -2, pct: 17.61 }, 'la cifra de esta semana: su último día cerrado')
igual(ultimoDe(c1, 'media'), { dia: 5, pct: 85.46 }, 'la de la media: su último día')
igual(ultimoDe(c2, 'esta'), null, 'sin días cerrados, sin cifra')
igual(curvaVacia(c2), false, 'con media, la curva no está vacía')
igual(
  curvaVacia({ ...c2, puntos: c2.puntos.map((p) => ({ ...p, mediaPct: null })) }),
  true,
  'sin nada que dibujar, vacía',
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
