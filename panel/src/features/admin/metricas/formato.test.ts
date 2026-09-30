/**
 * Pruebas de cómo se escriben las cifras de Métricas.
 *
 *   npx tsx src/features/admin/metricas/formato.test.ts
 *
 * Lo que se vigila: que el cambio diga su sentido con palabras y en corto,
 * que una tasa cambie en puntos y no en porcentaje, que el color salga de si
 * subir es bueno (y pueda ser neutro), que un cero no invente un porcentaje,
 * y que el desglose de una cuota diga siempre sus dos partes.
 */
import { comoTendencia, delta, porcentaje, textoDeDesglose, textoDeDesgloseCorto } from './formato'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const MENOS = '−'

console.log('── Relativo ──────────────────────────────────────────────────')
igual(
  delta(912.4, 815, { tipo: 'relativo', arribaEsBueno: true }),
  { direccion: 'sube', texto: '12 % más', corto: '▲ 12 %', tono: 'bueno' },
  'sube un 12 %, y subir es bueno',
)
igual(
  delta(700, 815, { tipo: 'relativo', arribaEsBueno: true }),
  { direccion: 'baja', texto: '14 % menos', corto: '▼ 14 %', tono: 'malo' },
  'baja, y bajar es malo',
)
igual(
  delta(180, 118, { tipo: 'relativo', arribaEsBueno: false }),
  { direccion: 'sube', texto: '53 % más', corto: '▲ 53 %', tono: 'malo' },
  'lo vencido sube: malo',
)
igual(delta(1000, 100, { tipo: 'relativo', arribaEsBueno: null })?.tono, 'neutro', 'ni bueno ni malo: neutro')
igual(
  delta(100.5, 100, { tipo: 'relativo', arribaEsBueno: true }),
  { direccion: 'igual', texto: 'igual', corto: '=', tono: 'neutro' },
  'por debajo del uno por ciento es «igual»',
)
igual(
  delta(5, 0, { tipo: 'relativo', arribaEsBueno: true }),
  { direccion: 'nuevo', texto: 'nuevo', corto: 'nuevo', tono: 'neutro' },
  'de cero a algo es «nuevo», sin porcentaje',
)
igual(delta(0, 0, { tipo: 'relativo', arribaEsBueno: true }), null, 'de cero a cero no hay nada que contar')
igual(delta(10, -20, { tipo: 'relativo', arribaEsBueno: true })?.texto, '150 % más', 'sobre un negativo, contra su valor absoluto')
igual(delta(1234, 1, { tipo: 'relativo', arribaEsBueno: true })?.texto, '123.300 % más', 'con el punto de millar de aquí')

console.log('\n── En puntos ─────────────────────────────────────────────────')
igual(
  delta(81.2, 84.5, { tipo: 'puntos', arribaEsBueno: true }),
  { direccion: 'baja', texto: '3,3 puntos menos', corto: '▼ 3,3 pts', tono: 'malo' },
  'el cobro a tiempo baja 3,3 puntos',
)
igual(
  delta(10, 7.5, { tipo: 'puntos', arribaEsBueno: false }),
  { direccion: 'sube', texto: '2,5 puntos más', corto: '▲ 2,5 pts', tono: 'malo' },
  'la mora sube: malo',
)
igual(delta(6, 5, { tipo: 'puntos', arribaEsBueno: false })?.texto, '1,0 punto más', 'un punto, en singular')
igual(delta(6.02, 6, { tipo: 'puntos', arribaEsBueno: false })?.direccion, 'igual', 'menos de una décima es «igual»')
igual(delta(4, 0, { tipo: 'puntos', arribaEsBueno: false })?.texto, '4,0 puntos más', 'en puntos, desde cero sí hay cambio')

console.log('\n── Sin dato ──────────────────────────────────────────────────')
igual(delta(null, 5, { tipo: 'relativo', arribaEsBueno: true }), null, 'sin la actual no hay cambio')
igual(delta(5, null, { tipo: 'puntos', arribaEsBueno: true }), null, 'sin la anterior tampoco')
igual(delta(Number.NaN, 5, { tipo: 'relativo', arribaEsBueno: true }), null, 'un NaN no es una cifra')

console.log('\n── Como pastilla de Stat ─────────────────────────────────────')
{
  const sube = delta(912.4, 815, { tipo: 'relativo', arribaEsBueno: true })
  const moraSube = delta(10, 7.5, { tipo: 'puntos', arribaEsBueno: false })
  const moraBaja = delta(5, 7.5, { tipo: 'puntos', arribaEsBueno: false })
  const neutra = delta(1000, 100, { tipo: 'relativo', arribaEsBueno: null })
  const plana = delta(100.5, 100, { tipo: 'relativo', arribaEsBueno: true })
  igual(sube && comoTendencia(sube), { label: '12 % más', direction: 'up', upIsGood: true }, 'sube y es bueno: verde')
  igual(moraSube && comoTendencia(moraSube), { label: '2,5 puntos más', direction: 'up', upIsGood: false }, 'la mora sube: rojo')
  igual(moraBaja && comoTendencia(moraBaja), { label: '2,5 puntos menos', direction: 'down', upIsGood: false }, 'la mora baja: verde')
  igual(neutra && comoTendencia(neutra), { label: '900 % más', direction: 'up', upIsGood: null }, 'neutra: flecha gris')
  igual(plana && comoTendencia(plana), { label: 'igual', direction: 'flat', upIsGood: null }, 'igual: plana')
}

console.log('\n── Porcentaje y desglose ─────────────────────────────────────')
igual(porcentaje(1, 4), 25, 'una parte de un todo')
igual(porcentaje(3, 0), null, 'sin total no hay porcentaje')
igual(porcentaje(0, 10), 0, 'un cero sobre algo sí es un dato')
igual(
  textoDeDesglose({ financedUsd: 146.72, feeUsd: 34.04 }),
  'Financiamiento $146,72 + service fee $34,04',
  'la cuota dice sus dos partes',
)
igual(
  textoDeDesglose({ financedUsd: -16.7, feeUsd: 0 }),
  `Financiamiento ${MENOS}$16,70 + service fee $0,00`,
  'con el signo menos de verdad delante del dólar',
)
igual(
  textoDeDesgloseCorto({ financedUsd: 146.72, feeUsd: 34.04 }),
  'financiamiento $146,72 · fee $34,04',
  'en corto, «fee» y nunca «servicio»',
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
