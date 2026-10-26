/**
 * Pruebas de registrar un pago.
 *
 *   npx tsx src/features/admin/pagosRegistrados/registrarPago.test.ts
 *
 * Lo que se vigila: la regla de «lo vencido va primero» (marcar una cuota por
 * vencer arrastra las vencidas; quitar una vencida suelta las adelantadas), el
 * total con los cargos por atraso, la moneda de cada cuota, lo que dice la
 * base que debería decir el comprobante y su diferencia, la ruta de la
 * captura y el aviso del doble control.
 */
import {
  alternarCuota,
  METODOS_DEL_PACIENTE,
  armarCuotas,
  diferenciaEnBs,
  explicarErrorDeAprobacion,
  extensionDelComprobante,
  fraseDelExtracto,
  leerPagoRegistrado,
  leerPrevisionDelPago,
  montoDeLaCuota,
  motivoDeArchivo,
  motivoDeSeleccion,
  rutaDelComprobante,
  totalDeLaSeleccion,
} from './registrarPago'
import type { CuotaParaPagar } from './registrarPago'

let fallos = 0
function igual(nombre: string, obtenido: unknown, esperado: unknown) {
  const ok = JSON.stringify(obtenido) === JSON.stringify(esperado)
  if (!ok) {
    fallos++
    console.error(`✗ ${nombre}\n  esperado: ${JSON.stringify(esperado)}\n  obtenido: ${JSON.stringify(obtenido)}`)
  } else {
    console.log(`✓ ${nombre}`)
  }
}

const HOY = '2026-10-15'

function cuota(p: Partial<CuotaParaPagar> & Pick<CuotaParaPagar, 'id' | 'dueDate'>): CuotaParaPagar {
  return {
    chargeId: 'c1',
    orderNumber: 1042,
    sequence: 1,
    amountUsd: 61.6,
    moneda: 'USD',
    amountCur: 61.6,
    merchantName: 'Consultorio Demo',
    lateFeesUsd: 0,
    enRevision: false,
    ...p,
  }
}

// Dos financiamientos: la cuota 1 del primero venció, la del segundo vence hoy
// y las cuotas 2 vencen después.
const pendientes = [
  cuota({ id: 'a1', dueDate: '2026-10-08', lateFeesUsd: 2 }),
  cuota({ id: 'b1', chargeId: 'c2', dueDate: '2026-10-15', amountUsd: 30.8 }),
  cuota({ id: 'a2', dueDate: '2026-10-22', sequence: 2 }),
  cuota({ id: 'b2', chargeId: 'c2', dueDate: '2026-10-29', sequence: 2, amountUsd: 30.8 }),
]
const lista = (s: Set<string>) => [...s].sort()

// ── Lo vencido va primero ──────────────────────────────────────────────────

igual('marcar una vencida sola vale', lista(alternarCuota(new Set(), 'a1', pendientes, HOY)), ['a1'])
igual(
  'marcar una por vencer arrastra las que vencen hoy o antes',
  lista(alternarCuota(new Set(), 'a2', pendientes, HOY)),
  ['a1', 'a2', 'b1'],
)
igual(
  'desmarcar una vencida suelta las adelantadas',
  lista(alternarCuota(new Set(['a1', 'b1', 'a2', 'b2']), 'b1', pendientes, HOY)),
  ['a1'],
)
igual(
  'desmarcar una adelantada deja las vencidas',
  lista(alternarCuota(new Set(['a1', 'b1', 'a2']), 'a2', pendientes, HOY)),
  ['a1', 'b1'],
)
const conRevision = pendientes.map((c) => (c.id === 'a1' ? { ...c, enRevision: true } : c))
igual('una en revisión no se marca', lista(alternarCuota(new Set(), 'a1', conRevision, HOY)), [])
igual(
  'y no se exige para adelantar',
  lista(alternarCuota(new Set(), 'a2', conRevision, HOY)),
  ['a2', 'b1'],
)

igual('sin nada marcado', motivoDeSeleccion(new Set(), pendientes, HOY), 'Marca al menos una cuota.')
igual('solo lo vencido vale', motivoDeSeleccion(new Set(['b1']), pendientes, HOY), null)
igual(
  'adelantar dejando una vencida no',
  motivoDeSeleccion(new Set(['a1', 'a2']), pendientes, HOY),
  'Para adelantar una cuota hay que pagar también la que ya venció.',
)
igual(
  'adelantar dejando dos vencidas no',
  motivoDeSeleccion(new Set(['b2']), pendientes, HOY),
  'Para adelantar una cuota hay que pagar también las 2 que ya vencieron.',
)
igual('adelantar con todo lo vencido sí', motivoDeSeleccion(new Set(['a1', 'b1', 'b2']), pendientes, HOY), null)
igual(
  'una que ya no está pendiente',
  motivoDeSeleccion(new Set(['zz']), pendientes, HOY),
  'Alguna de las cuotas marcadas ya no está pendiente.',
)

