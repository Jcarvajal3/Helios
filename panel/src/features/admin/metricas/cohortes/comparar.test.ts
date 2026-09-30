/**
 * Pruebas de «Comparar todas»: el gráfico de lo que hay que cobrar y el CSV.
 *
 *   npx tsx src/features/admin/metricas/cohortes/comparar.test.ts
 *
 * Lo que se vigila: que las columnas del gráfico vayan de la más vieja a la
 * más nueva (las doce más recientes) y sumen su total a cobrar; que el CSV
 * lleve cada importe con sus dos partes (consumo sin fee y service fee),
 * nunca un total sin sus sumandos; que no diga «servicio»; y que un dato que
 * no hay salga en blanco.
 */
import { construirCsv } from '@/lib/csv'
import { SEMANA_14, SEMANA_21, SEMANA_7, cohorteCruda, cuotaCruda } from './datosDePrueba'
import { columnasCsvDeCohortes, columnasDelCobro, nombreDelCsv } from './comparar'
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

console.log('── El gráfico de lo que hay que cobrar ────────────────────────')
{
  const columnas = columnasDelCobro([s21, s7, s14])
  igual(columnas.map((c) => c.semana), ['2026-09-07', '2026-09-14', '2026-09-21'], 'de la más vieja a la más nueva')
  const c14 = columnas[1]
  igual(c14.rotulo, '14–20 sep', 'el rótulo del eje')
  igual(c14.titulo, 'del 14 al 20 de septiembre', 'el título del globo')
  igual(c14.valores, [603.48, 6.37, 151.7, 657.71, 0], 'cada estado, en lo que se cobra')
  igual(
    Math.round(c14.valores.reduce((a, v) => a + v, 0) * 100) / 100,
    c14.total.payableUsd,
    'los estados suman el total a cobrar',
  )
  igual(c14.total, { payableUsd: 1419.26, financedUsd: 1152, feeUsd: 267.26 }, 'el total, con su desglose')
  const muchas = Array.from({ length: 15 }, (_, i) => {
    const lunes = new Date(Date.UTC(2026, 5, 1 + 7 * i)).toISOString().slice(0, 10)
    return leerCohorte(
      cohorteCruda(lunes, [cuotaCruda(1, '2026-06-08', '2026-06-14', { a_tiempo: { payable: 10, financed: 8 } })]),
    )
  })
  igual(columnasDelCobro(muchas).length, 12, 'como mucho doce semanas')
  igual(columnasDelCobro(muchas).at(-1)?.semana, muchas.at(-1)?.semana, 'las doce más recientes')
}

console.log('\n── El CSV ─────────────────────────────────────────────────────')
{
  const columnas = columnasCsvDeCohortes()
  const cabeceras = columnas.map((c) => c.header)
  igual(cabeceras.length, 30 + 24 * 2, 'la semana, lo que hay que cobrar y un bloque por cuota')
  igual(
    cabeceras.filter((h) => h.startsWith('Total a cobrar')),
    ['Total a cobrar ($)', 'Total a cobrar: financiado, sin fee ($)', 'Total a cobrar: service fee + IVA ($)'],
    'el total a cobrar, con su desglose',
  )
  // Todo importe (una cabecera en $ que no es ya una parte) trae sus dos partes.
  const sinPartes = cabeceras
    .filter((h) => h.endsWith(' ($)') && !h.includes(':'))
    .filter((h) => {
      const base = h.slice(0, -' ($)'.length)
      return !cabeceras.includes(`${base}: financiado, sin fee ($)`) || !cabeceras.includes(`${base}: service fee + IVA ($)`)
    })
  igual(sinPartes, [], 'ningún importe sin su financiamiento y su service fee')
  igual(cabeceras.filter((h) => /servicio/i.test(h)), [], 'ninguna cabecera dice «servicio»')

  const csv = construirCsv(columnas, [s14])
  const [cabecera = '', fila = ''] = csv.replace(/^\uFEFF/, '').split('\r\n')
  const valores = Object.fromEntries(cabecera.split(';').map((h, i) => [h, fila.split(';')[i]]))
  igual(valores['Total a cobrar ($)'], '1419,26', 'lo que hay que cobrar, con coma decimal')
  igual(valores['Total a cobrar: financiado, sin fee ($)'], '1152,00', 'su financiamiento, sin fee')
  igual(valores['Total a cobrar: service fee + IVA ($)'], '267,26', 'su service fee')
  igual(valores['Cobrado ($)'], '609,85', 'lo cobrado de las dos cuotas')
  igual(valores['Cobrado (%)'], '42,97', 'qué parte del total se cobró')
  igual(valores['Vencido: service fee + IVA ($)'], '28,57', 'el service fee de lo vencido')
  igual(valores['Cuota 1 · total de la cuota ($)'], '709,75', 'lo que se cobra en la cuota 1')
  igual(valores['Cuota 1 · vencido: service fee + IVA ($)'], '28,57', 'y el service fee de lo vencido en ella')
  igual(valores['Cuota 2 · cobrado (%)'], '27,97', 'un porcentaje, con coma')
  const sinCuota2 = leerCohorte(cohorteCruda('2026-09-07', [SEMANA_7.cuotas[0]]))
  const filaSin = construirCsv(columnas, [sinCuota2]).split('\r\n')[1] ?? ''
  const celdas = filaSin.split(';')
  igual(celdas[cabeceras.indexOf('Cuota 2 · total de la cuota ($)')], '', 'sin cuota 2, la celda en blanco y no a cero')
  igual(s21.aCobrar.importe.payableUsd > 0, true, 'y una semana en curso también tiene su total a cobrar')
}

console.log('\n── El nombre del archivo ──────────────────────────────────────')
igual(nombreDelCsv('2026-09-26', null), 'cohortes-de-financiamiento-2026-09-26', 'todas las clínicas')
igual(nombreDelCsv('2026-09-26', 'La Quinta Bar'), 'cohortes-de-financiamiento-la-quinta-bar-2026-09-26', 'una clínica, sin espacios')
igual(nombreDelCsv('2026-09-26', 'Café Ñandú'), 'cohortes-de-financiamiento-cafe-nandu-2026-09-26', 'sin tildes')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
