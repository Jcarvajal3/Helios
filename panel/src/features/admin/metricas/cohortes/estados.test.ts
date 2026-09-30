/**
 * Pruebas de en qué está una semana y cada cuota.
 *
 *   npx tsx src/features/admin/metricas/cohortes/estados.test.ts
 *
 * Lo que se vigila: la pastilla de la semana mide lo que hay que cobrar de
 * ella (la cuota 1 + la 2, payable) y la de una cuota lo que se cobra en
 * ELLA; lo vencido manda sobre lo demás; una semana cuya cuota 1 no ha
 * vencido no dice «0 % vencido»; un vencido mínimo no se redondea a cero; y
 * los tramos de la semana suman su total a cobrar.
 */
import { GRACIA, HOY, SEMANA_14, SEMANA_21, SEMANA_7, cohorteCruda, cuotaCruda } from './datosDePrueba'
import {
  cuotaDe,
  parteDeEstado,
  pastillaDeCuota,
  pastillaDeSemana,
  pctCorto,
  plazoCerrado,
  queEsCadaEstado,
  tramosDeCobro,
} from './estados'
import { leerCohorte } from './lectura'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const s7 = leerCohorte(SEMANA_7)
const s14 = leerCohorte(SEMANA_14)
const s21 = leerCohorte(SEMANA_21)

console.log('── La pastilla de la semana ───────────────────────────────────')
igual(pastillaDeSemana(s21, HOY), { texto: 'Aún no vence', tono: 'neutral' }, 'la cuota 1 todavía no vence')
// 151,70 vencidos de 1.419,26 a cobrar = 10,7 %: sin decimal por encima del 10.
igual(pastillaDeSemana(s14, HOY), { texto: '11 % vencido', tono: 'warning' }, 'lo vencido, en % de lo que hay que cobrar')
igual(pastillaDeSemana(s7, HOY), { texto: '1,7 % vencido', tono: 'warning' }, 'por debajo del 10 %, con un decimal')
{
  const enCurso = leerCohorte(
    cohorteCruda('2026-09-07', [
      cuotaCruda(1, '2026-09-14', '2026-09-20', { a_tiempo: { payable: 100, financed: 81 } }),
      cuotaCruda(2, '2026-09-21', '2026-09-27', { por_vencer: { payable: 100, financed: 81 } }),
    ]),
  )
  igual(pastillaDeSemana(enCurso, HOY), { texto: 'En curso', tono: 'neutral' }, 'nada vencido y algo por vencer')
  const cobrada = leerCohorte(
    cohorteCruda('2026-08-24', [
      cuotaCruda(1, '2026-08-31', '2026-09-06', { a_tiempo: { payable: 100, financed: 81 } }),
      cuotaCruda(2, '2026-09-07', '2026-09-13', { tarde: { payable: 100, financed: 81 } }),
    ]),
  )
  igual(pastillaDeSemana(cobrada, HOY), { texto: 'Cobrada', tono: 'success' }, 'todo pagado')
  const perdida = leerCohorte(
    cohorteCruda('2026-08-03', [
      cuotaCruda(1, '2026-08-10', '2026-08-16', { a_tiempo: { payable: 100, financed: 81 } }),
      cuotaCruda(2, '2026-08-17', '2026-08-23', {
        a_tiempo: { payable: 90, financed: 72.9 },
        perdida: { payable: 10, financed: 8.1 },
      }),
    ]),
  )
  igual(pastillaDeSemana(perdida, HOY), { texto: '5,0 % perdido', tono: 'error' }, 'algo dado por perdido y nada más vivo')
}

console.log('\n── La pastilla de una cuota ───────────────────────────────────')
igual(pastillaDeCuota(cuotaDe(s14, 1)!, HOY), { texto: '21 % vencido', tono: 'warning' }, 'lo vencido, en % de lo que se cobra en ESA cuota')
igual(pastillaDeCuota(cuotaDe(s14, 2)!, HOY), { texto: 'Aún no vence', tono: 'neutral' }, 'la cuota 2 todavía no vence')
igual(pastillaDeCuota(cuotaDe(s7, 2)!, HOY), { texto: 'En curso', tono: 'neutral' }, 'venciendo, sin nada vencido')
igual(pastillaDeCuota(cuotaDe(s21, 1)!, '2026-09-28'), { texto: 'En curso', tono: 'neutral' }, 'el día que empieza a vencer ya no es «aún no vence»')

console.log('\n── Porcentajes cortos ─────────────────────────────────────────')
igual(pctCorto(14.2), '14 %', 'sin decimal por encima del 10 %')
igual(pctCorto(5.46), '5,5 %', 'con un decimal por debajo')
igual(pctCorto(0.02), 'menos del 0,1 %', 'un vencido mínimo no es un cero')
igual(pctCorto(0), '0,0 %', 'el cero sí es cero')

console.log('\n── Los tramos de las barras ───────────────────────────────────')
igual(
  tramosDeCobro(s14.aCobrar).map((t) => [t.clave, t.valor]),
  [
    ['a_tiempo', 603.48],
    ['tarde', 6.37],
    ['vencida', 151.7],
    ['por_vencer', 657.71],
    ['perdida', 0],
  ],
  'la semana, en lo que hay que cobrar: los cinco estados de las dos cuotas juntas',
)
{
  const t = tramosDeCobro(s14.aCobrar)
  igual(
    Math.round(t.reduce((a, x) => a + x.valor, 0) * 100) / 100,
    s14.aCobrar.importe.payableUsd,
    'los tramos de la semana suman su total a cobrar',
  )
  const cuota = (n: 1 | 2) => cuotaDe(s14, n)?.importe.payableUsd ?? 0
  igual(Math.round((cuota(1) + cuota(2)) * 100) / 100, s14.aCobrar.importe.payableUsd, 'y el total a cobrar es la cuota 1 + la 2')
  igual(t[2]?.desglose, { payableUsd: 151.7, financedUsd: 123.13, feeUsd: 28.57 }, 'cada tramo lleva su desglose para el globo')
  igual(t[2]?.personas, 12, 'y sus pacientes')
}
igual(
  tramosDeCobro(cuotaDe(s14, 1)!).map((t) => t.rotulo),
  ['Cobrado a tiempo', 'Cobrado con atraso', 'Vencido', 'Por vencer', 'Perdido'],
  'los cinco estados de una cuota, en orden',
)
{
  const q = cuotaDe(s14, 1)!
  igual(
    Math.round(tramosDeCobro(q).reduce((a, x) => a + x.valor, 0) * 100) / 100,
    q.importe.payableUsd,
    'los tramos de una cuota suman lo que se cobra en ella',
  )
  igual(Math.round((parteDeEstado(q, 'vencida') ?? 0) * 100) / 100, 21.37, 'la parte de un estado')
}

console.log('\n── Qué es cada estado ─────────────────────────────────────────')
{
  const texto = queEsCadaEstado()
  igual(texto.startsWith('Cobrado a tiempo: pagada'), true, 'empieza por el primer estado')
  igual(/día operativo del reporte/.test(texto), true, 'a tiempo se juzga por el día del reporte')
}

console.log('\n── El plazo de una cuota ──────────────────────────────────────')
igual(plazoCerrado(cuotaDe(s7, 1)!, HOY, GRACIA), true, 'vence hasta el 20, +2 de gracia = 22 < 26')
igual(plazoCerrado(cuotaDe(s14, 1)!, HOY, GRACIA), false, 'vence hasta el 27: todavía no')
igual(plazoCerrado(cuotaDe(s7, 1)!, '2026-09-22', GRACIA), false, 'el último día de la gracia todavía cuenta')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
