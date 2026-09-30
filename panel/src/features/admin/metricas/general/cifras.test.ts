/**
 * Pruebas de lo que la pestaña General escribe con sus cifras.
 *
 *   npx tsx src/features/admin/metricas/general/cifras.test.ts
 *
 * Lo que se vigila: que la frase no sume el service fee al consumo, que un
 * denominador que falta dé un guion y no un 0 %, que las pastillas solo
 * salgan al cruzar un umbral, que «por cada $100» cierre con su margen y que
 * la curva no pinte como cero lo que no se parte por local.
 */
import type { Parametros } from '@/features/admin/parametros'
import {
  contar,
  cuotaATiempo,
  diaYMes,
  fraseGeneral,
  lineasPorCadaCien,
  notaDeMadurez,
  pctOGuion,
  pieCargos,
  pieCuotaATiempo,
  pieDeCuotas,
  pieDeQuienesConsumieron,
  pieHanComprado,
  pieImpago,
  pieLocalesActivos,
  pieMora,
  piePerdido,
  piePorPagar,
  puntosDeConsumo,
  puntosDeRegistros,
  resumenDeConsumo,
  resumenDeRegistros,
  resumenPorCadaCien,
  rotuloDeSemana,
  senalCuotaATiempo,
  senalImpago,
  senalMora,
} from './cifras'
import { leerGeneral } from './lectura'
import { respuestaDeMuestra, respuestaDeUnLocal } from './muestra'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

/** La frase, escrita de corrido, con las cifras entre asteriscos. */
function leer(partes: ReturnType<typeof fraseGeneral>): string {
  return partes.map((p) => (typeof p === 'string' ? p : `*${p.cifra}*`)).join('')
}

/** Unos parámetros con los umbrales del panel. */
function parametros(valores: Record<string, number>): Parametros {
  return {
    businessDate: '2026-09-26',
    filas: Object.entries(valores).map(([key, value]) => ({ key, value }) as unknown as Parametros['filas'][number]),
  }
}

const UMBRALES = parametros({
  umbral_mora_alerta_pct: 7,
  umbral_mora_critica_pct: 15,
  umbral_impago_alerta_pct: 3,
  umbral_impago_critico_pct: 6,
  umbral_cobro_a_tiempo_bueno_pct: 90,
  umbral_cobro_a_tiempo_alerta_pct: 80,
})

const todos = leerGeneral(respuestaDeMuestra())
const local = leerGeneral(respuestaDeUnLocal())

console.log('── Escribir ──────────────────────────────────────────────────')
igual(contar(1, 'paciente', 'pacientes'), '1 paciente', 'uno en singular')
igual(contar(1940, 'paciente', 'pacientes'), '1.940 pacientes', 'miles con punto')
igual(pctOGuion(null), '—', 'sin dato, un guion')
igual(pctOGuion(20.38), '20,4 %', 'un porcentaje con coma')
igual(diaYMes('2026-08-28', '2026-09-26'), '28 de agosto', 'el año de hoy no se escribe')
igual(diaYMes('2025-12-30', '2026-09-26'), '30 de diciembre de 2025', 'otro año, sí')

console.log('\n── La frase ──────────────────────────────────────────────────')
igual(
  leer(fraseGeneral(todos, null)),
  'Las cifras desde el inicio cuentan desde el *7 de septiembre*.',
  'todas las clínicas: solo desde cuándo, lo demás está en las tarjetas',
)
igual(
  leer(fraseGeneral(local, 'La Quinta Bar')),
  'En La Quinta Bar, las cifras desde el inicio cuentan desde el *7 de septiembre*, su primer financiamiento.',
  'con clínica: desde su primer financiamiento',
)
igual(
  leer(fraseGeneral({ ...local, desde: null }, null)),
  'Esta clínica todavía no tiene financiamientos.',
  'una clínica sin financiamientos, y sin su nombre todavía',
)
igual(leer(fraseGeneral({ ...todos, desde: null }, null)), 'Todavía no hay registros ni financiamientos.', 'nada de nada')

