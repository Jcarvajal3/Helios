/**
 * Pruebas de la lectura de `admin_metricas_general`.
 *
 *   npx tsx src/features/admin/metricas/general/lectura.test.ts
 *
 * Lo que se vigila: que cada clave llegue a su sitio, que lo que no se parte
 * por local se quede en `null` (nunca en cero), y que un importe que se paga
 * sin sus dos partes haga fallar la lectura en vez de pintarse suelto.
 */
import { RespuestaGeneralRota, leerGeneral } from './lectura'
import { respuestaDeMuestra, respuestaDeUnLocal } from './muestra'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

function lanza(fn: () => unknown, titulo: string) {
  let lanzo = false
  try {
    fn()
  } catch (e) {
    lanzo = e instanceof RespuestaGeneralRota
  }
  if (!lanzo) fallos++
  console.log(`${lanzo ? '  ok  ' : ' FALLA'}  ${titulo}`)
}

console.log('── Todas las clínicas ─────────────────────────────────────────')
{
  const g = leerGeneral(respuestaDeMuestra())
  igual(g.hoy, '2026-09-26', 'el hoy de la base')
  igual(g.desde, '2026-09-07', 'desde el primer día')
  igual(g.local, null, 'sin clínica')
  igual(
    g.gente,
    {
      registros: 194,
      verificados: 194,
      hanComprado: 134,
      hanCompradoPct: 69.1,
      activos: 124,
      repiten: 101,
      solicitaron: 236,
      telefonoConfirmado: 226,
    },
    'la gente: registros verificados y, aparte, quien pidió el código',
  )
  igual(g.consumo.financedUsd, 7373, 'el financiamiento, sin comisión')
  igual(g.consumo.ticketUsd, 23.19, 'el ticket medio')
  igual(
    g.dinero.porCobrar,
    { payableUsd: 2589.93, financedUsd: 2102.14, feeUsd: 487.79, cuotas: 180, personas: 90 },
    'lo por cobrar, con su desglose',
  )
  igual(g.dinero.vencido.personas, 26, 'los pacientes con algo vencido')
  igual(g.dinero.cobrado, { payableUsd: 6421.01, financedUsd: 5211.69, feeUsd: 1209.32, cuotas: 460 }, 'lo cobrado, con su desglose')
  igual(
    g.dinero.movido,
    { payableUsd: 9083.84, financedUsd: 7373, feeUsd: 1710.84, cuotas: 642, consumos: 318 },
    'todo lo movido, con su desglose',
  )
  const m = g.dinero.movido
  const suma = g.dinero.cobrado.payableUsd + g.dinero.porCobrar.payableUsd + g.dinero.perdido.payableUsd
  igual(m !== null && Math.abs(m.payableUsd - suma) < 0.005, true, 'lo movido es lo cobrado + lo por cobrar + lo perdido')
  igual(m?.financedUsd, g.consumo.financedUsd, 'y su financiado es el financiamiento')
  igual(g.dinero.servicioUsd, 1473.85, 'la Comisión Helios sin IVA, en su cifra')
  igual(g.dinero.cargos, { devengadoUsd: 254, cobradoUsd: 148, cargos: 51 }, 'los cargos por atraso, en la suya')
  igual(g.dinero.perdido.financedUsd, 59.17, 'lo perdido en financiamiento')
  igual(g.dinero.cajaUsd, 2346.91, 'la caja')
  igual(g.dinero.porPagarLocales, { totalUsd: 3149.66, atrasadoUsd: 379, locales: 3 }, 'lo que se debe a las clínicas')
  igual(g.riesgo.moraPct, 20.38, 'la mora')
  igual(g.riesgo.aTiempo.map((c) => [c.cuota, c.juzgadas, c.aTiempo, c.pct]), [[1, 356, 272, 76.4], [2, 290, 222, 76.6]], 'las dos cuotas a tiempo')
  igual(g.porCadaCien.por100, { servicioUsd: 19.99, cargosUsd: 3.45, personalUsd: 2.16, perdidoUsd: 0.8, margenUsd: 20.48 }, 'por cada cien')
  igual(g.porCadaCien.personalUsd, 159, 'lo pagado al personal, desde el primer día')
  igual(g.curva.length, 3, 'tres semanas de curva')
  igual(g.curva[2], { semana: '2026-09-21', registros: 44, registrosAcum: 194, consumos: 118, financedUsd: 2873, financedAcumUsd: 7373 }, 'una semana de la curva')
}

