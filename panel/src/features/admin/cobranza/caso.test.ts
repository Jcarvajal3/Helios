/**
 * Pruebas del caso de cobranza: la línea de tiempo, el WhatsApp, las
 * promesas y el rendimiento.
 *
 *   npx tsx src/features/admin/cobranza/caso.test.ts
 *
 * Lo que se vigila: que la línea de tiempo ponga cada cosa en su instante
 * (una cuota vence al empezar el día operativo siguiente), que el WhatsApp no
 * se abra con un mensaje a medias y que un porcentaje sin denominador llegue
 * como `null` y no como cero.
 */
import { formatVes } from '@/components/ui'
import {
  CLAVES_PLANTILLA,
  EJEMPLO_DE_COBRO,
  claveDePlantilla,
  cuandoSeUsa,
  diasDeAtraso,
  mensajeDeCobro,
  rellenar,
  usaLaCuenta,
} from '@/features/admin/plantillas'
import type { CortesDeTramo } from '@/features/admin/tramos'
import type { CollectionContact } from '@/features/admin/contacts'
import type { LateFee } from '@/features/admin/lateFees'
import type { UserDetail } from '@/features/admin/users'
import type { CollectionRow } from './cartera'
import { inicioDelDiaOperativo, lineaDeTiempo } from './lineaDeTiempo'
import { leerPromesas, promesasDelEstado, tasaDeCumplimiento } from './promesas'
import { comoPeriodo, leerCura, leerEfectividadDeCobranza, leerRecuperado, periodoDeLaCura, rangoDe } from './rendimiento'
import { whatsAppDeCobro } from './whatsapp'
import { SIN_HECHOS } from './senales'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const HOY = '2026-09-24'