console.log('\n── Los pies ──────────────────────────────────────────────────')
igual(pieHanComprado(todos), '134 de 194 registros', 'han comprado: de cuántos registros')
igual(pieHanComprado(local), undefined, 'con clínica no hay pie de registros')
igual(pieDeQuienesConsumieron(124, todos), '92,5 % de los pacientes', 'activos sobre quienes se han financiado')
igual(pieDeQuienesConsumieron(101, local), '75,4 % de los pacientes de la clínica', 'con clínica, «de la clínica»')
igual(
  pieDeQuienesConsumieron(3, { ...todos, consumo: { ...todos.consumo, personas: 0 } }),
  undefined,
  'sin nadie que haya financiado, sin pie',
)
igual(pieLocalesActivos(todos), '3 han financiado alguna vez', 'clínicas activas')
igual(pieDeCuotas(180, 90), '180 cuotas de 90 pacientes', 'cuotas y pacientes')
igual(pieDeCuotas(0, 0), 'Ninguna cuota', 'sin cuotas')
igual(pieCargos(todos), 'De ello, cobrado $148,00', 'los cargos: lo cobrado, aparte')
igual(pieCargos({ ...todos, dinero: { ...todos.dinero, cargos: { devengadoUsd: 0, cobradoUsd: 0, cargos: 0 } } }), 'Ninguno todavía', 'sin cargos')
igual(piePerdido(todos), 'De 2 pacientes', 'lo perdido: de cuántos pacientes')
igual(piePorPagar(todos), 'De ello, atrasado $379,00', 'lo atrasado con las clínicas')
igual(
  piePorPagar({ ...todos, dinero: { ...todos.dinero, porPagarLocales: { totalUsd: 10, atrasadoUsd: 0, locales: 1 } } }),
  'Nada atrasado',
  'nada atrasado',
)
igual(pieMora(todos), '26 pacientes con deuda vencida', 'la mora: cuánta gente')
igual(pieMora({ ...todos, riesgo: { ...todos.riesgo, moraPct: null } }), 'Nada por cobrar', 'sin nada vivo')
igual(pieImpago(todos), 'Helios pierde desde el 16,7 %', 'el impago frente al empate')
igual(pieCuotaATiempo(cuotaATiempo(todos, 1)), '272 de 356 con plazo cerrado', 'la cuota 1: sobre cuántas')
igual(pieCuotaATiempo({ cuota: 2, juzgadas: 0, aTiempo: 0, pct: null }), 'Ninguna ha cerrado su plazo', 'sin plazos cerrados')
igual(pieCuotaATiempo(cuotaATiempo(todos, 3)), 'Ninguna ha cerrado su plazo', 'una cuota que no viene')

console.log('\n── Las pastillas ─────────────────────────────────────────────')
igual(senalMora(todos, UMBRALES), { tone: 'error', texto: 'Crítico · desde 15 %' }, 'la mora cruza el crítico')
igual(senalMora({ ...todos, riesgo: { ...todos.riesgo, moraPct: 3 } }, UMBRALES), undefined, 'por debajo de la alerta, nada')
igual(senalMora(todos, undefined), undefined, 'sin parámetros, nada: un color inventado es peor')
igual(senalImpago(todos, UMBRALES), undefined, 'el impago bajo sus umbrales y bajo el empate')
igual(
  senalImpago({ ...todos, riesgo: { ...todos.riesgo, impagoPct: 17 } }, UMBRALES),
  { tone: 'error', texto: 'Crítico · empate 16,7 %' },
  'el impago que pasa el empate es crítico',
)
igual(senalCuotaATiempo(cuotaATiempo(todos, 1), UMBRALES), { tone: 'error', texto: 'Bajo · meta 90 %' }, 'la cuota 1 por debajo de la alerta')
igual(senalCuotaATiempo({ cuota: 1, juzgadas: 0, aTiempo: 0, pct: null }, UMBRALES), undefined, 'sin juzgadas, sin pastilla')

