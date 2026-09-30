/**
 * Pruebas de la lectura del JSON de las cohortes.
 *
 *   npx tsx src/features/admin/metricas/cohortes/lectura.test.ts
 *
 * Lo que se vigila: que la lista salga de la más reciente a la más vieja, que
 * cada cuota traiga sus cinco estados con su desglose, que lo que hay que
 * cobrar de la semana (la cuota 1 + la 2) llegue con su desglose, lo cobrado
 * y lo que falta, que la cuota 1 vaya antes que la 2, que un día sin cerrar
 * sea `null` y no un cero, y que una respuesta rota se diga como error en vez
 * de pintarse a cero.
 */
import { LISTA_CRUDA, DETALLE_CRUDO, SEMANA_14 } from './datosDePrueba'
import { RespuestaRota, leerCohorte, leerDetalleDeCohorte, leerListaDeCohortes } from './lectura'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

function lanza(f: () => unknown, titulo: string) {
  let lanzo = false
  try {
    f()
  } catch (e) {
    lanzo = e instanceof RespuestaRota
  }
  if (!lanzo) fallos++
  console.log(`${lanzo ? '  ok  ' : ' FALLA'}  ${titulo}`)
}

console.log('── La lista ───────────────────────────────────────────────────')
{
  const l = leerListaDeCohortes(LISTA_CRUDA)
  igual(l.hoy, '2026-09-26', 'el hoy que usó la base')
  igual(l.graciaDias, 2, 'los días de gracia')
  igual(
    l.cohortes.map((c) => c.semana),
    ['2026-09-21', '2026-09-14', '2026-09-07'],
    'de la semana más reciente a la más vieja',
  )
  igual(l.cohortes[0].enCurso, true, 'la de hoy va en curso')
}

console.log('\n── Una cohorte ────────────────────────────────────────────────')
{
  const c = leerCohorte(SEMANA_14)
  igual(c.consumoUsd, 1152, 'el financiamiento es la suma del financiamiento de sus cuotas')
  igual(c.cuotas.map((q) => q.numero), [1, 2], 'la cuota 1 antes que la 2')
  const q1 = c.cuotas[0]
  igual(
    q1.importe,
    { payableUsd: 709.75, financedUsd: 576.06, feeUsd: 133.69 },
    'lo que se cobra en la cuota 1 viene con su desglose',
  )
  igual(
    q1.estados.vencida,
    { cuotas: 16, personas: 12, importe: { payableUsd: 151.7, financedUsd: 123.13, feeUsd: 28.57 } },
    'cada estado trae cuotas, pacientes e importe con desglose',
  )
  igual(q1.estados.perdida.importe.payableUsd, 0, 'un estado vacío vale cero (la base manda los cinco)')
  igual(q1.venceDesde, '2026-09-21', 'el primer vencimiento')
  // `sequence` llega como texto en algunas respuestas de PostgREST.
  const conTexto = leerCohorte({ ...SEMANA_14, cuotas: SEMANA_14.cuotas.map((q) => ({ ...q, sequence: String(q.sequence) })) })
  igual(conTexto.cuotas.map((q) => q.numero), [1, 2], 'un número de cuota en texto se lee')
}

console.log('\n── Lo que hay que cobrar de la semana ─────────────────────────')
{
  const a = leerCohorte(SEMANA_14).aCobrar
  igual(
    a.importe,
    { payableUsd: 1419.26, financedUsd: 1152, feeUsd: 267.26 },
    'el total a cobrar (cuota 1 + cuota 2) viene con su desglose',
  )
  igual(a.cobrado.importe, { payableUsd: 609.85, financedUsd: 495, feeUsd: 114.85 }, 'lo cobrado, con su desglose')
  igual(a.falta.importe, { payableUsd: 809.41, financedUsd: 657, feeUsd: 152.41 }, 'lo que falta, con su desglose')
  igual(a.estados.vencida.importe.payableUsd, 151.7, 'cada estado de las dos cuotas juntas')
  igual([a.cobradoPct, a.faltaPct], [42.97, 57.03], 'los porcentajes, sobre el total a cobrar')
  igual([a.venceDesde, a.venceHasta], ['2026-09-21', '2026-10-04'], 'del primer vencimiento de la cuota 1 al último de la 2')
  const sinCuotas = leerCohorte({ ...SEMANA_14, a_cobrar: { ...SEMANA_14.a_cobrar, vence_desde: null, vence_hasta: null } })
  igual(sinCuotas.aCobrar.venceDesde, null, 'sin vencimiento (una semana sin cuotas), null y no un día inventado')
}

console.log('\n── El detalle ─────────────────────────────────────────────────')
{
  const d = leerDetalleDeCohorte(DETALLE_CRUDO)
  igual(d.semana, { desde: '2026-09-14', hasta: '2026-09-20', enCurso: false }, 'la semana que usó la base')
  igual(d.curvas.map((c) => c.numero), [1, 2], 'las curvas, la 1 antes que la 2')
  const c1 = d.curvas[0]
  igual(c1.puntos.length, 21, 'veintiún días, de −6 a +14')
  igual(c1.puntos[0], { dia: -6, estaPct: 0.96, mediaPct: 9.23, semanasEnMedia: 4 }, 'el primer día')
  igual(c1.puntos[6].estaPct, null, 'un día sin cerrar es null, no cero')
  igual(d.porLocal[0].nombre, 'La Quinta Bar', 'la clínica de la fila')
  igual(d.porLocal[0].merchantId, '11111111-1111-4111-8111-111111111111', 'y su id')
  igual(leerDetalleDeCohorte({ ...DETALLE_CRUDO, cohorte: null }).cohorte, null, 'una semana sin financiamientos: null')
}

console.log('\n── Una respuesta rota no se pinta a cero ──────────────────────')
lanza(() => leerListaDeCohortes({ cohortes: [] }), 'sin «hoy»')
lanza(() => leerListaDeCohortes(null), 'sin nada')
lanza(() => leerCohorte({ ...SEMANA_14, semana: 'ayer' }), 'con una semana que no es un día')
lanza(
  () => leerCohorte({ ...SEMANA_14, cuotas: [{ ...SEMANA_14.cuotas[0], payable_usd: null }] }),
  'con una cuota sin lo que se cobra',
)
lanza(
  () => leerCohorte({ ...SEMANA_14, cuotas: [{ ...SEMANA_14.cuotas[0], estados: { a_tiempo: SEMANA_14.cuotas[0].estados.a_tiempo } }] }),
  'con una cuota a la que le faltan estados',
)
lanza(() => leerCohorte({ ...SEMANA_14, cuotas: [{ ...SEMANA_14.cuotas[0], sequence: 3 }] }), 'con una cuota 3')
lanza(() => leerCohorte({ ...SEMANA_14, a_cobrar: undefined }), 'sin lo que hay que cobrar de la semana')
lanza(
  () => leerCohorte({ ...SEMANA_14, a_cobrar: { ...SEMANA_14.a_cobrar, cobrado: null } }),
  'sin lo cobrado de la semana',
)
lanza(() => leerDetalleDeCohorte({ ...DETALLE_CRUDO, semana: null }), 'un detalle sin la semana que usó')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
