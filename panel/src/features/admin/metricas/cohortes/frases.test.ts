/**
 * Pruebas de las frases con cifras de Cohortes.
 *
 *   npx tsx src/features/admin/metricas/cohortes/frases.test.ts
 *
 * Lo que se vigila: que las frases hablen en lo que hay que COBRAR (la cuota
 * 1 + la 2, con el service fee dentro), que todo importe que se cobra lleve
 * su desglose al lado (consumo sin fee + service fee) y que ninguna diga
 * «servicio». Y que cada frase cambie con los datos (nada cobrado, una cuota
 * que no vence, una curva sin días cerrados, nada vencido).
 */
import { formatUsd } from '@/components/ui'
import { HOY, SEMANA_14, SEMANA_21, SEMANA_7, DETALLE_CRUDO, cohorteCruda, cuotaCruda } from './datosDePrueba'
import {
  comoSeLee,
  fraseDeLaCurva,
  fraseDeLaSemana,
  fraseDelGrafico,
  importeConDesglose,
  semanaDeEjemplo,
  textoPlano,
} from './frases'
import { cuotaDe } from './estados'
import { leerCohorte, leerDetalleDeCohorte } from './lectura'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

function cierto(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const s7 = leerCohorte(SEMANA_7)
const s14 = leerCohorte(SEMANA_14)
const s21 = leerCohorte(SEMANA_21)

/** Todo importe de la frase va seguido de su desglose entre paréntesis. */
function importesConDesglose(f: string): boolean {
  const importes = f.match(/€[\d.]+,\d\d(?! \+ service fee)(?!\))/g) ?? []
  return importes.every((imp) => f.includes(`${imp} (financiado $`))
}

console.log('── La frase de la semana ──────────────────────────────────────')
{
  const f = textoPlano(fraseDeLaSemana(s14, HOY))
  igual(
    f,
    'Ya se cobró el 43 % de lo que hay que cobrar de esta semana. De la cuota 1 se cobró el 58 % y 12 pacientes la tienen vencida. La cuota 2 vence del 28 sep al 4 oct.',
    'semana con la cuota 1 venciendo y la 2 por vencer',
  )
  cierto(!f.includes('$'), 'en %: los importes, con su desglose, están en las cifras de encima', f)
}
igual(
  textoPlano(fraseDeLaSemana(s21, HOY)),
  'Ya se cobró el 5,8 % de lo que hay que cobrar de esta semana. La cuota 1 vence del 28 sep al 3 oct. La cuota 2 vence del 5 al 10 oct.',
  'semana en curso: ninguna cuota vence todavía, pero alguien ya pagó',
)
igual(
  textoPlano(fraseDeLaSemana(s7, HOY)),
  'Ya se cobró el 84 % de lo que hay que cobrar de esta semana. De la cuota 1 se cobró el 97 % y 1 paciente la tiene vencida. De la cuota 2 se cobró el 71 % y el resto todavía no vence.',
  'semana madura, en singular',
)
{
  const nada = leerCohorte(
    cohorteCruda('2026-09-21', [
      cuotaCruda(1, '2026-09-28', '2026-10-04', { por_vencer: { payable: 100, financed: 81 } }),
      cuotaCruda(2, '2026-10-05', '2026-10-11', { por_vencer: { payable: 100, financed: 81 } }),
    ]),
  )
  igual(
    textoPlano(fraseDeLaSemana(nada, HOY)),
    'Todavía no se ha cobrado nada de lo que hay que cobrar de esta semana. La cuota 1 vence del 28 sep al 4 oct. La cuota 2 vence del 5 al 11 oct.',
    'nada cobrado todavía',
  )
}
igual(
  fraseDeLaSemana(s14, HOY).filter((t) => typeof t !== 'string'),
  [{ cifra: '43 %' }, { cifra: '58 %' }, { cifra: '12 pacientes' }],
  'las cifras destacadas',
)

console.log('\n── Un importe que se cobra, siempre con su desglose ───────────')
igual(
  textoPlano(importeConDesglose({ payableUsd: 45.2, financedUsd: 36.7, feeUsd: 8.5 })),
  '$45,20 (financiado $36,70 + service fee + IVA $8,50)',
  'lo que se cobra y de qué está hecho',
)

console.log('\n── La curva ───────────────────────────────────────────────────')
{
  const d = leerDetalleDeCohorte(DETALLE_CRUDO)
  const [c1, c2] = d.curvas
  igual(
    fraseDeLaCurva(c1, cuotaDe(s14, 1)),
    'A 2 días de vencer, esta semana llevaba cobrado el 18 % de la cuota 1; las 4 semanas anteriores llevaban de media el 38 %.',
    'sin el día del vencimiento cerrado, el último día cerrado',
  )
  const conVence = {
    ...c1,
    puntos: c1.puntos.map((p) => (p.dia === 0 ? { ...p, estaPct: 70.2, mediaPct: 71.48, semanasEnMedia: 4 } : p)),
  }
  igual(
    fraseDeLaCurva(conVence, cuotaDe(s14, 1)),
    'El día que venció, esta semana llevaba cobrado el 70 % de la cuota 1; las 4 semanas anteriores llevaban de media el 71 %.',
    'con el día del vencimiento cerrado, ese día',
  )
  igual(
    fraseDeLaCurva(c2, cuotaDe(s14, 2)),
    'La cuota 2 de esta semana vence del 28 sep al 4 oct. La curva empieza cuando hayan cerrado sus días.',
    'sin días cerrados: cuándo empieza',
  )
  const sinMedia = { ...c1, puntos: c1.puntos.map((p) => ({ ...p, mediaPct: null, semanasEnMedia: 0 })) }
  igual(
    fraseDeLaCurva(sinMedia, cuotaDe(s14, 1)),
    'A 2 días de vencer, esta semana llevaba cobrado el 18 % de la cuota 1.',
    'sin semanas anteriores, sin media',
  )
}

