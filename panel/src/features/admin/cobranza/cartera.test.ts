/**
 * Pruebas de la cartera vencida y de la gestión.
 *
 *   npx tsx src/features/admin/cobranza/cartera.test.ts
 *
 * Lo que se vigila: que el número de cada filtro y las filas que enseña
 * salgan de la misma regla, que Plazo vigente, Vence hoy y Plazo vencido
 * partan la cola sin solaparse, que «Vence mañana» mire el día operativo (no
 * el de calendario) y que el diálogo de la gestión pida lo mismo que la base.
 */
import {
  FILTROS_CARTERA,
  filtroDeCartera,
  idsSinRepetir,
  leerCartera,
  pasaElFiltro,
  proximaAccion,
  recuentoPorFiltro,
  rotuloDeFiltro,
  desgloseCorto,
  sumasDeCartera,
  totalPorCobrar,
} from './cartera'
import type { FilaCartera } from './cartera'
import {
  aGestion,
  avisoDeGestionAnotada,
  borradorInicial,
  motivoParaNoAnotar,
  resumenDeGestion,
} from './gestion'
import type { CortesDeTramo } from '@/features/admin/tramos'
import { diaOperativo } from '@/components/ui'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const CORTES: CortesDeTramo = { intervalo: 7, baja: 30, expulsion: 60 }
const HOY = '2026-09-24'

function fila(parte: Partial<FilaCartera>): FilaCartera {
  return {
    bucket: 'por_vencer',
    overdueUsd: 0,
    daysOverdue: 0,
    nextDueDate: '2026-09-28',
    contactedSinceDue: false,
    ...parte,
  }
}

console.log('── El día operativo ─────────────────────────────────────────')
{
  // 23:59 de Caracas (03:59 UTC) todavía es el día anterior.
  comprueba(diaOperativo(new Date('2026-09-25T03:59:00Z')) === '2026-09-24', 'a las 23:59 sigue siendo ayer')
  comprueba(diaOperativo(new Date('2026-09-25T04:00:00Z')) === '2026-09-25', 'a medianoche cambia el día')
  // 23:30 de Caracas es 03:30 UTC del día siguiente: el calendario UTC ya dice 26.
  comprueba(diaOperativo(new Date('2026-09-26T03:30:00Z')) === '2026-09-25', 'a medianoche en UTC sigue el día de Caracas')
  comprueba(diaOperativo(new Date('2026-09-26T06:00:00Z')) === '2026-09-26', 'la madrugada ya es del día nuevo: el corte no es a las 10')
}

