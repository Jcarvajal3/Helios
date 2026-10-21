/**
 * Pruebas de la lectura y las frases de Métricas › Caja.
 *
 *   npx tsx src/features/admin/metricas/caja/calculos.test.ts
 *
 * Lo que se vigila: que lo que entró de cuotas se lea y se diga SIEMPRE con
 * su consumo y su Comisión Helios (regla de la comisión); que con un local la caja
 * sea `null` y la frase hable de lo que se le debe; que lo que se esperaba
 * cobrar se reparta como lo que vencía; y que el aviso del libro solo salga
 * cuando no cuadra.
 */
import {
  descuadreDelLibro,
  etiquetaConDesglose,
  etiquetaDeSemana,
  fraseDeLaSemana,
  notaDeLoCobrado,
  repartirComoVencia,
} from './calculos'
import { leerCaja, leerFoto, leerProyeccion } from './lectura'
import { textoDeDesglose } from '@/features/admin/metricas/formato'

let fallos = 0

/** Las dos partes de lo cobrado tal como van en la frase y en el globo: «consumo $X + Comisión Helios $Y». */
function dosPartes(financedUsd: number, feeUsd: number): string {
  return textoDeDesglose({ financedUsd, feeUsd }).replace('Financiamiento', 'financiamiento')
}

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

/** La frase pegada, con las cifras entre asteriscos. */
function pegar(partes: ReturnType<typeof fraseDeLaSemana>): string {
  return partes.map((p) => (typeof p === 'string' ? p : `*${p.cifra}*`)).join('')
}

const LOCAL = '179b20df-8f9c-1a61-4927-f53fd545b218'

const MOV = {
  cobrado: { payable_usd: 903.24, financed_usd: 733.01, fee_usd: 170.23, cuotas: 102, personas: 54 },
  servicio_cobrado_usd: 146.22,
  cargos_cobrados: { usd: 16, n: 8 },
  transferido: { usd: 470.1, n: 2 },
  consumo: { financed_usd: 1129, consumos: 43 },
  servicio_ganado_usd: 225.8,
  cargos_devengados_usd: 28,
  libro: { cobrado_usd: 919.24, transferido_usd: 470.1, otros_usd: 0 },
}

const TODOS = leerCaja({
  hoy: '2026-09-26',
  semana: { desde: '2026-09-21', hasta: '2026-09-27', en_curso: true },
  dias: 6,
  anterior: { desde: '2026-09-14', hasta: '2026-09-19' },
  merchant_id: null,
  movimientos: MOV,
  movimientos_anterior: MOV,
  caja: { al_inicio_usd: 1733.9, al_cierre_usd: 2183.04, al_cierre_anterior_usd: 1674.46 },
  por_pagar_locales: { total_usd: 3118.664, atrasado_usd: 379, este_cierre_usd: 1413.66, fecha_cierre: '2026-09-28', locales_atrasados: 2 },
  semanas: [
    {
      lunes: '2026-08-31',
      domingo: '2026-09-06',
      en_curso: false,
      cobrado: { payable_usd: 100, financed_usd: 81.17, fee_usd: 18.83 },
      caja_al_cierre_usd: 900,
      vencia: { payable_usd: 123.2, financed_usd: 100, fee_usd: 23.2 },
    },
  ],
})

console.log('── La lectura ────────────────────────────────────────────────')
igual(
  TODOS.movimientos.cobrado,
  { payableUsd: 903.24, financedUsd: 733.01, feeUsd: 170.23, cuotas: 102, personas: 54 },
  'lo cobrado, con sus dos partes',
)
igual(TODOS.caja?.alCierreUsd ?? null, 2183.04, 'la caja del libro')
igual(TODOS.semanas[0]?.vencia.financedUsd ?? null, 100, 'lo que vencía, partido')
igual(TODOS.anterior, { desde: '2026-09-14', hasta: '2026-09-19' }, 'la anterior a la misma altura')

const CON_LOCAL = leerCaja({
  semana: { desde: '2026-09-14', hasta: '2026-09-20', en_curso: false },
  merchant_id: LOCAL,
  movimientos: { ...MOV, libro: null, transferido: { usd: 0, n: 0 } },
  caja: null,
  por_pagar_locales: { total_usd: 1268.25, ultimo_pago_dia: '2026-09-21', ultimo_pago_usd: 324 },
})
igual(CON_LOCAL.caja, null, 'con clínica no hay caja: null, no cero')
igual(CON_LOCAL.movimientos.libro, null, 'ni libro')
igual(CON_LOCAL.porPagarLocales.ultimoPagoUsd, 324, 'el último pago a la clínica')

console.log('── La frase ──────────────────────────────────────────────────')
igual(
  pegar(fraseDeLaSemana(TODOS, null)),
  `En lo que va de semana entraron *$903,24 de cuotas* (${dosPartes(733.01, 170.23)}) y salieron *$470,10* a las clínicas; la caja va por *$2.183,04*.`,
  'semana en curso, sin clínica: el desglose va siempre',
)
igual(
  pegar(fraseDeLaSemana({ ...TODOS, semana: { desde: '2026-09-14', hasta: '2026-09-20', enCurso: false } }, null)),
  `La semana del 14 al 20 de septiembre de 2026 entraron *$903,24 de cuotas* (${dosPartes(733.01, 170.23)}) y salieron *$470,10* a las clínicas; la caja cerró en *$2.183,04*.`,
  'semana cerrada: la caja cerró',
)
igual(
  pegar(fraseDeLaSemana(CON_LOCAL, 'La Quinta Bar')),
  `Esa semana, de los financiamientos de La Quinta Bar entraron *$903,24 de cuotas* (${dosPartes(733.01, 170.23)}) y no se le transfirió nada; hoy se le deben *$1.268,25*.`,
  'con clínica: lo que se le debe, no la caja',
)

