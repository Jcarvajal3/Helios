/**
 * Pruebas de «Tu cola» de Inicio.
 *
 *   npx tsx src/components/admin/inicio/colas.test.ts
 *
 * Lo que se vigila: que cada cola cuente con la regla de su pantalla, que los
 * ids salgan en el orden en que se recorren (el primero es el que abre
 * «Empezar»), que el plazo pinte bien el punto y que la lista ponga arriba lo
 * urgente y abajo lo vacío.
 */
import { formatUsd } from '@/components/ui'
import type { MerchantPayable, QueueItem } from '@/features/admin/api'
import type { Promesa, Promesas } from '@/features/admin/cobranza/promesas'
import {
  ordenarColas,
  puestoDe,
  resumirAbonos,
  resumirAlertasAltas,
  resumirCartera,
  resumirPagosALocales,
  resumirPagosReportados,
  resumirPromesasDeHoy,
  tieneTrabajo,
} from './colas'
import type { FilaParaLaCola, Lectura, Plazo } from './colas'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const AHORA = Date.parse('2026-09-25T15:00:00Z')
const HORA = 3_600_000
const HOY = '2026-09-25'

function haceHoras(h: number): string {
  return new Date(AHORA - h * HORA).toISOString()
}

function pago(id: string, horas: number): QueueItem {
  return {
    reportId: id,
    status: 'reported',
    createdAt: haceHoras(horas),
    method: 'pago_movil',
    bank: 'Banco de Venezuela',
    reference: '123456',
    payerDocument: null,
    payerPhone: null,
    note: null,
    reviewedAt: null,
    reviewedByName: null,
    amountUsd: 10,
    amountVes: 10_000,
    fxRate: 1000,
    installmentCount: 1,
    installmentsUsd: 10,
    lateFeeUsd: 0,
    userId: `persona-${id}`,
    fullName: 'Ana Pérez',
    phone: '584141234567',
    userDocument: null,
    userStatus: 'active',
    userLevel: 1,
    referenceCollisions: 0,
    statementMatches: 0,
    statementMatchesAvailable: 0,
    statementLine: null,
    purchases: [],
    lateFees: [],
  }
}

function local(id: string, parte: Partial<MerchantPayable>): MerchantPayable {
  return {
    merchantId: id,
    merchantName: `Clínica ${id}`,
    taxId: null,
    isTest: false,
    todayDate: HOY,
    nextRunDate: '2026-09-28',
    nextRunUsd: 0,
    accruedUsd: 0,
    accruedCount: 0,
    overdueUsd: 0,
    oldestDueDate: null,
    upcomingUsd: 0,
    totalPendingUsd: 0,
    lastPayoutOn: null,
    lastPayoutUsd: null,
    ...parte,
  }
}

function promesa(userId: string, parte: Partial<Promesa>): Promesa {
  return {
    gestionId: `g-${userId}-${parte.fecha ?? HOY}`,
    userId,
    nombre: null,
    telefono: null,
    estadoPersona: 'frozen',
    contactadoEl: '2026-09-23T15:00:00Z',
    canal: 'llamada',
    resultado: 'promesa',
    nota: null,
    quien: 'Operador Helios',
    fecha: HOY,
    estado: 'vence_hoy',
    renegociada: false,
    vencidoHoyUsd: 0,
    vencidoHoyFinancedUsd: 0,
    vencidoHoyFeeUsd: 0,
    diasDeAtraso: 0,
    ultimoPago: null,
    ...parte,
  }
}

function filaCartera(userId: string, parte: Partial<FilaParaLaCola>): FilaParaLaCola {
  return {
    userId,
    bucket: 'por_vencer',
    overdueUsd: 0,
    upcomingUsd: 0,
    daysOverdue: 0,
    nextDueDate: '2026-09-30',
    contactedSinceDue: false,
    ...parte,
  }
}