console.log('── La línea de tiempo ───────────────────────────────────────')
{
  comprueba(
    inicioDelDiaOperativo('2026-09-12') === '2026-09-12T04:00:00.000Z',
    'el día operativo empieza a medianoche en Caracas',
  )

  type Cuota = UserDetail['installments'][number]
  const cuota = (parte: Partial<Cuota>): Cuota => ({
    id: 'c',
    chargeId: 'ch',
    orderNumber: 1043,
    sequence: 1,
    amountUsd: 2.39,
    financedUsd: 1.94,
    currency: 'USD',
    amountCur: 2.39,
    financedCur: 1.94,
    dueDate: '2026-09-11',
    status: 'pending',
    paidAt: null,
    merchantName: 'Bar Nocturno',
    daysOverdue: 13,
    writtenOffAt: null,
    paidDay: null,
    onTime: null,
    ...parte,
  })
  const gestion: CollectionContact = {
    id: 'g1',
    contactedAt: '2026-09-20T15:00:00Z',
    channel: 'llamada',
    template: null,
    note: null,
    promiseDate: '2026-09-21',
    actorName: 'Operador',
    outcome: 'promesa',
    nextActionOn: null,
    promiseStatus: 'rota',
  }
  const cargo: LateFee = {
    id: 'f1',
    amountUsd: 2,
    daysLate: 4,
    businessDate: '2026-09-15',
    status: 'pending',
    waivedAt: null,
    waiveReason: null,
    installmentId: 'c',
    sequence: 1,
    dueDate: '2026-09-11',
    merchantName: 'Bar Nocturno',
  }

  const sucesos = lineaDeTiempo({
    gestiones: [gestion],
    pagos: [],
    cuotas: [
      cuota({ id: 'vencida' }),
      // Pagada a las 23:00 del día en que vencía: todavía a tiempo.
      cuota({ id: 'a-tiempo', dueDate: '2026-09-18', status: 'paid', paidAt: '2026-09-19T03:00:00Z' }),
      // Reportada el día que vencía y aprobada dos días después: no se venció.
      cuota({
        id: 'aprobada-tarde',
        dueDate: '2026-09-17',
        status: 'paid',
        paidAt: '2026-09-19T16:00:00Z',
        paidDay: '2026-09-17',
        onTime: true,
      }),
      // Reportada dos días tarde: se venció, pero dentro de la gracia.
      cuota({
        id: 'en-la-gracia',
        dueDate: '2026-09-16',
        status: 'paid',
        paidAt: '2026-09-18T16:00:00Z',
        paidDay: '2026-09-18',
        onTime: true,
      }),
      // Reportada cinco días tarde: fuera de la gracia.
      cuota({
        id: 'tarde',
        dueDate: '2026-09-18',
        status: 'paid',
        paidAt: '2026-09-23T16:00:00Z',
        paidDay: '2026-09-23',
        onTime: false,
      }),
      // Sin veredicto del servidor (base sin 20260927696000): sin marca.
      cuota({ id: 'sin-veredicto', dueDate: '2026-09-10', status: 'paid', paidAt: '2026-09-20T16:00:00Z' }),
      // Aún no vence.
      cuota({ id: 'futura', dueDate: '2026-09-30' }),
    ],
    cargos: [cargo],
    hoy: HOY,
  })
  const ids = sucesos.map((s) => s.id)

  comprueba(ids[0] === 'pagada:tarde', 'lo último, arriba', ids.join(', '))
  comprueba(ids.includes('vencio:vencida'), 'una cuota sin pagar y pasada de fecha se venció')
  comprueba(!ids.includes('vencio:a-tiempo'), 'pagarla la noche del vencimiento no es vencerse', ids.join(', '))
  comprueba(ids.includes('vencio:tarde') && ids.includes('pagada:tarde'), 'la pagada tarde se vence y luego se paga')
  comprueba(!ids.some((i) => i.endsWith(':futura')), 'lo que aún no vence no sale')
  const vencio = sucesos.find((s) => s.id === 'vencio:vencida')
  comprueba(vencio?.cuando === '2026-09-12T04:00:00.000Z', 'se vence al empezar el día operativo siguiente', vencio?.cuando)
  const pagadaTarde = sucesos.find((s) => s.id === 'pagada:tarde')
  comprueba(pagadaTarde?.tipo === 'pagada' && pagadaTarde.conAtraso, 'la pagada tarde lleva la marca de atraso')
  comprueba(!ids.includes('vencio:aprobada-tarde'), 'se juzga por el día del reporte, no el de la aprobación', ids.join(', '))
  const enLaGracia = sucesos.find((s) => s.id === 'pagada:en-la-gracia')
  comprueba(ids.includes('vencio:en-la-gracia'), 'reportada el día +2: se venció')
  comprueba(enLaGracia?.tipo === 'pagada' && !enLaGracia.conAtraso, 'reportada dentro de la gracia: sin marca de atraso')
  const sinVeredicto = sucesos.find((s) => s.id === 'pagada:sin-veredicto')
  comprueba(sinVeredicto?.tipo === 'pagada' && !sinVeredicto.conAtraso, 'sin veredicto del servidor, sin marca')
  comprueba(ids.includes('cargo:f1') && ids.includes('gestion:g1'), 'salen el cargo y la gestión')
}