console.log('\n── Comparar todas ─────────────────────────────────────────────')
{
  const todas = [s21, s14, s7]
  const g = textoPlano(fraseDelGrafico(todas))
  igual(
    g,
    'La semana con más vencido es la del 14 al 20 de septiembre: $151,70 (financiado $123,13 + service fee + IVA $28,57), el 11 % de lo que hay que cobrar de ella.',
    'el gráfico: la semana con más vencido, con su desglose',
  )
  cierto(importesConDesglose(g), 'todo importe del gráfico lleva su desglose', g)
  igual(
    textoPlano(fraseDelGrafico([s21])),
    'Ninguna de estas semanas tiene nada vencido: lo que falta por cobrar todavía no vence.',
    'nada vencido',
  )
  igual(textoPlano(fraseDelGrafico([])), 'Todavía no hay ninguna semana con algo que cobrar.', 'ninguna semana')

  igual(semanaDeEjemplo(todas, '2026-09-14', HOY)?.semana, '2026-09-14', 'la semana elegida, si ya empezó a vencer')
  igual(semanaDeEjemplo(todas, '2026-09-21', HOY)?.semana, '2026-09-14', 'si la elegida no vence aún, la más reciente que sí')
  igual(semanaDeEjemplo([s21], '2026-09-21', HOY), null, 'ninguna: sin ejemplo')

  const lee = textoPlano(comoSeLee(s7, HOY))
  igual(
    lee,
    'cada fila es el total a cobrar de los financiamientos de una semana: la cuota 1 más la cuota 2, cada una con su service fee + IVA. En la del 7 al 13 de septiembre hay que cobrar $704,60 (financiado $572,00 + service fee + IVA $132,60) y ya se cobró el 84 % (el 97 % de la cuota 1 y el 71 % de la cuota 2).',
    'cómo se lee, con los números de una semana',
  )
  cierto(lee.includes(`${formatUsd(s7.aCobrar.importe.payableUsd)} (financiado`), 'el total a cobrar, con su desglose', lee)
  igual(
    textoPlano(comoSeLee(s14, HOY)),
    'cada fila es el total a cobrar de los financiamientos de una semana: la cuota 1 más la cuota 2, cada una con su service fee + IVA. En la del 14 al 20 de septiembre hay que cobrar $1.419,26 (financiado $1.152,00 + service fee + IVA $267,26) y ya se cobró el 43 % (el 58 % de la cuota 1 y el 28 % de la cuota 2).',
    'la cuota 2 sin vencer, pero con pagos adelantados',
  )
  const soloVence = leerCohorte(
    cohorteCruda('2026-09-14', [
      cuotaCruda(1, '2026-09-21', '2026-09-27', { a_tiempo: { payable: 100, financed: 81 } }),
      cuotaCruda(2, '2026-09-28', '2026-10-04', { por_vencer: { payable: 100, financed: 81 } }),
    ]),
  )
  igual(
    textoPlano(comoSeLee(soloVence, HOY)),
    'cada fila es el total a cobrar de los financiamientos de una semana: la cuota 1 más la cuota 2, cada una con su service fee + IVA. En la del 14 al 20 de septiembre hay que cobrar $200,00 (financiado $162,00 + service fee + IVA $38,00) y ya se cobró el 50 % (el 100 % de la cuota 1 y la cuota 2 vence del 28 sep al 4 oct).',
    'la cuota 2 sin vencer ni pagos: cuándo vence',
  )
  igual(
    textoPlano(comoSeLee(null, HOY)),
    'cada fila es el total a cobrar de los financiamientos de una semana: la cuota 1 más la cuota 2, cada una con su service fee + IVA.',
    'sin semana de ejemplo, solo la regla',
  )
}

console.log('\n── Ninguna frase dice «servicio» ──────────────────────────────')
{
  const d = leerDetalleDeCohorte(DETALLE_CRUDO)
  const todas = [
    ...[s7, s14, s21].map((c) => textoPlano(fraseDeLaSemana(c, HOY))),
    ...[s7, s14, s21].map((c) => textoPlano(comoSeLee(c, HOY))),
    textoPlano(fraseDelGrafico([s7, s14, s21])),
    ...d.curvas.map((c) => fraseDeLaCurva(c, cuotaDe(s14, c.numero))),
  ]
  cierto(todas.every((f) => !/servicio/i.test(f)), 'ni «servicio» ni «servicio e IVA»', todas.find((f) => /servicio/i.test(f)))
}

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
