/**
 * Pruebas de la semana de Cobranza y riesgo: el corte, la cartera y sus
 * tramos, lo que vencía cada día y su frase, el cobro a tiempo, la semana
 * juzgada del impago de cada cuota y el paso entre tramos.
 *
 *   npx tsx src/features/admin/metricas/cobranza/semana.test.ts
 *
 * Lo que se vigila: que una semana pasada se mire a su cierre y la en curso
 * ahora; que lo que vencía vaya siempre con su desglose y lo que entró como
 * la parte que es de ello (nunca otro total con el fee dentro); que un
 * tramo que no vino sea un cero; que «sin cuotas que juzgar» no sea un 0 %, y
 * que el paso cuente a cada persona en una sola de las cuatro líneas.
 */
import { leerPrimeraCuota } from '@/features/admin/riesgo/credito'
import { leerFlujo } from '@/features/admin/riesgo/flujo'
import {
  corteDeLaSemana,
  fraseDeLosDias,
  leerCobroATiempo,
  leerDiasDeCobro,
  leerResumenDeCobranza,
  notaDelDia,
  pasoDeLaSemana,
  periodoDelPaso,
  comparaLasCuotas,
  desgloseEnLinea,
  pieDeCobroATiempo,
  pieDelImpago,
  resumenDeLosDias,
  semanaJuzgadaDelImpago,
  textoDelDesglose,
  totalDeLosTramos,
  tramoJuzgado,
} from './semana'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

console.log('── El corte ────────────────────────────────────────────────────')
igual(corteDeLaSemana('2026-09-20', '2026-09-26'), '2026-09-20', 'una semana pasada se mira a su cierre')
igual(corteDeLaSemana('2026-09-27', '2026-09-26'), '2026-09-26', 'la en curso, hoy')

console.log('── La cartera al corte ─────────────────────────────────────────')
{
  const r = leerResumenDeCobranza({
    semana: { desde: '2026-09-21', hasta: '2026-09-27', en_curso: true },
    hoy: '2026-09-26',
    corte: '2026-09-26',
    cartera: {
      vencido: { payable_usd: 180.76, financed_usd: 146.72, fee_usd: 34.04 },
      por_vencer: { payable_usd: 1000, financed_usd: 811.69 },
      perdido: {},
      mora_pct: 15.3,
      cuotas_vencidas: 30,
      personas_vencidas: 25,
    },
    cartera_anterior: { corte: '2026-09-19', vencido: { payable_usd: 100, financed_usd: 81.17 }, mora_pct: null },
    tramos: {
      cortes: { grace_days: 3, interval_days: 7, demotion_days: 30, expulsion_days: 60 },
      filas: [
        { tramo: 't1', personas: 17, cuotas: 20, payable_usd: 128.4, financed_usd: 104.22, fee_usd: 24.18 },
        { tramo: 't3', personas: 8, cuotas: 10, payable_usd: 52.36, financed_usd: 42.5, fee_usd: 9.86 },
      ],
    },
    impago: { impago_pct: 0.81, empate_pct: 16.66, perdido: {} },
    hoy_vencido: { personas: 25, payable_usd: 180.76, financed_usd: 146.72, fee_usd: 34.04 },
  })
  igual(r.semana?.enCurso, true, 'la semana que usó la base')
  igual(r.cartera.vencido, { payableUsd: 180.76, financedUsd: 146.72, feeUsd: 34.04 }, 'lo vencido con su desglose')
  igual(
    r.cartera.porVencer.feeUsd.toFixed(2),
    '188.31',
    'un fee que no viene se deduce de payable − financed',
  )
  igual(r.cartera.perdido, { payableUsd: 0, financedUsd: 0, feeUsd: 0 }, 'lo perdido que no viene es cero')
  igual(r.anterior.moraPct, null, 'una mora sin nada vivo es nula, no 0 %')
  igual(r.tramos.map((t) => t.tramo), ['t1', 't2', 't3', 't4', 't5'], 'siempre los cinco tramos')
  igual(r.tramos[1].personas, 0, 'un tramo que no vino es cero')
  const total = totalDeLosTramos(r.tramos)
  igual(total.personas, 25, 'los pacientes de los tramos son las de la cartera')
  igual(total.vencido.payableUsd.toFixed(2), '180.76', 'y lo vencido también')
  igual(r.cortes?.expulsion, 60, 'los cortes de los tramos')
  igual(r.impago.empatePct, 16.66, 'el punto de empate')
}

