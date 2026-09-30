/**
 * Pruebas de Por cobrar: la lectura de `admin_receivables_by_day` y lo que se
 * calcula con ella.
 *
 *   npx tsx src/features/admin/porCobrar.test.ts
 *
 * Lo que se vigila: que se lean todas las cifras con su clase, que el día
 * vencido llegue marcado, que los locales de un día salgan de sus filas y no
 * de la semana, que un día de otra semana no filtre nada y que el cotejo con
 * el libro diga la diferencia sin enseñar un total con la comisión dentro.
 */
import {
  cifrasDe,
  diaDentro,
  fraseDelCotejo,
  hayCargos,
  leerPorCobrar,
  localesDe,
  rotuloDelDia,
} from './porCobrar'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const BAR = '11111111-1111-1111-1111-111111111111'

/** Un día vacío, como los manda la base. */
function vacio(dia: string) {
  return {
    dia, cuotas: 0, personas: 0, locales: 0, consumo_usd: 0, comision_usd: 0, cargos_usd: 0,
    total_usd: 0, cuotas_sin_pagar: 0, vencido: false,
  }
}

console.log('── Una semana con un día vencido (dev, semana del 7 de septiembre) ──')
{
  // Tal como la devolvió la base en el ensayo: una cuota del 11 sin pagar,
  // con su cargo por atraso, y otra del mismo día ya pagada.
  const d = leerPorCobrar({
    desde: '2026-09-07', hasta: '2026-09-13', hoy: '2026-09-25', dia_operativo: '2026-09-25',
    incluye_pagadas: false,
    periodo: { cuotas: 1, personas: 1, locales: 1, consumo_usd: 1.87, comision_usd: 0.52, cargos_usd: 2, total_usd: 4.39 },
    pagado: { cuotas: 1, personas: 1, consumo_usd: 1.88, comision_usd: 0.52, cargos_usd: 2, total_usd: 4.4 },
    vencido_antes: { hasta: '2026-09-06', cuotas: 0, personas: 0, consumo_usd: 0, comision_usd: 0, cargos_usd: 0, total_usd: 0 },
    por_dia: [
      vacio('2026-09-07'), vacio('2026-09-08'), vacio('2026-09-09'), vacio('2026-09-10'),
      {
        dia: '2026-09-11', cuotas: 1, personas: 1, locales: 1, consumo_usd: 1.87, comision_usd: 0.52,
        cargos_usd: 2, total_usd: 4.39, cuotas_sin_pagar: 1, vencido: true,
      },
      vacio('2026-09-12'), vacio('2026-09-13'),
    ],
    por_local: [
      { local_id: BAR, local: 'Bar Nocturno', cuotas: 1, personas: 1, consumo_usd: 1.87, comision_usd: 0.52, cargos_usd: 2, total_usd: 4.39 },
    ],
    por_dia_y_local: [
      { dia: '2026-09-11', local_id: BAR, local: 'Bar Nocturno', cuotas: 1, personas: 1, consumo_usd: 1.87, comision_usd: 0.52, cargos_usd: 2, total_usd: 4.39 },
    ],
    cotejo: { pendiente_usd: 32.65, cargos_sin_cuota_usd: 0, libro_usd: 32.65 },
  })

  comprueba(d.desde === '2026-09-07' && d.hasta === '2026-09-13' && !d.incluyePagadas, 'lee el periodo y el modo')
  comprueba(
    d.periodo.consumoUsd === 1.87 && d.periodo.comisionUsd === 0.52 && d.periodo.cargosUsd === 2 && d.periodo.totalUsd === 4.39,
    'lee los tres sumandos y su total',
    JSON.stringify(d.periodo),
  )
  // En céntimos: 1,87 + 0,52 + 2 en coma flotante es 4,390000000000001.
  const centimos = (n: number) => Math.round(n * 100)
  comprueba(
    centimos(d.periodo.consumoUsd) + centimos(d.periodo.comisionUsd) + centimos(d.periodo.cargosUsd) ===
      centimos(d.periodo.totalUsd),
    'el desglose cierra con su total',
  )
  comprueba(d.pagado.totalUsd === 4.4 && d.vencidoAntes.hasta === '2026-09-06', 'lee lo pagado y lo vencido de antes')
  comprueba(d.porDia.length === 7, 'siete días, los vacíos incluidos', String(d.porDia.length))
  const once = d.porDia[4]
  comprueba(once.vencido && once.cuotasSinPagar === 1, 'el día con algo sin pagar llega vencido')
  comprueba(d.porDia.filter((x) => x.vencido).length === 1, 'y solo ese')
  comprueba(hayCargos(d), 'con cargos por atraso, van como tercer sumando')

  const semana = localesDe(d, null)
  comprueba(semana.length === 1 && semana[0].localId === BAR, 'las clínicas de la semana')
  comprueba(localesDe(d, '2026-09-11')[0]?.totalUsd === 4.39, 'los de un día salen de sus filas')
  comprueba(localesDe(d, '2026-09-10').length === 0, 'un día sin nada no tiene clínicas')
  comprueba(cifrasDe(d, '2026-09-11').cargosUsd === 2 && cifrasDe(d, null) === d.periodo, 'las cifras del día y las de la semana')
  comprueba(cifrasDe(d, '2026-10-01').totalUsd === 0, 'un día que no está no inventa cifras')
}