console.log('── Las semanas ───────────────────────────────────────────────')
igual(etiquetaDeSemana({ lunes: '2026-09-14', domingo: '2026-09-20' }), '14–20 sep', 'una semana dentro del mes')
igual(etiquetaDeSemana({ lunes: '2026-08-31', domingo: '2026-09-06' }), '31 ago–6 sep', 'una que cruza de mes')
igual(
  etiquetaConDesglose({ lunes: '2026-09-14', domingo: '2026-09-20', cobrado: { payableUsd: 891.98, financedUsd: 723.97, feeUsd: 168.01 } }),
  `14–20 sep (${dosPartes(723.97, 168.01)})`,
  'el globo de lo cobrado lleva sus dos partes',
)

console.log('── El globo de lo cobrado ────────────────────────────────────')
{
  const cobrado = { payableUsd: 891.98, financedUsd: 723.97, feeUsd: 168.01 }
  igual(
    notaDeLoCobrado({ cobrado, cargosCobradosUsd: 12 }, false),
    `Cobrado: ${dosPartes(723.97, 168.01)} · cargos por atraso $12,00`,
    'lo cobrado con sus dos partes y los cargos aparte',
  )
  igual(
    notaDeLoCobrado({ cobrado, cargosCobradosUsd: 0 }, true),
    `En curso · Cobrado: ${dosPartes(723.97, 168.01)}`,
    'la semana en curso lo dice delante',
  )
  igual(notaDeLoCobrado(undefined, true), 'En curso', 'sin las partes todavía, solo que va a medias')
  igual(notaDeLoCobrado(undefined, false), undefined, 'y en una semana cerrada, nada')
  igual(
    notaDeLoCobrado({ cobrado: { payableUsd: 0, financedUsd: 0, feeUsd: 0 }, cargosCobradosUsd: 0 }, false),
    undefined,
    'una semana sin cobros no lleva unas partes en cero',
  )
}

console.log('── Lo que se esperaba cobrar ─────────────────────────────────')
igual(
  repartirComoVencia(61.6, { payableUsd: 123.2, financedUsd: 100, feeUsd: 23.2 }),
  { payableUsd: 61.6, financedUsd: 50, feeUsd: 11.6 },
  'la mitad de lo que vencía: la mitad de cada parte',
)
igual(repartirComoVencia(10, { payableUsd: 0, financedUsd: 0, feeUsd: 0 }), null, 'sin nada que venciera no se inventa')

console.log('── El libro ──────────────────────────────────────────────────')
igual(descuadreDelLibro(TODOS.movimientos), null, 'cuotas + cargos = libro: cuadra')
igual(
  descuadreDelLibro({ ...TODOS.movimientos, libro: { cobradoUsd: 929.24, transferidoUsd: 470.1, otrosUsd: 0 } }),
  { cobradoUsd: 10, transferidoUsd: 0 },
  'diez dólares de más en el libro',
)
igual(descuadreDelLibro(CON_LOCAL.movimientos), null, 'con clínica no hay libro que cotejar')

console.log('── La foto y la proyección ───────────────────────────────────')
const foto = leerFoto({
  cash: null,
  merchant_id: LOCAL,
  receivable: { payable_usd: 1366.13, financed_usd: 1108.92, fee_usd: 257.21, late_fees_usd: 50 },
  overdue: { payable_usd: 290.12, financed_usd: 235.5, fee_usd: 54.62 },
  lost: { payable_usd: 0, financed_usd: 0, fee_usd: 0, late_fees_usd: 0 },
  merchant_payable: 1268.25,
  service: { earned_usd: 690.7, collected_usd: 460.41, late_fees_earned_usd: 116, late_fees_collected_usd: 54 },
})
igual(foto.cajaUsd, null, 'con clínica, sin caja')
igual(foto.porCobrar, { payableUsd: 1366.13, financedUsd: 1108.92, feeUsd: 257.21, cargosUsd: 50 }, 'lo que se debe, partido')
const proy = leerProyeccion({
  cash_now_usd: 2183.04,
  on_time_factor: 0.747,
  rows: [
    {
      week_start: '2026-09-21',
      week_end: '2026-09-27',
      expected_gross_usd: 129.74,
      expected_gross_financed_usd: 105.31,
      expected_gross_fee_usd: 24.43,
      expected_in_usd: 96.92,
      expected_in_financed_usd: 78.67,
      expected_in_fee_usd: 18.25,
      expected_out_usd: 0,
      net_usd: 96.92,
    },
  ],
})
igual(proy.filas[0]?.vence ?? null, { payableUsd: 129.74, financedUsd: 105.31, feeUsd: 24.43 }, 'lo que vence, con su desglose')
igual(proy.filas[0]?.seEspera.financedUsd ?? null, 78.67, 'y lo que se espera cobrar')

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