console.log('\n── Los filtros ──────────────────────────────────────────────')
{
  const ctx = { hoy: HOY, cortes: CORTES }
  const manana = fila({ nextDueDate: '2026-09-25' })
  const pasado = fila({ nextDueDate: '2026-09-27' })
  const hoy = fila({ bucket: 'vence_hoy', nextDueDate: HOY })
  const t1 = fila({ bucket: 'congelado', overdueUsd: 5, daysOverdue: 2, nextDueDate: '2026-09-22' })
  const t2Contactado = fila({ bucket: 'congelado', overdueUsd: 8, daysOverdue: 13, contactedSinceDue: true })
  const t4 = fila({ bucket: 'expulsion', overdueUsd: 20, daysOverdue: 70 })

  comprueba(pasaElFiltro(manana, 'recordar_hoy', ctx), 'vence mañana: «Vence mañana»')
  comprueba(!pasaElFiltro(pasado, 'recordar_hoy', ctx), 'vence pasado mañana: no es «Vence mañana»')
  comprueba(pasaElFiltro(manana, 'por_vencer', ctx), '«Vence mañana» también está en Plazo vigente')
  comprueba(pasaElFiltro(hoy, 'vence_hoy', ctx) && !pasaElFiltro(hoy, 'por_vencer', ctx), 'vence hoy no está en Plazo vigente')
  comprueba(!pasaElFiltro(hoy, 'plazo_vencido', ctx), 'vence hoy no está en Plazo vencido')
  comprueba(pasaElFiltro(t1, 'plazo_vencido', ctx) && pasaElFiltro(t4, 'plazo_vencido', ctx), 'cualquier tramo está en Plazo vencido')
  comprueba(!pasaElFiltro(manana, 'plazo_vencido', ctx), 'sin nada vencido no está en Plazo vencido')
  comprueba(pasaElFiltro(t1, 't1', ctx) && !pasaElFiltro(t1, 't2', ctx), '2 días de atraso: primer tramo')
  comprueba(pasaElFiltro(t2Contactado, 't2', ctx), '13 días: segundo tramo')
  comprueba(pasaElFiltro(fila({ overdueUsd: 5, daysOverdue: 7 }), 't1', ctx), '7 días: todavía el primer tramo (la gracia ya no corta)')
  comprueba(pasaElFiltro(t4, 't4', ctx), '70 días: último tramo')
  comprueba(pasaElFiltro(t1, 'sin_contactar', ctx), 'atrasado sin gestión: sin contactar')
  comprueba(!pasaElFiltro(t2Contactado, 'sin_contactar', ctx), 'con gestión desde el vencimiento: ya contactado')
  comprueba(!pasaElFiltro(manana, 'sin_contactar', ctx), 'sin nada vencido no es «sin contactar»')
  comprueba(!pasaElFiltro(t1, 't1', { hoy: HOY, cortes: null }), 'sin cortes, ningún tramo')

  const filas = [manana, pasado, hoy, t1, t2Contactado, t4]
  const r = recuentoPorFiltro(filas, ctx)
  comprueba(r.todos === 6, 'todos cuenta todas las filas', String(r.todos))
  comprueba(r.recordar_hoy === 1 && r.por_vencer === 2 && r.vence_hoy === 1, 'recuentos fijos', JSON.stringify(r))
  comprueba(r.t1 === 1 && r.t2 === 1 && r.t4 === 1 && r.t3 === 0, 'recuentos por tramo', JSON.stringify(r))
  comprueba(r.sin_contactar === 2, 'sin contactar', String(r.sin_contactar))
  comprueba(r.plazo_vencido === 3, 'plazo vencido', String(r.plazo_vencido))
  comprueba(
    r.por_vencer + r.vence_hoy + r.plazo_vencido === r.todos,
    'Plazo vigente + Vence hoy + Plazo vencido = Todos',
    JSON.stringify(r),
  )
  comprueba(
    r.t1 + r.t2 + r.t3 + r.t4 === r.plazo_vencido,
    'la suma de los tramos es Plazo vencido',
    JSON.stringify(r),
  )
  // Cada fila, en uno y solo uno de los tres plazos.
  for (const f of filas) {
    const en = (['por_vencer', 'vence_hoy', 'plazo_vencido'] as const).filter((p) => pasaElFiltro(f, p, ctx))
    comprueba(en.length === 1, `la fila de ${f.daysOverdue} días cae en un solo plazo`, en.join(', '))
  }
  // Vencidos sin contactar y Vence mañana son partes de otro filtro.
  for (const f of filas) {
    if (pasaElFiltro(f, 'sin_contactar', ctx)) comprueba(pasaElFiltro(f, 'plazo_vencido', ctx), 'sin contactar ⊂ plazo vencido')
    if (pasaElFiltro(f, 'recordar_hoy', ctx)) comprueba(pasaElFiltro(f, 'por_vencer', ctx), 'vence mañana ⊂ plazo vigente')
  }

  const s = sumasDeCartera([
    { overdueUsd: 5, upcomingUsd: 2 },
    { overdueUsd: 0, upcomingUsd: 3 },
  ])
  comprueba(s.vencidoUsd === 5 && s.personasConVencido === 1 && s.porVencerUsd === 5, 'sumas de lo que se ve')
  comprueba(s.vencidoDesglose === null, 'sin partes en las filas, la suma no inventa un desglose')

  const conPartes = sumasDeCartera([
    { overdueUsd: 5, upcomingUsd: 2, overdueDesglose: { financedUsd: 4, feeUsd: 1 }, upcomingDesglose: { financedUsd: 1.6, feeUsd: 0.4 } },
    { overdueUsd: 0, upcomingUsd: 3, overdueDesglose: { financedUsd: 0, feeUsd: 0 }, upcomingDesglose: { financedUsd: 2.4, feeUsd: 0.6 } },
  ])
  comprueba(
    conPartes.vencidoDesglose?.financedUsd === 4 && conPartes.vencidoDesglose.feeUsd === 1,
    'lo vencido suma sus dos partes',
    JSON.stringify(conPartes.vencidoDesglose),
  )
  comprueba(
    Math.abs((conPartes.porVencerDesglose?.financedUsd ?? 0) - 4) < 1e-9 &&
      Math.abs((conPartes.porVencerDesglose?.feeUsd ?? 0) - 1) < 1e-9,
    'lo por vencer también',
    JSON.stringify(conPartes.porVencerDesglose),
  )
  comprueba(
    desgloseCorto({ financedUsd: 37, feeUsd: 8.2 }) === 'financiamiento $37,00 · comisión $8,20',
    'el desglose corto dice «financiamiento» y «comisión»',
    desgloseCorto({ financedUsd: 37, feeUsd: 8.2 }),
  )
}