console.log('── Lo que vencía cada día ──────────────────────────────────────')
{
  const dia = (d: string, due: number, paid: number, n: number, pagadas: number, futuro = false) => ({
    business_date: d,
    due_usd: due,
    due_financed_usd: +(due / 1.232).toFixed(2),
    due_fee_usd: +(due - due / 1.232).toFixed(2),
    due_count: n,
    due_paid_usd: paid,
    due_paid_financed_usd: +(paid / 1.232).toFixed(2),
    due_paid_fee_usd: +(paid - paid / 1.232).toFixed(2),
    due_paid_count: pagadas,
    collected_usd: 0,
    collected_count: 0,
    is_future: futuro,
  })
  const dias = leerDiasDeCobro([
    dia('2026-09-22', 0, 0, 0, 0),
    dia('2026-09-21', 12.32, 12.32, 1, 1),
    dia('2026-09-23', 24.64, 12.32, 2, 1),
    dia('2026-09-24', 12.32, 0, 1, 0, true),
  ])
  igual(dias.map((d) => d.dia), ['2026-09-21', '2026-09-22', '2026-09-23', '2026-09-24'], 'en orden de día')
  const r = resumenDeLosDias(dias)
  igual(r.vencia.payableUsd.toFixed(2), '36.96', 'lo que vencía, sin los días que no han llegado')
  igual(r.pct?.toFixed(1), '66.7', 'y la parte que entró de eso')
  igual(r.diasPorVenir, 1, 'un día por venir con algo que vence')
  igual(
    fraseDeLosDias(dias, true, '2026-09-23'),
    [
      'Hasta hoy vencían ',
      { cifra: '$36,96 en cuotas' },
      ' (financiado $30,00 + service fee + IVA $6,96) y ',
      'ya se ha cobrado ',
      { cifra: 'el 67 %' },
      '.',
      ' Lo de hoy aún puede pagarse.',
    ],
    'la frase lleva el desglose y lo que entró como parte, sin otro total',
  )
  igual(
    fraseDeLosDias([], false, '2026-09-26'),
    ['Esta semana no vencía ninguna cuota.'],
    'una semana sin cuotas lo dice',
  )
  igual(notaDelDia(dias[1]), 'No vencía nada', 'un día sin nada')
  igual(
    notaDelDia(dias[2]),
    '1 de 2 cuotas pagadas · vencía financiado $20,00 + service fee + IVA $4,64 · cobrado financiado $10,00 + service fee + IVA $2,32',
    'la nota del día con el desglose de lo que vencía y de lo que entró',
  )
  igual(
    notaDelDia(dias[3]),
    '0 de 1 cuota pagada · vencía financiado $10,00 + service fee + IVA $2,32',
    'si no entró nada, solo lo que vencía',
  )
}

console.log('── Cobro a tiempo ──────────────────────────────────────────────')
{
  const c = leerCobroATiempo({
    from: '2026-09-14',
    to: '2026-09-20',
    grace_days: 2,
    total: { due_count: 112, on_time_count: 90, late_count: 12, unpaid_count: 10, rate_pct: 80.4 },
    installments: {
      cuota_2: { sequence: 2, due_count: 51, on_time_count: 45, rate_pct: 88.2 },
      cuota_1: { sequence: 1, due_count: 61, on_time_count: 45, rate_pct: 73.8 },
    },
  })
  igual(c.cuotas.map((q) => q.numero), [1, 2], 'las cuotas en orden')
  igual(pieDeCobroATiempo(c), 'Cuota 1: 74 % · cuota 2: 88 %', 'el pie de la tarjeta')
  igual(tramoJuzgado(c, '2026-09-14', '2026-09-20'), null, 'si es la semana entera no se aclara nada')
  igual(tramoJuzgado(c, '2026-09-21', '2026-09-27'), 'Vencían del 14 sep al 20 sep', 'si no, de qué días es')
  const vacio = leerCobroATiempo({ total: { due_count: 0, rate_pct: null }, installments: {} })
  igual(vacio.total.pct, null, 'sin cuotas que juzgar no hay porcentaje')
  igual(pieDeCobroATiempo(vacio), 'Ninguna cuota ha cerrado su plazo todavía', 'y se dice')
}