// ── Total ──────────────────────────────────────────────────────────────────

igual('cuotas + sus cargos', totalDeLaSeleccion(new Set(['a1', 'b1']), pendientes), {
  cuotasUsd: 92.4,
  cargosUsd: 2,
  totalUsd: 94.4,
})
igual('los cargos sueltos van con cualquier pago', totalDeLaSeleccion(new Set(['b1']), pendientes, 2).totalUsd, 32.8)
igual('sin selección, cero (ni los sueltos)', totalDeLaSeleccion(new Set(), pendientes, 2).totalUsd, 0)

const armadas = armarCuotas(
  [
    { id: 'x2', chargeId: 'c', orderNumber: 7, sequence: 2, amountUsd: 10, dueDate: '2026-10-22', merchantName: 'M', status: 'pending', writtenOffAt: null },
    { id: 'x1', chargeId: 'c', orderNumber: 7, sequence: 1, amountUsd: 10, dueDate: '2026-10-15', merchantName: 'M', status: 'pending', writtenOffAt: null },
    { id: 'p1', chargeId: 'd', orderNumber: 8, sequence: 1, amountUsd: 10, dueDate: '2026-10-01', merchantName: 'M', status: 'paid', writtenOffAt: null },
    { id: 'w1', chargeId: 'e', orderNumber: 9, sequence: 1, amountUsd: 10, dueDate: '2026-08-01', merchantName: 'M', status: 'pending', writtenOffAt: '2026-10-01' },
  ],
  [
    { installmentId: 'x1', amountUsd: 2, status: 'pending', waivedAt: null },
    { installmentId: 'x1', amountUsd: 2, status: 'pending', waivedAt: '2026-10-10' },
    { installmentId: 'p1', amountUsd: 2, status: 'pending', waivedAt: null },
    { installmentId: null, amountUsd: 2, status: 'pending', waivedAt: null },
    { installmentId: 'x2', amountUsd: 2, status: 'paid', waivedAt: null },
  ],
  new Set(['x2']),
)
igual('solo las pendientes vivas, de la más vieja a la más nueva', armadas.cuotas.map((c) => c.id), ['x1', 'x2'])
igual('el cargo condonado no viaja', armadas.cuotas[0]?.lateFeesUsd, 2)
igual('en revisión se marca', armadas.cuotas[1]?.enRevision, true)
igual('los sueltos: de una cuota pagada y sin cuota', armadas.cargosSueltosUsd, 4)
igual('sin moneda, dólares', [armadas.cuotas[0]?.moneda, armadas.cuotas[0]?.amountCur], ['USD', 10])

const enEuros = armarCuotas(
  [
    { id: 'e1', chargeId: 'c', orderNumber: 7, sequence: 1, amountUsd: 63.39, currency: 'EUR', amountCur: 56.96, dueDate: '2026-10-15', merchantName: 'M', status: 'pending', writtenOffAt: null },
  ],
  [],
  new Set(),
)
igual('una cuota de una orden en euros lleva sus euros', [enEuros.cuotas[0]?.moneda, enEuros.cuotas[0]?.amountCur], ['EUR', 56.96])
igual('se elige en dólares, con sus euros al lado', enEuros.cuotas[0] ? montoDeLaCuota(enEuros.cuotas[0]) : null, '$63,39 · cobrada en €56,96')
igual('una en dólares, solo dólares', montoDeLaCuota(cuota({ id: 'z', dueDate: HOY })), '$61,60')

// ── Cómo paga ──────────────────────────────────────────────────────────────

igual('el paciente solo paga en bolívares', METODOS_DEL_PACIENTE.map((m) => m.value), ['pago_movil', 'transferencia'])

// ── Bolívares ──────────────────────────────────────────────────────────────