console.log('\n── El filtro de la URL ───────────────────────────────────────')
{
  // Cada valor que acepta la URL vuelve igual: los enlaces guardados
  // (`?tramo=t3`, `?tramo=recordar_hoy`, `?tramo=sin_contactar`) siguen llegando.
  for (const f of FILTROS_CARTERA) comprueba(filtroDeCartera(f) === f, `«${f}» se lee tal cual`, String(filtroDeCartera(f)))
  comprueba(filtroDeCartera('t5') === 't4', 'el quinto tramo de antes cae en el último de ahora', String(filtroDeCartera('t5')))
  comprueba(filtroDeCartera('t6') === undefined && filtroDeCartera(5) === undefined, 'lo que no es un filtro no pasa')
  comprueba(filtroDeCartera('toString') === undefined, 'ni una clave de Object')
  comprueba(rotuloDeFiltro('recordar_hoy', CORTES) === 'Vence mañana', 'la clave vieja lleva el rótulo nuevo')
  comprueba(rotuloDeFiltro('t2', CORTES) === 'Plazo vencido, 8–29 días de atraso', 'un tramo se nombra dentro de Plazo vencido', rotuloDeFiltro('t2', CORTES))
  comprueba(rotuloDeFiltro('t1', null) === 'Tramo de atraso', 'sin cortes no se inventan los días')
}

console.log('\n── La próxima acción y la cola ──────────────────────────────')
{
  comprueba(proximaAccion(null, HOY) === null, 'sin fecha, sin acción')
  comprueba(proximaAccion('2026-09-20', HOY)?.cuando === 'atrasada', 'fecha pasada: atrasada')
  comprueba(proximaAccion(HOY, HOY)?.cuando === 'hoy', 'hoy: toca hoy')
  comprueba(proximaAccion('2026-09-30', HOY)?.cuando === 'mas_adelante', 'fecha futura: más adelante')
  comprueba(idsSinRepetir(['a', 'b', 'a', 'c']).join() === 'a,b,c', 'un paciente con dos promesas es un caso')
}

console.log('\n── La lectura de admin_collections ──────────────────────────')
{
  const c = leerCartera({
    demotion_days: 30,
    expulsion_days: 60,
    rows: [
      {
        user_id: 'u1',
        full_name: 'PRUEBA',
        phone_e164: '584261111111',
        status: 'frozen',
        level: 1,
        bucket: 'congelado',
        open_usd: 4.78,
        overdue_usd: 2.39,
        upcoming_usd: 2.39,
        days_overdue: 13,
        next_due_date: '2026-09-11',
        installment_count: 2,
        merchants: ['Bar Nocturno'],
        last_payment_at: null,
        last_contact_at: '2026-09-20T15:00:00+00:00',
        last_contact_channel: 'llamada',
        last_contact_by: 'Operador Helios',
        last_contact_note: null,
        last_contact_outcome: 'promesa',
        last_contact_next_action_on: '2026-09-26',
        promise_date: '2026-09-21',
        promise_status: 'rota',
        contacted_since_due: true,
        overdue_financed_usd: 1.95,
        overdue_fee_usd: 0.44,
      },
      { user_id: 'u2', bucket: 'raro', days_overdue: 0, last_contact_outcome: 'inventado' },
    ],
  })
  const [a, b] = c.rows
  comprueba(c.demotionDays === 30 && c.rows.length === 2, 'lee la cabecera y las filas')
  comprueba(a.lastContactOutcome === 'promesa' && a.promiseStatus === 'rota', 'lee el resultado y la promesa')
  comprueba(a.lastContactNextActionOn === '2026-09-26', 'lee la próxima acción')
  comprueba(a.merchants[0] === 'Bar Nocturno' && a.overdueUsd === 2.39, 'lee montos y clínicas')
  comprueba(b.bucket === 'por_vencer', 'un nombre de tramo desconocido se deduce del atraso')
  comprueba(b.lastContactOutcome === null, 'un resultado desconocido no se inventa')
  comprueba(b.promiseDate === null && b.phone === null, 'lo que falta es null, no un texto vacío')
  comprueba(
    a.overdueDesglose?.financedUsd === 1.95 && a.overdueDesglose.feeUsd === 0.44,
    'lee el desglose de lo vencido',
    JSON.stringify(a.overdueDesglose),
  )
  comprueba(a.upcomingDesglose === null && b.overdueDesglose === null, 'sin el financiamiento, el desglose es null y no un cero')
}

