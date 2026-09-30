/**
 * Pruebas de los tramos de atraso y de los umbrales de color.
 *
 *   npx tsx src/features/admin/tramos.test.ts
 *
 * Lo que se comprueba aquí es lo que la base da por hecho en
 * `admin_collection_flow`: los mismos cortes, en los mismos días. Si alguien
 * cambia un `<` por un `<=`, una persona salta de tramo sin haber pagado nada
 * y solo se nota comparando el panel con la base.
 */
import type { Parametro, Parametros } from './parametros'
import { cortesDeTramo, rotuloDeTramo, tramoDe, tramoVacio, tramosConRotulo } from './tramos'
import type { CortesDeTramo } from './tramos'
import { tonoCobroATiempo, tonoImpago, tonoMora, tonoPorUmbral } from './umbrales'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function fila(key: string, value: number | null): Parametro {
  return {
    key,
    value,
    effectiveFrom: value === null ? null : '2026-08-01',
    note: null,
    nextValue: null,
    nextFrom: null,
    history: [],
    label: null,
    unit: null,
    grupo: null,
  }
}

function parametros(valores: Record<string, number | null>): Parametros {
  return {
    businessDate: '2026-09-25',
    filas: Object.entries(valores).map(([k, v]) => fila(k, v)),
  }
}

const hoy: CortesDeTramo = { gracia: 3, intervalo: 7, baja: 30, expulsion: 60 }

console.log('── Cada día cae en su tramo (gracia 3, intervalo 7, baja 30, expulsión 60) ──')
const esperado: Array<[number, string]> = [
  [-2, 'al_dia'],
  [0, 'al_dia'],
  [1, 't1'],
  [3, 't1'],
  [4, 't2'],
  [7, 't2'],
  [8, 't3'],
  [29, 't3'],
  [30, 't4'],
  [60, 't4'],
  [61, 't5'],
  [400, 't5'],
]
for (const [dias, tramo] of esperado) {
  const real = tramoDe(dias, hoy)
  comprueba(real === tramo, `${dias} días → ${tramo}`, `salió ${real}`)
}

console.log('\n── Rótulos ─────────────────────────────────────────────────')
const rotulos = tramosConRotulo(hoy).map((t) => t.rotulo)
comprueba(
  rotulos.join(' | ') === '1–3 días | 4–7 días | 8–29 días | 30–60 días | Más de 60 días',
  'los cinco rótulos',
  rotulos.join(' | '),
)
comprueba(rotuloDeTramo('t1', { ...hoy, gracia: 1 }) === '1 día', 'un tramo de un día dice «1 día»')

console.log('\n── Parámetros cruzados ─────────────────────────────────────')
const cruzados: CortesDeTramo = { gracia: 7, intervalo: 7, baja: 30, expulsion: 60 }
comprueba(tramoVacio('t2', cruzados), 'con gracia = intervalo, t2 queda vacío')
comprueba(
  tramosConRotulo(cruzados).every((t) => t.tramo !== 't2'),
  'y no se ofrece como filtro',
)

console.log('\n── Los cortes salen de los parámetros ──────────────────────')
const completos = parametros({
  late_fee_grace_days: 3,
  installment_interval_days: 7,
  mora_demotion_days: 30,
  mora_expulsion_days: 60,
})
const c = cortesDeTramo(completos)
comprueba(c !== null && c.gracia === 3 && c.expulsion === 60, 'con los cuatro, hay cortes')
comprueba(
  cortesDeTramo(parametros({ late_fee_grace_days: 3 })) === null,
  'si falta alguno, no hay cortes (nunca un número inventado)',
)
comprueba(cortesDeTramo(undefined) === null, 'sin parámetros todavía, tampoco')

console.log('\n── Umbrales ────────────────────────────────────────────────')
const umbrales = parametros({
  umbral_mora_alerta_pct: 7,
  umbral_mora_critica_pct: 15,
  umbral_impago_alerta_pct: 4,
  umbral_impago_critico_pct: 8,
  umbral_cobro_a_tiempo_bueno_pct: 90,
  umbral_cobro_a_tiempo_alerta_pct: 80,
})
comprueba(tonoMora(6.9, umbrales) === 'success', 'mora 6,9 % → verde')
comprueba(tonoMora(7, umbrales) === 'warning', 'mora 7 % → ámbar (el corte es >=)')
comprueba(tonoMora(15, umbrales) === 'error', 'mora 15 % → rojo')
comprueba(tonoImpago(8, umbrales) === 'error', 'impago 8 % → rojo')
comprueba(tonoCobroATiempo(92, umbrales) === 'success', 'a tiempo 92 % → verde')
comprueba(tonoCobroATiempo(85, umbrales) === 'warning', 'a tiempo 85 % → ámbar')
comprueba(tonoCobroATiempo(70, umbrales) === 'error', 'a tiempo 70 % → rojo')
comprueba(tonoMora(50, undefined) === 'neutral', 'sin parámetros, neutro')
comprueba(tonoMora(null, umbrales) === 'neutral', 'sin cifra, neutro')
comprueba(
  tonoMora(20, parametros({ umbral_mora_alerta_pct: 7, umbral_mora_critica_pct: null })) ===
    'neutral',
  'un umbral sin valor no inventa color',
)
comprueba(tonoPorUmbral(3, { alerta: 5, critico: 10 }) === 'success', 'por debajo de la alerta → verde')

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