const prevision = leerPrevisionDelPago({
  paid_on: '2026-10-15',
  installments_usd: '63.39',
  late_fee_usd: 2,
  amount_usd: 65.39,
  amount_eur: '56.96',
  amount_usd_part: 2,
  fx_rate: 184.52,
  fx_rate_eur: 210.1,
  amount_ves: 12336.3,
})
igual(
  'la previsión de la base, leída',
  [prevision.amountEur, prevision.amountUsdPart, prevision.fxRateEur, prevision.amountVes],
  [56.96, 2, 210.1, 12336.3],
)
igual('sin la tasa que falta, sin bolívares', leerPrevisionDelPago({ amount_ves: null, fx_rate_eur: null }).amountVes, null)
igual('diferencia que cuadra (céntimos)', diferenciaEnBs(11735, 11735.47, 184.52), { bs: -0.47, usd: -0, cuadra: true })
igual('pagó de menos', diferenciaEnBs(11000, 11735.47, 184.52), { bs: -735.47, usd: -3.99, cuadra: false })
// El margen (2026-10-26): 10 Bs de menos y 100 de más cuadran; un céntimo más allá, no.
igual('13,42 de más (Andrea Toledo) cuadra', diferenciaEnBs(14155, 14141.58, 886.2271)?.cuadra, true)
igual('10 de menos cuadra', diferenciaEnBs(14131.58, 14141.58, 886.2271)?.cuadra, true)
igual('10,01 de menos no', diferenciaEnBs(14131.57, 14141.58, 886.2271)?.cuadra, false)
igual('100 de más cuadra', diferenciaEnBs(14241.58, 14141.58, 886.2271)?.cuadra, true)
igual('100,01 de más no', diferenciaEnBs(14241.59, 14141.58, 886.2271)?.cuadra, false)
igual('con el margen de los parámetros', diferenciaEnBs(14155, 14141.58, 886.2271, { menosBs: 0, masBs: 5 })?.cuadra, false)
igual('sin monto escrito, sin diferencia', diferenciaEnBs(null, 11735.47, 184.52), null)

// ── La captura ─────────────────────────────────────────────────────────────

igual('ruta por paciente', rutaDelComprobante('u-1', 'abc', 'jpg'), 'u-1/abc.jpg')
igual('extensión por el tipo', extensionDelComprobante({ name: 'x', type: 'image/png' }), 'png')
igual('jpeg por el nombre', extensionDelComprobante({ name: 'Captura.JPEG', type: '' }), 'jpg')
igual('pdf', extensionDelComprobante({ name: 'recibo.pdf', type: 'application/pdf' }), 'pdf')
igual('un .exe no', extensionDelComprobante({ name: 'x.exe', type: 'application/x-msdownload' }), null)
igual('demasiado grande', motivoDeArchivo({ name: 'a.png', type: 'image/png', size: 11 * 1024 * 1024 }), 'La captura pesa más de 10 MB.')
igual('una imagen normal vale', motivoDeArchivo({ name: 'a.png', type: 'image/png', size: 200_000 }), null)

// ── Respuesta y extracto ───────────────────────────────────────────────────

const respuesta = leerPagoRegistrado({
  report_id: 'r1',
  quote_id: 'q1',
  amount_usd: '63.60',
  late_fee_usd: 2,
  fx_rate: 184.52,
  fx_rate_eur: 210.1,
  amount_eur: 56.96,
  amount_ves: 11735.47,
  status: 'reported',
  candidatos_extracto: 1,
})
igual('respuesta leída', [respuesta.reportId, respuesta.amountUsd, respuesta.candidatosExtracto], ['r1', 63.6, 1])
igual('con su parte en euros', [respuesta.amountEur, respuesta.fxRateEur], [56.96, 210.1])
igual('un candidato: se puede aprobar', fraseDelExtracto(1).tono, 'success')
igual('varios: elegir', fraseDelExtracto(3).tono, 'warning')
igual('ninguno: esperar al extracto', fraseDelExtracto(0).tono, 'info')

// ── Doble control ──────────────────────────────────────────────────────────

const cuatroOjos = { code: '42501', message: 'Quien registró el pago no puede aprobarlo' }
igual(
  'el 42501 del doble control se explica',
  explicarErrorDeAprobacion(cuatroOjos, 'Quien registró el pago no puede aprobarlo'),
  'Doble control: quien registró este pago no puede aprobarlo. Pide a otra persona del equipo (o a un super admin) que lo apruebe. · Quien registró el pago no puede aprobarlo',
)
igual(
  'un 42501 de permisos no se disfraza',
  explicarErrorDeAprobacion({ code: '42501', message: 'Falta el segundo factor' }, 'Falta el segundo factor'),
  'Falta el segundo factor',
)
igual(
  'si quien aprueba lo registró, se explica aunque el texto no lo diga',
  explicarErrorDeAprobacion({ code: '42501', message: 'Sin permiso' }, 'Sin permiso', true)?.startsWith('Doble control'),
  true,
)
igual('otro error, tal cual', explicarErrorDeAprobacion({ code: '22023' }, 'x'), 'x')

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