console.log('\n── Anotar una gestión ───────────────────────────────────────')
{
  const vacio = borradorInicial()
  comprueba(motivoParaNoAnotar(vacio, HOY) === 'Elige qué pasó en la gestión.', 'el resultado es obligatorio')

  const promesaSinFecha = borradorInicial({ resultado: 'promesa' })
  comprueba(motivoParaNoAnotar(promesaSinFecha, HOY) !== undefined, 'una promesa pide su fecha')
  comprueba(
    motivoParaNoAnotar({ ...promesaSinFecha, fechaPrometida: '2026-09-20' }, HOY) === 'La fecha prometida ya pasó.',
    'una promesa en el pasado no se acepta',
  )
  comprueba(motivoParaNoAnotar({ ...promesaSinFecha, fechaPrometida: HOY }, HOY) === undefined, 'prometer para hoy vale')
  comprueba(
    motivoParaNoAnotar(borradorInicial({ resultado: 'no_contesta', volverALlamar: '2026-09-01' }), HOY) !== undefined,
    'volver a llamar en el pasado no se acepta',
  )

  const cambiado = aGestion({
    ...borradorInicial({ fechaPrometida: '2026-09-30', nota: '  ' }),
    resultado: 'contesto',
  })
  comprueba(cambiado.fechaPrometida === null, 'la fecha prometida solo viaja con «Prometió pagar»')
  comprueba(cambiado.nota === null && cambiado.plantilla === null, 'los vacíos viajan como null')

  const noContesta = resumenDeGestion('Ana', borradorInicial({ resultado: 'no_contesta' }))
  comprueba(!noContesta.includes('hablaste'), 'si no contestó, no dice «hablaste con»', noContesta)
  const contesto = resumenDeGestion('Ana', borradorInicial({ resultado: 'contesto', canal: 'whatsapp' }))
  comprueba(contesto.includes('hablaste con Ana por WhatsApp'), 'si contestó, lo dice', contesto)
  const promesa = resumenDeGestion('Ana', borradorInicial({ resultado: 'promesa', fechaPrometida: '2026-09-30' }))
  comprueba(promesa.includes('prometió') && promesa.includes('30/09/26'), 'la promesa lleva su día', promesa)

  comprueba(
    avisoDeGestionAnotada({ ...cambiado, resultado: 'promesa', fechaPrometida: '2026-09-30' }).includes('30/09/26'),
    'el aviso de una promesa dice el día',
  )
}

console.log('\n── El total por cobrar, como Métricas › Global ──────────────')
{
  const t = totalPorCobrar([
    // Debe 30 vencido, de lo que 10 está perdido (8 de consumo), y 20 por vencer.
    {
      overdueUsd: 30,
      overdueDesglose: { financedUsd: 24, feeUsd: 6 },
      upcomingUsd: 20,
      upcomingDesglose: { financedUsd: 16, feeUsd: 4 },
      lostUsd: 10,
      lostFinancedUsd: 8,
    },
    // Solo le queda lo perdido: no debe nada «por cobrar».
    {
      overdueUsd: 5,
      overdueDesglose: { financedUsd: 4, feeUsd: 1 },
      upcomingUsd: 0,
      upcomingDesglose: null,
      lostUsd: 5,
      lostFinancedUsd: 4,
    },
    // Al día, con algo por vencer.
    {
      overdueUsd: 0,
      overdueDesglose: null,
      upcomingUsd: 12,
      upcomingDesglose: { financedUsd: 10, feeUsd: 2 },
      lostUsd: 0,
      lostFinancedUsd: 0,
    },
  ])
  comprueba(t.usd === 52, 'vencido sin lo perdido + por vencer', String(t.usd))
  comprueba(t.partes?.financedUsd === 42 && t.partes.feeUsd === 10, 'con sus dos partes', JSON.stringify(t.partes))
  comprueba(t.personas === 2, 'quien solo debe lo perdido no cuenta', String(t.personas))
  comprueba(t.perdido.usd === 15 && t.perdido.personas === 2, 'lo perdido, aparte', JSON.stringify(t.perdido))
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