console.log('\n── Con una clínica ──────────────────────────────────────────────')
{
  const g = leerGeneral(respuestaDeUnLocal())
  igual(g.local, '11111111-1111-1111-1111-111111111111', 'la clínica que usó la base')
  igual(
    [
      g.gente.registros,
      g.gente.verificados,
      g.gente.hanComprado,
      g.gente.hanCompradoPct,
      g.gente.solicitaron,
      g.gente.telefonoConfirmado,
    ],
    [null, null, null, null, null, null],
    'lo de la gente que no se parte, nulo',
  )
  igual([g.consumo.locales, g.consumo.localesActivos], [null, null], 'cuántas clínicas, nulo')
  igual(g.dinero.cajaUsd, null, 'la caja, nula y no cero')
  igual(g.curva.every((s) => s.registros === null && s.registrosAcum === null), true, 'la curva sin registros')
  igual(g.gente.activos, 124, 'los activos sí se parten')
}

console.log('\n── Lo que falta no se inventa ────────────────────────────────')
{
  const sinTasas = respuestaDeMuestra()
  sinTasas.riesgo = { mora_pct: null, impago_pct: null, empate_pct: null, a_tiempo: [{ cuota: 1, juzgadas: 0, a_tiempo: 0, pct: null }] }
  const g = leerGeneral(sinTasas)
  igual([g.riesgo.moraPct, g.riesgo.impagoPct, g.riesgo.empatePct], [null, null, null], 'una tasa sin denominador es nula')
  igual(g.riesgo.aTiempo[0]?.pct, null, 'sin cuotas juzgadas, sin porcentaje')

  const sinPor100 = respuestaDeMuestra()
  sinPor100.por_cada_100 = { financed_usd: 0, consumos: 0, financed_maduro_usd: 0, servicio_usd: 0, cargos_usd: 0, perdido_usd: 0, por_100: null }
  igual(leerGeneral(sinPor100).porCadaCien.por100, null, 'sin financiamiento no hay «por cada cien»')

  const vacia = respuestaDeMuestra()
  vacia.desde = null
  vacia.curva = []
  const v = leerGeneral(vacia)
  igual([v.desde, v.curva.length], [null, 0], 'sin nada: ni desde ni curva')

  const sinMovido = respuestaDeMuestra()
  delete (sinMovido.dinero as Record<string, unknown>).movido
  igual(leerGeneral(sinMovido).dinero.movido, null, 'una base sin 20260928210000: sin lo movido, y nada se rompe')

  const sinFee = respuestaDeMuestra()
  ;(sinFee.dinero as Record<string, unknown>).cobrado = { payable_usd: 10, financed_usd: 8, cuotas: 1 }
  igual(leerGeneral(sinFee).dinero.cobrado.feeUsd, 2, 'sin fee_usd, se deduce: payable − financed')
}

console.log('\n── Lo que está roto falla ────────────────────────────────────')
{
  lanza(() => leerGeneral(null), 'sin respuesta')
  const sinHoy = respuestaDeMuestra()
  delete sinHoy.hoy
  lanza(() => leerGeneral(sinHoy), 'sin el hoy')
  const sinConsumo = respuestaDeMuestra()
  ;(sinConsumo.dinero as Record<string, unknown>).por_cobrar = { payable_usd: 10, fee_usd: 2 }
  lanza(() => leerGeneral(sinConsumo), 'un payable sin su financiamiento no se lee')
  const sinVencido = respuestaDeMuestra()
  delete (sinVencido.dinero as Record<string, unknown>).vencido
  lanza(() => leerGeneral(sinVencido), 'sin lo vencido')
}

if (fallos > 0) {
  console.log(`\n${fallos} ${fallos === 1 ? 'falla' : 'fallan'}`)
  process.exit(1)
}
console.log('\nTodo bien')