console.log('\n── El mensaje de WhatsApp ───────────────────────────────────')
{
  const persona: CollectionRow = {
    userId: 'u1',
    fullName: 'ANA PÉREZ',
    phone: '584141234567',
    status: 'frozen',
    level: 1,
    bucket: 'congelado',
    openUsd: 10,
    overdueUsd: 5,
    upcomingUsd: 5,
    overdueDesglose: null,
    upcomingDesglose: null,
    overdueText: null,
    overdueVesHoy: null,
    upcomingText: null,
    upcomingVesHoy: null,
    daysOverdue: 4,
    nextDueDate: '2026-09-20',
    installmentCount: 2,
    merchants: [],
    lastPaymentAt: null,
    lastContactAt: null,
    lastContactChannel: null,
    lastContactBy: null,
    lastContactNote: null,
    lastContactOutcome: null,
    lastContactNextActionOn: null,
    promiseDate: null,
    promiseStatus: null,
    contactedSinceDue: false,
    perfil: 'se_le_paso',
    prioridad: 'baja',
    orden: 1,
    motivo: 'Pagó a tiempo 4 de 4 cuotas; lleva 4 días de atraso',
    lostUsd: 0,
    lostFinancedUsd: 0,
    senales: SIN_HECHOS,
  }
  // Los cortes de hoy: gracia 3, intervalo 7, baja 30, expulsión 60. Con 4
  // días de atraso, la persona está en t2.
  const cortes: CortesDeTramo = { gracia: 3, intervalo: 7, baja: 30, expulsion: 60 }
  const plantilla = { bucket: 't2', label: 'Con cargo por atraso', body: 'Hola {nombre}, debes {monto_usd} desde hace {dias_atraso}. Paga a {banco} {telefono_pago}.' }
  const cuenta = { isActive: true, bankName: 'Banco X', rif: 'J-1', phone: '584120000000' }
  const listo = <T,>(valor: T) => ({ estado: 'listo' as const, valor })

  const ok = whatsAppDeCobro({
    persona: listo(persona),
    plantillas: listo([plantilla]),
    cuentas: listo([cuenta]),
    tasa: listo(900),
    cortes: listo<CortesDeTramo | null>(cortes),
  })
  comprueba(ok.listo && ok.href.startsWith('https://wa.me/584141234567?text='), 'abre el chat con el número')
  comprueba(ok.listo && decodeURIComponent(ok.href).includes('Hola ANA, debes $5,00'), 'rellena el nombre y lo vencido')
  comprueba(ok.listo && decodeURIComponent(ok.href).includes('desde hace 4 días'), 'rellena los días de atraso')
  comprueba(ok.listo && ok.plantilla === 'Con cargo por atraso', 'elige la plantilla por el tramo, no por el bucket viejo')

  const viejaSola = whatsAppDeCobro({
    persona: listo(persona),
    plantillas: listo([{ ...plantilla, bucket: 'congelado' }]),
    cuentas: listo([cuenta]),
    tasa: listo(900),
    cortes: listo<CortesDeTramo | null>(cortes),
  })
  comprueba(!viejaSola.listo && viejaSola.motivo === 'No hay plantilla para este tramo.', 'la plantilla vieja ya no vale para un tramo')

  const sinCortes = whatsAppDeCobro({
    persona: listo(persona),
    plantillas: listo([plantilla]),
    cuentas: listo([cuenta]),
    tasa: listo(900),
    cortes: listo<CortesDeTramo | null>(null),
  })
  comprueba(!sinCortes.listo && sinCortes.motivo.includes('Parámetros'), 'sin los días de los tramos, dicho y sin inventarlos')

  const tramo = (dias: number, bucket = 'congelado') => claveDePlantilla({ daysOverdue: dias, bucket }, cortes)
  comprueba(tramo(0, 'por_vencer') === 'por_vencer' && tramo(0, 'vence_hoy') === 'vence_hoy', 'sin atraso, la de antes de vencer o la del día')
  comprueba(
    [1, 3, 4, 7, 8, 29, 30, 60, 61].map((d) => tramo(d)).join(' ') === 't1 t1 t2 t2 t3 t3 t4 t4 t5',
    'cada día de atraso cae en su tramo',
    [1, 3, 4, 7, 8, 29, 30, 60, 61].map((d) => tramo(d)).join(' '),
  )
  comprueba(CLAVES_PLANTILLA.join(' ') === 'por_vencer vence_hoy t1 t2 t3 t4 t5', 'las siete, en orden')
  comprueba(cuandoSeUsa('t1', cortes) === '1–3 días de atraso' && cuandoSeUsa('t5', cortes) === 'Más de 60 días de atraso', 'rótulo de días de cada tramo')
  comprueba(cuandoSeUsa('t4', null) === null && cuandoSeUsa('vence_hoy', null) === 'El día del vencimiento', 'sin cortes no se inventa el rótulo')
  comprueba(diasDeAtraso(1) === '1 día' && diasDeAtraso(12) === '12 días', 'un día en singular')

  const sinPlantillas = whatsAppDeCobro({
    persona: listo(persona),
    plantillas: { estado: 'error' },
    cuentas: listo([cuenta]),
    tasa: listo(900),
    cortes: listo<CortesDeTramo | null>(cortes),
  })
  comprueba(!sinPlantillas.listo && sinPlantillas.motivo === 'No se pudieron leer las plantillas.', 'sin plantillas no se abre un chat vacío')

  const sinCuenta = whatsAppDeCobro({
    persona: listo(persona),
    plantillas: listo([plantilla]),
    cuentas: listo([{ ...cuenta, isActive: false }]),
    tasa: listo(900),
    cortes: listo<CortesDeTramo | null>(cortes),
  })
  comprueba(!sinCuenta.listo && sinCuenta.motivo.includes('cuenta de cobro'), 'sin cuenta activa no se manda a pagar a una cuenta en blanco')

  const fuera = whatsAppDeCobro({
    persona: listo(null),
    plantillas: listo([plantilla]),
    cuentas: listo([cuenta]),
    tasa: listo(900),
    cortes: listo<CortesDeTramo | null>(cortes),
  })
  comprueba(!fuera.listo, 'quien no está en la cartera no tiene mensaje de cobro')

  const sinTelefono = whatsAppDeCobro({
    persona: listo({ ...persona, phone: null }),
    plantillas: listo([plantilla]),
    cuentas: listo([cuenta]),
    tasa: listo(900),
    cortes: listo<CortesDeTramo | null>(cortes),
  })
  comprueba(!sinTelefono.listo && sinTelefono.motivo === 'No tiene teléfono.', 'sin teléfono, dicho')

  comprueba(usaLaCuenta('Paga a {banco}') && !usaLaCuenta('Hola {nombre}'), 'sabe si el texto usa la cuenta')
  comprueba(
    mensajeDeCobro('{monto_bs}', { persona, tasa: null, cuenta: null }) === 'el equivalente en bolívares',
    'sin tasa, el monto en bolívares se dice con palabras',
  )
  // Una orden en euros (2026-10-07): lo que dice la cartera en su moneda y sus
  // bolívares de hoy mandan sobre los dólares por la tasa del dólar.
  const enEuros = { ...persona, overdueText: '€56,96 + $2', overdueVesHoy: 52864 }
  comprueba(
    mensajeDeCobro('{monto_usd} = {monto_bs}', { persona: enEuros, tasa: 800, cuenta: null }) ===
      `€56,96 + $2 = ${formatVes(52864)}`,
    'una deuda en euros se pide en euros y con los bolívares de cada tasa',
  )
  comprueba(rellenar('{nombre} {toString} {otra}', EJEMPLO_DE_COBRO) === 'Ana {toString} {otra}', 'lo que no es variable se queda tal cual')
}