console.log('── El impago de cada cuota ─────────────────────────────────────')
{
  const fila = (key: string, maduras: number, enGracia: number, pct: number | null) => ({
    key,
    label: key,
    matured_count: maduras,
    defaulted_count: 0,
    defaulted_pct: pct,
    in_grace_count: enGracia,
  })
  const pc = leerPrimeraCuota(
    {
      rows: [
        fila('2026-09-21', 0, 74, null),
        fila('2026-09-14', 6, 73, 0),
        fila('2026-09-07', 61, 0, 19.7),
        fila('2026-08-31', 51, 0, 7.8),
      ],
    },
    'semana',
  )
  igual(pc.cuota, 1, 'sin la clave cuota, la base juzgó la 1')
  igual(semanaJuzgadaDelImpago(pc, '2026-09-21')?.clave, '2026-09-07', 'la última que ya pasó la gracia entera')
  igual(semanaJuzgadaDelImpago(pc, '2026-09-01')?.clave, '2026-08-31', 'nunca una posterior a la elegida')
  igual(semanaJuzgadaDelImpago(pc, '2026-08-01'), null, 'sin ninguna, nula')
  igual(
    pieDelImpago(semanaJuzgadaDelImpago(pc, '2026-09-21'), '2026-09-21'),
    '0 de 61 cuotas · financiamientos del 7 sep al 13 sep, la última semana con la gracia terminada',
    'el pie dice de qué semana es',
  )
  igual(
    pieDelImpago(semanaJuzgadaDelImpago(pc, '2026-09-07'), '2026-09-07'),
    '0 de 61 cuotas · financiamientos del 7 sep al 13 sep',
    'si es la elegida, sin más',
  )

  // La cuota 2 vence una semana después: su semana juzgada es más vieja.
  const pc2 = leerPrimeraCuota(
    {
      cuota: 2,
      rows: [
        fila('2026-09-21', 0, 74, null),
        fila('2026-09-14', 0, 79, null),
        fila('2026-09-07', 8, 53, 25),
        fila('2026-08-31', 51, 0, 7.8),
      ],
    },
    'semana',
  )
  igual(pc2.cuota, 2, 'la cuota que dice la base')
  igual(semanaJuzgadaDelImpago(pc2, '2026-09-21')?.clave, '2026-08-31', 'la cuota 2 se juzga en una semana más vieja')
  igual(
    comparaLasCuotas([
      { cuota: 1, fila: semanaJuzgadaDelImpago(pc, '2026-09-21') },
      { cuota: 2, fila: semanaJuzgadaDelImpago(pc2, '2026-09-21') },
    ]),
    'Cuota 1: 20 % · cuota 2: 8 %',
    'las dos cuotas en una línea',
  )
  igual(
    comparaLasCuotas([
      { cuota: 1, fila: null },
      { cuota: 2, fila: null },
    ]),
    'Cuota 1: sin juzgar · cuota 2: sin juzgar',
    'sin semana juzgada no es un 0 %',
  )
}

console.log('── El desglose ─────────────────────────────────────────────────')
igual(
  textoDelDesglose({ financedUsd: 146.72, feeUsd: 34.04 }),
  'Financiado $146,72 (sin fee) · service fee + IVA $34,04',
  'el fee se llama «service fee» en el desglose',
)
igual(desgloseEnLinea({ financedUsd: 10, feeUsd: 2.32 }), 'financiado $10,00 + service fee + IVA $2,32', 'dentro de una frase, en minúscula')

console.log('── El paso entre tramos ────────────────────────────────────────')
{
  const flujo = leerFlujo({
    tramos: { grace_days: 3, interval_days: 7, demotion_days: 30, expulsion_days: 60 },
    weeks: [
      {
        cut_date: '2026-09-26',
        from_date: '2026-09-21',
        en_curso: true,
        people_total: 20,
        people: {},
        transitions: [
          { from: 'nuevo', to: 'al_dia', people: 5 },
          { from: 'nuevo', to: 't1', people: 1 },
          { from: 'al_dia', to: 'al_dia', people: 6 },
          { from: 'al_dia', to: 't1', people: 3 },
          { from: 't1', to: 'al_dia', people: 2 },
          { from: 't1', to: 't2', people: 1 },
          { from: 't3', to: 't1', people: 1 },
          { from: 't3', to: 't3', people: 1 },
        ],
      },
    ],
  })
  const semana = flujo.semanas[0]
  igual(
    pasoDeLaSemana(semana),
    { seAlDia: 2, mejoraron: 1, empeoraron: 1, entraron: 4, siguen: 1 },
    'cada paciente en una sola línea; los nuevos que entran vencidos cuentan como entrados',
  )
  igual(periodoDelPaso(semana), 'Del lunes 21 a hoy', 'la semana en curso va hasta hoy')
  igual(
    periodoDelPaso({ ...semana, enCurso: false, desde: '2026-09-14', corte: '2026-09-21' }),
    'Del lunes 14 al lunes 21',
    'una pasada, de lunes a lunes',
  )
}

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