console.log('\n── Lo que falta o viene mal ─────────────────────────────────')
{
  const d = leerPorCobrar(null)
  comprueba(d.porDia.length === 0 && d.porLocal.length === 0, 'una respuesta vacía no rompe: listas vacías')
  comprueba(d.periodo.totalUsd === 0 && !d.incluyePagadas, 'y cifras a cero, no NaN')
  comprueba(!hayCargos(d), 'sin cargos')

  // PostgREST manda los numeric grandes como texto.
  const t = leerPorCobrar({ periodo: { consumo_usd: '10.5', comision_usd: '2.44', total_usd: '12.94' } })
  comprueba(t.periodo.consumoUsd === 10.5 && t.periodo.totalUsd === 12.94, 'un número en texto se lee')

  const sinNombre = leerPorCobrar({ por_local: [{ local_id: BAR, total_usd: 1 }] })
  comprueba(sinNombre.porLocal[0]?.local === 'Clínica sin nombre', 'una clínica sin nombre se dice')
}

console.log('\n── El orden de las clínicas ──────────────────────────────────')
{
  const fila = (local: string, total: number) => ({
    local_id: local, local, cuotas: 1, personas: 1, consumo_usd: total, comision_usd: 0, cargos_usd: 0, total_usd: total,
  })
  const d = leerPorCobrar({
    por_local: [fila('Bravo', 5), fila('Alfa', 5), fila('Charlie', 9)],
    por_dia_y_local: [
      { ...fila('Bravo', 1), dia: '2026-09-25' },
      { ...fila('Charlie', 3), dia: '2026-09-25' },
      { ...fila('Alfa', 7), dia: '2026-09-26' },
    ],
  })
  comprueba(
    localesDe(d, null).map((l) => l.local).join(',') === 'Charlie,Alfa,Bravo',
    'de mayor a menor total, y a igual total por nombre',
    localesDe(d, null).map((l) => l.local).join(','),
  )
  comprueba(
    localesDe(d, '2026-09-25').map((l) => l.local).join(',') === 'Charlie,Bravo',
    'los de un día, solo los de ese día y en su orden',
  )
}

console.log('\n── La semana y el día ───────────────────────────────────────')
comprueba(rotuloDelDia('2026-09-21', 0) === 'L 21', 'el lunes es «L 21»', rotuloDelDia('2026-09-21', 0))
comprueba(rotuloDelDia('2026-09-21', 2) === 'X 23', 'el miércoles es la X', rotuloDelDia('2026-09-21', 2))
comprueba(rotuloDelDia('2026-09-28', 3) === 'J 1', 'el jueves que cambia de mes es «J 1»', rotuloDelDia('2026-09-28', 3))
comprueba(diaDentro('2026-09-24', '2026-09-21', '2026-09-27') === '2026-09-24', 'un día de la semana vale')
comprueba(diaDentro('2026-09-28', '2026-09-21', '2026-09-27') === null, 'uno de otra semana no filtra nada')
comprueba(diaDentro(undefined, '2026-09-21', '2026-09-27') === null, 'sin día, la semana entera')

console.log('\n── El cotejo con el libro ───────────────────────────────────')
{
  const cuadra = fraseDelCotejo({ pendienteUsd: 32.65, cargosSinCuotaUsd: 0, libroUsd: 32.65 })
  comprueba(cuadra.includes('cuadra con') && !cuadra.includes('no cuadra'), 'cuando cuadra, lo dice', cuadra)
  comprueba(!cuadra.includes('$'), 'y no enseña ninguna de las dos cifras: llevan la comisión dentro', cuadra)

  const cargos = fraseDelCotejo({ pendienteUsd: 30, cargosSinCuotaUsd: 2, libroUsd: 32 })
  comprueba(cargos.includes('no cuadra') && cargos.includes('$2,00 más'), 'dice cuánto más lleva el libro', cargos)
  comprueba(cargos.includes('cargos por atraso anteriores al reparto por cuota'), 'y que son cargos sin cuota', cargos)
  comprueba(!cargos.includes('$30') && !cargos.includes('$32'), 'sin las cifras enteras', cargos)

  const ajuste = fraseDelCotejo({ pendienteUsd: 30, cargosSinCuotaUsd: 2, libroUsd: 33 })
  comprueba(ajuste.includes('$1,00 son asientos del libro'), 'lo que no explican los cargos es del libro', ajuste)

  const falta = fraseDelCotejo({ pendienteUsd: 30, cargosSinCuotaUsd: 0, libroUsd: 29 })
  comprueba(falta.includes('$1,00 menos') && falta.includes('Al libro le faltan $1,00'), 'y al revés, lo que le falta al libro', falta)

  const ruido = fraseDelCotejo({ pendienteUsd: 30, cargosSinCuotaUsd: 0, libroUsd: 30.004 })
  comprueba(ruido.includes('cuadra con') && !ruido.includes('no cuadra'), 'menos de medio céntimo no es una diferencia', ruido)
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