console.log('\n── Las promesas ─────────────────────────────────────────────')
{
  const p = leerPromesas({
    business_date: HOY,
    from: '2026-08-25',
    to: null,
    summary: { vence_hoy: 1, pendiente: 2, cumplida: 3, rota: 1 },
    rows: [
      { contact_id: 'a', user_id: 'u1', promise_date: '2026-09-30', status: 'pendiente', contacted_at: '2026-09-20T10:00:00Z', channel: 'llamada', overdue_usd: 0, last_payment: null },
      { contact_id: 'b', user_id: 'u2', promise_date: '2026-09-26', status: 'pendiente', contacted_at: '2026-09-21T10:00:00Z', channel: 'whatsapp', overdue_usd: 4.5, last_payment: { report_id: 'r1', created_at: '2026-09-22T10:00:00Z', status: 'rejected', amount_usd: 4.5 } },
      { contact_id: 'c', user_id: 'u3', promise_date: '2026-09-21', status: 'desconocido' },
    ],
  })
  comprueba(p.filas.length === 2, 'un estado desconocido no tiene pestaña donde salir')
  comprueba(p.filas[1].ultimoPago?.estado === 'rejected' && p.filas[1].vencidoHoyUsd === 4.5, 'lee el último pago y la deuda')
  comprueba(p.hasta === null, 'sin tope de fecha es null')
  const pendientes = promesasDelEstado(p.filas, 'pendiente')
  comprueba(pendientes[0].gestionId === 'b', 'las pendientes, la más cercana primero')
  const t = tasaDeCumplimiento(p.recuento)
  comprueba(t.pct === 75 && t.resueltas === 4, 'el cumplimiento cuenta solo las resueltas', JSON.stringify(t))
  comprueba(tasaDeCumplimiento({ vence_hoy: 2, pendiente: 1, cumplida: 0, rota: 0 }).pct === null, 'sin resueltas no es un 0 %')
}