console.log('── Caja ─────────────────────────────────────────────────────')
{
  const r = resumirPagosReportados([pago('b', 5), pago('a', 30), pago('c', 1)], AHORA)
  comprueba(r.cantidad === 3, 'cuenta todos los pagos por aprobar', String(r.cantidad))
  comprueba(r.ids.join(',') === 'a,b,c', 'del más viejo al más nuevo, como la lista', r.ids.join(','))
  comprueba(r.plazo === 'pasado', 'con uno de más de 24 h, el plazo ya pasó', r.plazo)
  comprueba(r.detalle === 'El más viejo espera 1 d', 'dice cuánto espera el más viejo', String(r.detalle))

  const hoy = resumirPagosReportados([pago('b', 5)], AHORA)
  comprueba(hoy.plazo === 'hoy' && hoy.detalle === 'El más viejo espera 5 h', 'con menos de 24 h es para hoy', `${hoy.plazo} ${hoy.detalle}`)

  const vacia = resumirPagosReportados([], AHORA)
  comprueba(vacia.cantidad === 0 && vacia.detalle === null, 'sin pagos no hay detalle')
}
{
  const r = resumirAbonos(
    [
      { id: 'x', amountUsd: 10 },
      { id: 'y', amountUsd: 5 },
      { id: 'z', amountUsd: null },
    ],
    100,
  )
  comprueba(r.cantidad === 3 && !r.alTope, 'cuenta los abonos y no llega al tope')
  comprueba(
    r.detalle === `${formatUsd(15)} sin asignar, y 1 sin tasa del día`,
    'suma solo los que tienen tasa y dice cuántos no',
    String(r.detalle),
  )
  comprueba(r.ids.at(0) === 'x', 'el primero es el primero de la lista, que es el que abre «Empezar»')
  comprueba(resumirAbonos([{ id: 'x', amountUsd: 1 }], 1).alTope, 'en el tope, el número es un mínimo')
}
{
  const r = resumirPagosALocales([
    local('uno', { overdueUsd: 50 }),
    local('dos', { overdueUsd: 0, nextRunUsd: 20 }),
    local('prueba', { overdueUsd: 30, isTest: true }),
  ])
  comprueba(r.cantidad === 1, 'solo cuentan las clínicas con atraso, sin los de prueba', String(r.cantidad))
  comprueba(r.detalle === `${formatUsd(50)} sin transferir`, 'el atraso sin la clínica de prueba', String(r.detalle))
  comprueba(r.plazo === 'pasado', 'un cierre sin transferir ya es un atraso')
}

console.log('\n── Cobranza ─────────────────────────────────────────────────')
{
  const p: Promesas = {
    hoy: HOY,
    desde: '2026-08-26',
    hasta: null,
    recuento: { vence_hoy: 3, pendiente: 1, cumplida: 0, rota: 0 },
    filas: [
      promesa('ana', { vencidoHoyUsd: 20, vencidoHoyFinancedUsd: 16, vencidoHoyFeeUsd: 4, contactadoEl: '2026-09-22T15:00:00Z' }),
      promesa('ana', { vencidoHoyUsd: 20, vencidoHoyFinancedUsd: 16, vencidoHoyFeeUsd: 4, contactadoEl: '2026-09-24T15:00:00Z' }),
      promesa('luis', { vencidoHoyUsd: 10, vencidoHoyFinancedUsd: 8, vencidoHoyFeeUsd: 2 }),
      promesa('eva', { estado: 'pendiente', fecha: '2026-09-27', vencidoHoyUsd: 99 }),
    ],
  }
  const r = resumirPromesasDeHoy(p)
  comprueba(r.cantidad === 3, 'el número es el del recuento de su pantalla', String(r.cantidad))
  comprueba(r.ids.join(',') === 'ana,luis', 'un paciente con dos promesas es un solo caso', r.ids.join(','))
  comprueba(
    r.detalle === `Deben ${formatUsd(30)} vencidos (financiamiento ${formatUsd(24)} · fee ${formatUsd(6)}) y no han reportado el pago`,
    'la deuda se suma una vez por paciente, sin las pendientes y con sus dos partes',
    String(r.detalle),
  )
  const sinDeuda = resumirPromesasDeHoy({ ...p, filas: [promesa('luis', {})] })
  comprueba(sinDeuda.detalle === 'Todavía no han reportado el pago', 'sin deuda vencida no se escribe «$0,00»')
}
{
  const filas = [
    filaCartera('a', { bucket: 'congelado', overdueUsd: 5, daysOverdue: 10, overdueDesglose: { financedUsd: 4, feeUsd: 1 } }),
    filaCartera('b', { bucket: 'congelado', overdueUsd: 10, daysOverdue: 20, overdueDesglose: { financedUsd: 8, feeUsd: 2 } }),
    filaCartera('c', { bucket: 'congelado', overdueUsd: 8, daysOverdue: 30, contactedSinceDue: true }),
    filaCartera('d', { upcomingUsd: 12, nextDueDate: '2026-09-26' }),
    filaCartera('e', { upcomingUsd: 7, nextDueDate: '2026-09-29' }),
  ]
  const sin = resumirCartera(filas, 'sin_contactar', HOY)
  comprueba(sin.cantidad === 2, 'sin contactar: vencidos con los que nadie habló', String(sin.cantidad))
  comprueba(sin.ids.join(',') === 'b,a', 'el más atrasado primero, como la cartera', sin.ids.join(','))
  comprueba(sin.plazo === 'pasado', 'la deuda ya venció')
  comprueba(
    sin.detalle === `${formatUsd(15)} vencidos (financiamiento ${formatUsd(12)} · fee ${formatUsd(3)}) sin gestión desde que vencieron`,
    'suma lo vencido de esas filas, con sus dos partes',
    String(sin.detalle),
  )

  const recordar = resumirCartera(filas, 'recordar_hoy', HOY)
  comprueba(recordar.ids.join(',') === 'd', 'recordar hoy: solo lo que vence mañana', recordar.ids.join(','))
  // Sin las partes en la fila (una respuesta vieja), el importe sale sin ellas: no se inventan.
  comprueba(recordar.plazo === 'hoy' && recordar.detalle === `${formatUsd(12)} vencen mañana`, 'y es para hoy', String(recordar.detalle))
  const conPartes = resumirCartera(
    [filaCartera('d', { upcomingUsd: 12, nextDueDate: '2026-09-26', upcomingDesglose: { financedUsd: 9.6, feeUsd: 2.4 } })],
    'recordar_hoy',
    HOY,
  )
  comprueba(
    conPartes.detalle === `${formatUsd(12)} vencen mañana (financiamiento ${formatUsd(9.6)} · fee ${formatUsd(2.4)})`,
    'con las partes, «Vence mañana» las dice',
    String(conPartes.detalle),
  )
}

