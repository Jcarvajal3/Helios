/**
 * Pruebas de la lectura de `admin_metricas_semanas`.
 *
 *   npx tsx src/features/admin/metricas/semana/lectura.test.ts
 *
 * Lo que se vigila: que cada cifra llegue a su sitio con su clase de dinero,
 * que lo que se paga en cuotas llegue con sus dos partes, que «no se parte
 * por local» y «sin dato» lleguen como null y no como cero, y que una
 * respuesta sin la semana elegida se rechace en vez de pintarse en ceros.
 */
import { leerRespuestaSemanas } from './lectura'
import { respuestaCruda } from './__fixtures__/respuestaSemanas'

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
  } catch {
    lanzo = true
  }
  if (!lanzo) fallos++
  console.log(`${lanzo ? '  ok  ' : ' FALLA'}  ${titulo}`)
}

console.log('── La respuesta entera ───────────────────────────────────────')
const r = leerRespuestaSemanas(respuestaCruda({ n: 3 }))
igual(r.hoy, '2026-09-26', 'el hoy que usó la base')
igual(r.semana, { desde: '2026-09-21', hasta: '2026-09-27', enCurso: true }, 'la semana que usó la base')
igual(r.semanas.length, 3, 'tres semanas')
igual(
  r.semanas.map((s) => s.desde),
  ['2026-09-07', '2026-09-14', '2026-09-21'],
  'de la más vieja a la elegida',
)
igual(r.graciaDias, 2, 'los días de gracia')
igual(r.local, null, 'sin clínica')

console.log('── Una semana ────────────────────────────────────────────────')
const ultima = r.semanas.at(-1)
igual(ultima?.enCurso, true, 'la última está en curso')
igual(ultima?.dias, 6, 'y lleva seis días')
igual(ultima?.hastaDato, '2026-09-26', 'hasta hoy')
const c = ultima?.cifras
igual(c?.consumo.consumoUsd, 912.4, 'financiamiento sin comisión')
igual(c?.consumo.ticketMedioUsd, 30.41, 'ticket medio')
igual(c?.ingreso.servicioUsd, 182.48, 'Comisión Helios sin IVA, aparte')
igual(
  c?.cobro.vencian,
  { payableUsd: 1062.97, financedUsd: 862.8, feeUsd: 200.17, cuotas: 60 },
  'lo que vencía llega con sus dos partes',
)
igual(c?.cobro.aTiempo, { juzgadas: 40, aTiempo: 32, pct: 80 }, 'el cobro a tiempo con lo juzgado')
igual(c?.cobro.juzgadoHasta, '2026-09-23', 'hasta qué vencimiento se juzgó')
igual(
  c?.riesgo.vencido,
  { payableUsd: 180.76, financedUsd: 146.72, feeUsd: 34.04, cuotas: 9, personas: 9 },
  'lo vencido llega con sus dos partes',
)
igual(c?.riesgo.moraPct, 9.39, 'la mora')
igual(c?.gente, { registros: 64, verificados: 64, primerConsumo: 18, solicitaron: 71 }, 'la gente: registros verificados y quien pidió el código')
igual(c?.caja, { transferidoALocalesUsd: 400, pagosALocales: 2, enCajaUsd: 2611 }, 'la caja')

console.log('── La comparación ────────────────────────────────────────────')
igual(r.comparacion.mismaAltura, true, 'a la misma altura')
igual([r.comparacion.desde, r.comparacion.hasta, r.comparacion.dias], ['2026-09-14', '2026-09-19', 6], 'los mismos seis días')
igual(r.comparacion.cifras.consumo.consumoUsd, 815, 'con sus cifras')

console.log('── Nulos, no ceros ───────────────────────────────────────────')
const conLocal = leerRespuestaSemanas(
  respuestaCruda({ n: 2, local: 'b6a4f1d2-0000-4000-8000-000000000001', ultima: { registros: null, verificados: null, solicitaron: null, caja: null } }),
)
igual(conLocal.local, 'b6a4f1d2-0000-4000-8000-000000000001', 'la clínica que filtró la base')
igual(conLocal.semanas.at(-1)?.cifras.gente.registros, null, 'los registros no se parten por clínica: null')
igual(conLocal.semanas.at(-1)?.cifras.gente.solicitaron, null, 'quien pidió el código tampoco: null')
igual(conLocal.semanas.at(-1)?.cifras.caja.enCajaUsd, null, 'la caja tampoco')
const sinNada = leerRespuestaSemanas(respuestaCruda({ n: 1, ultima: {} }))
igual(sinNada.semanas[0]?.cifras.consumo.ticketMedioUsd, null, 'sin financiamientos no hay ticket medio')
igual(sinNada.semanas[0]?.cifras.cobro.aTiempo.pct, null, 'sin cuotas juzgadas no hay tasa')
igual(sinNada.semanas[0]?.cifras.riesgo.moraPct, null, 'sin nada vivo no hay mora')

console.log('── Respuestas rotas ──────────────────────────────────────────')
lanza(() => leerRespuestaSemanas(null), 'una respuesta vacía no se pinta en ceros')
lanza(() => leerRespuestaSemanas({ ...respuestaCruda(), semana: null }), 'sin la semana usada, se rechaza')
lanza(() => leerRespuestaSemanas({ ...respuestaCruda(), filas: [] }), 'sin semanas, se rechaza')
lanza(
  () => leerRespuestaSemanas({ ...respuestaCruda(), semana: { desde: '2026-09-28', hasta: '2026-10-04', en_curso: true } }),
  'si la última no es la elegida, se rechaza',
)
lanza(() => leerRespuestaSemanas({ ...respuestaCruda(), comparacion: null }), 'sin la comparación, se rechaza')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} ${fallos === 1 ? 'fallo' : 'fallos'}.`)
if (fallos > 0) process.exit(1)