console.log('\n── El rendimiento ───────────────────────────────────────────')
{
  const tramos = { grace_days: 3, interval_days: 7, demotion_days: 30, expulsion_days: 60 }
  const r = leerRecuperado({
    from: '2026-09-18',
    to: HOY,
    recovered: { usd: 2.395, installments: 1, people: 1, written_off_usd: 0 },
    late_fees: { usd: 2, count: 1 },
    by_tramo: [{ tramo: 't3', usd: 2.395, installments: 1, people: 1 }],
    overdue_at_start: { usd: 0, installments: 0, people: 0, written_off_usd: 0 },
    recovered_from_start: { usd: 0, installments: 0, people: 0 },
    recovery_pct: null,
    tramos,
  })
  comprueba(r.porTramo.length === 5 && r.porTramo[2].usd === 2.395, 'siempre los cinco tramos, en orden')
  comprueba(r.pctRecuperacion === null, 'sin nada vencido al empezar, no hay porcentaje')
  comprueba(r.cortes?.baja === 30, 'lee los cortes de la base')
  comprueba(r.cargosPorAtraso.usd === 2 && r.recuperado.usd === 2.395, 'el cargo por atraso va aparte')

  const cura = leerCura({
    weeks: [{ cut_date: '2026-09-21', cure: { t1: { from_people: 2, cured: 0, pct: 0 }, t2: { from_people: 0, cured: 0, pct: null } } }],
    tramos,
  })
  comprueba(cura.semanas[0].porTramo.t1.pct === 0, 'una cura del 0 % con gente es un cero de verdad')
  comprueba(cura.semanas[0].porTramo.t2.pct === null, 'sin gente en el tramo, sin porcentaje')
  comprueba(cura.semanas[0].porTramo.t5.pct === null, 'un tramo que no vino no es un cero')

  // La semana de la cura se rotula por su lunes y su cierre, no por el corte
  // (el lunes SIGUIENTE): la del 14 al 20 sep no puede decir «semana del 21».
  const pasada = leerCura({
    weeks: [{ cut_date: '2026-09-21', from_date: '2026-09-14', cierre: '2026-09-20', en_curso: false, cure: {} }],
    tramos,
  }).semanas[0]
  comprueba(periodoDeLaCura(pasada) === 'Del 14 sep al 20 sep', `semana pasada: ${periodoDeLaCura(pasada)}`)
  const actual = leerCura({
    weeks: [{ cut_date: '2026-09-27', from_date: '2026-09-21', cierre: '2026-09-27', en_curso: true, cure: {} }],
    tramos,
  }).semanas[0]
  comprueba(periodoDeLaCura(actual) === 'Del 21 sep a hoy', `semana en curso: ${periodoDeLaCura(actual)}`)
  comprueba(periodoDeLaCura(cura.semanas[0]) === 'Hasta 21 sep', 'sin su lunes, solo el corte')

  const e = leerEfectividadDeCobranza({
    from: '2026-09-01',
    to: HOY,
    window_hours: 72,
    total: { contacts: 6, with_payment: 2, open_window: 2, rate_pct: 25 },
    by_channel: [{ key: 'llamada', contacts: 4, with_payment: 1, open_window: 1, rate_pct: 33.3 }, { key: 'raro', contacts: 1 }],
    by_hour: [{ hour: 11, contacts: 3, with_payment: 1, open_window: 1, rate_pct: 50 }],
  })
  comprueba(e.porHora.length === 24 && e.porHora[11].gestiones === 3, 'siempre las 24 horas')
  comprueba(e.porHora[3].pct === null, 'una hora sin gestiones no tiene porcentaje')
  comprueba(e.porCanal.length === 1, 'un canal desconocido se descarta')

  comprueba(comoPeriodo(30) === 30 && comoPeriodo('90') === 90 && comoPeriodo(15) === undefined, 'el periodo de la URL')
  const rango = rangoDe(HOY, 7)
  comprueba(rango.desde === '2026-09-18' && rango.hasta === HOY, 'siete días con los dos extremos dentro')
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