console.log('\n── Riesgo ───────────────────────────────────────────────────')
{
  const r = resumirAlertasAltas({ pendientesAltas: 3, pendientesMedias: 2, revisadas: 7 })
  comprueba(r.cantidad === 3, 'la cola cuenta las altas sin revisar, como la insignia', String(r.cantidad))
  comprueba(r.plazo === 'hoy' && r.ids.length === 0, 'es para hoy y abre la lista: las alertas no tienen ficha')
  comprueba(r.detalle === 'Además hay 2 de gravedad media sin revisar', 'dice cuántas medias esperan', String(r.detalle))
  const sinMedias = resumirAlertasAltas({ pendientesAltas: 1, pendientesMedias: 0, revisadas: 0 })
  comprueba(sinMedias.detalle === null, 'sin medias pendientes no dice nada más', String(sinMedias.detalle))
}

console.log('\n── El orden de la lista ─────────────────────────────────────')
{
  const listo = (plazo: Plazo, cantidad = 1): Lectura => ({
    estado: 'listo',
    resumen: { cantidad, alTope: false, detalle: null, plazo, ids: [] },
  })
  const colas = [
    { id: 'vacia', lectura: listo('pasado', 0) },
    { id: 'hoy-1', lectura: listo('hoy') },
    { id: 'error', lectura: { estado: 'error', reintentar: () => {} } satisfies Lectura },
    { id: 'pasado', lectura: listo('pasado') },
    { id: 'cargando', lectura: { estado: 'cargando' } satisfies Lectura },
    { id: 'espera', lectura: listo('puede_esperar') },
    { id: 'hoy-2', lectura: listo('hoy') },
  ]
  const orden = ordenarColas(colas).map((c) => c.id).join(' ')
  comprueba(
    orden === 'pasado hoy-1 hoy-2 error espera cargando vacia',
    'lo que pasó, lo de hoy, lo que no se pudo leer, lo que espera, lo que carga y lo vacío',
    orden,
  )
  comprueba(puestoDe(listo('pasado', 0)) === 5, 'una cola vacía va al final aunque su plazo sea rojo')
  comprueba(tieneTrabajo(listo('hoy')) && !tieneTrabajo(listo('hoy', 0)), 'solo una cola con algo se puede empezar')
  comprueba(!tieneTrabajo({ estado: 'error', reintentar: () => {} }), 'una cola sin leer no se empieza: no es un cero')
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
