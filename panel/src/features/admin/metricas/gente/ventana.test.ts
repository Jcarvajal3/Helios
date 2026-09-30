/**
 * Pruebas de la ventana de Métricas › Gente.
 *
 *   npx tsx src/features/admin/metricas/gente/ventana.test.ts
 *
 * Lo que se vigila: que la ventana acabe el domingo de la semana elegida (u
 * hoy, si va a medias), que empiece el lunes de su primera semana, que «desde
 * el inicio» quepa en la serie diaria de la base, y que la frase de la
 * comparación diga «a la misma altura» solo cuando la semana va a medias.
 */
import { diasDelRango } from '@/components/ui'
import { validarGente } from './busqueda'
import {
  SEMANAS_DESDE_EL_INICIO,
  comparacionDeLaVentana,
  rangoDeLaVentana,
  textoDeLaVentana,
  ventanaAMedias,
} from './ventana'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const LUNES_EN_CURSO = '2026-09-21'
const HOY = '2026-09-26'

console.log('── El rango ──────────────────────────────────────────────────')
igual(
  rangoDeLaVentana('semana', LUNES_EN_CURSO, HOY),
  { from: '2026-09-21', to: '2026-09-26' },
  'la semana en curso acaba hoy, no el domingo',
)
igual(
  rangoDeLaVentana('semana', '2026-09-14', HOY),
  { from: '2026-09-14', to: '2026-09-20' },
  'una semana cerrada va de lunes a domingo',
)
igual(
  rangoDeLaVentana('4', '2026-09-14', HOY),
  { from: '2026-08-24', to: '2026-09-20' },
  'cuatro semanas: empieza el lunes de la primera',
)
igual(diasDelRango(rangoDeLaVentana('12', '2026-09-14', HOY)), 84, 'doce semanas cerradas son 84 días')
igual(
  diasDelRango(rangoDeLaVentana('inicio', '2026-09-14', HOY)),
  SEMANAS_DESDE_EL_INICIO * 7,
  'desde el inicio pide un año de semanas',
)
igual(
  diasDelRango(rangoDeLaVentana('inicio', '2026-09-14', HOY)) <= 366,
  true,
  'y cabe en la serie diaria de la base (366 días)',
)

console.log('── A medias ──────────────────────────────────────────────────')
igual(ventanaAMedias(rangoDeLaVentana('semana', LUNES_EN_CURSO, HOY), LUNES_EN_CURSO), true, 'la en curso va a medias')
igual(ventanaAMedias(rangoDeLaVentana('4', '2026-09-14', HOY), '2026-09-14'), false, 'una cerrada no')

console.log('── Las frases ────────────────────────────────────────────────')
igual(
  comparacionDeLaVentana('semana', true),
  'Las flechas comparan con la semana anterior, a la misma altura.',
  'semana a medias',
)
igual(
  comparacionDeLaVentana('4', false),
  'Las flechas comparan con las 4 semanas anteriores.',
  'cuatro semanas cerradas',
)
igual(comparacionDeLaVentana('inicio', false), null, 'desde el inicio no se compara')
igual(
  textoDeLaVentana({ from: '2026-09-21', to: '2026-09-26' }, 6),
  'Del 21 al 26 de septiembre de 2026 · 6 días',
  'la línea de los días, con mayúscula',
)
igual(textoDeLaVentana({ from: '2026-09-26', to: '2026-09-26' }, 1), 'El 26 de septiembre de 2026 · 1 día', 'un solo día')

console.log('── La búsqueda ───────────────────────────────────────────────')
igual(validarGente({ ventana: '4' }).ventana, '4', 'la ventana de la URL')
igual(validarGente({ ventana: 4 }).ventana, '4', 'llega como número y vale')
igual(validarGente({ ventana: '7' }).ventana, undefined, 'una que no existe se cae')
igual(
  validarGente({ sub: 'retencion', cubo: 'mes', cuantos: '12', ver: 'todas', medida: 'gasto', cohorte: '2026-09-01' }),
  {
    ventana: undefined,
    cubo: 'mes',
    cuantos: 12,
    ver: 'todas',
    medida: 'gasto',
    cohorte: '2026-09-01',
  },
  'las claves de la Retención, con los nombres de Crecimiento',
)
igual(validarGente({ cohorte: '2026-02-30' }).cohorte, undefined, 'un día que no existe se cae')

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