console.log('\n── Por cada $100 ─────────────────────────────────────────────')
{
  const lineas = lineasPorCadaCien(todos.porCadaCien)
  igual(
    lineas?.map((l) => [l.rotulo, l.valor, l.total === true]),
    [
      ['Service fee sin IVA', '+$19,99', false],
      ['Cargos por atraso', '+$3,45', false],
      ['Margen, menos el impago', '$22,63', true],
    ],
    'suma lo que entra y cierra con el margen, que ya resta el impago',
  )
  igual(lineasPorCadaCien({ ...todos.porCadaCien, por100: null }), null, 'sin financiamiento, nada que repartir')
  igual(resumenPorCadaCien(todos.porCadaCien), '318 financiamientos con $7.373,00 financiados (sin fee)', 'de dónde salen los cien')
  igual(resumenPorCadaCien({ ...todos.porCadaCien, consumos: 0 }), 'Todavía no hay financiamientos.', 'sin financiamientos')
  igual(
    notaDeMadurez(todos.porCadaCien),
    'El 32,6 % de lo financiado ya cerró su ciclo de cobro; lo perdido del resto todavía puede crecer.',
    'qué parte ya es definitiva',
  )
  igual(
    notaDeMadurez({ ...todos.porCadaCien, financedMaduroUsd: 0 }),
    'Nada de lo financiado ha cerrado todavía su ciclo de cobro: lo perdido todavía puede crecer.',
    'nada maduro',
  )
  igual(
    notaDeMadurez({ ...todos.porCadaCien, financedMaduroUsd: 7373 }),
    'Todo lo financiado ya cerró su ciclo de cobro: lo perdido es definitivo.',
    'todo maduro',
  )
  igual(notaDeMadurez({ ...todos.porCadaCien, financedUsd: 0 }), null, 'sin financiamiento, sin nota')
}

console.log('\n── La curva ──────────────────────────────────────────────────')
{
  const reg = puntosDeRegistros(todos.curva, todos.hoy)
  igual(reg?.map((p) => [p.label, p.values[0], p.note]), [
    ['7 sep', 150, '150 registros esa semana'],
    ['14 sep', 150, '0 registros esa semana'],
    ['Esta semana', 194, '44 registros esa semana'],
  ], 'registros acumulados; una semana sin registros es un cero, no un hueco')
  igual(puntosDeRegistros(local.curva, local.hoy), null, 'con clínica no hay curva de registros')
  igual(puntosDeRegistros([], todos.hoy), null, 'sin semanas, sin curva')
  igual(
    puntosDeConsumo(todos.curva, todos.hoy).map((p) => [p.label, p.values[0], p.note]),
    [
      ['7 sep', 4500, '$4.500,00 esa semana'],
      ['14 sep', 4500, '$0,00 esa semana'],
      ['Esta semana', 7373, '$2.873,00 esa semana'],
    ],
    'financiamiento acumulado, sin fee',
  )
  igual(rotuloDeSemana({ semana: '2026-09-21', registros: 0, registrosAcum: 0, consumos: 0, financedUsd: 0, financedAcumUsd: 0 }, '2026-09-27'), 'Esta semana', 'el domingo sigue en la semana de su lunes')
  igual(resumenDeRegistros(todos), '194 registros en 3 semanas', 'el resumen de los registros')
  igual(resumenDeRegistros(local), undefined, 'con clínica, sin resumen de registros')
  igual(resumenDeConsumo(todos), '$7.373,00 en 3 semanas, sin el service fee', 'el resumen del financiamiento')
}

if (fallos > 0) {
  console.log(`\n${fallos} ${fallos === 1 ? 'falla' : 'fallan'}`)
  process.exit(1)
}
console.log('\nTodo bien')
