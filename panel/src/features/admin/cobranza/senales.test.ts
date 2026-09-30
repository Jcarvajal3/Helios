/**
 * Pruebas de las señales de un deudor.
 *
 *   npx tsx src/features/admin/cobranza/senales.test.ts
 *
 * Lo que se vigila: que cada señal diga un hecho que la base mandó (y no uno
 * que no puede saber), que un pago en revisión mande sobre todo lo demás,
 * que «no abrió los avisos» solo salga si la app ya los medía, que la
 * intención sea la suma de las señales y que los grupos de la cola partan a
 * todos sin solaparse.
 */
import {
  GRUPOS_DE_COLA,
  SIN_HECHOS,
  diasEntre,
  grupoDe,
  haceCuanto,
  intencionDe,
  leerHechos,
  ordenarPorAtraso,
  senalesDe,
} from './senales'
import type { ContextoDeSenales, FilaParaSenales, HechosDeDeudor } from './senales'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

// Lunes 28-09 a las 15:00 de Caracas (19:00 UTC): día operativo 28.
const AHORA = new Date('2026-09-28T19:00:00Z')
const CTX: ContextoDeSenales = { ahora: AHORA, hoy: '2026-09-28', diasBaja: 30 }

function fila(h: Partial<HechosDeDeudor>, parte: Partial<FilaParaSenales> = {}): FilaParaSenales {
  return {
    overdueUsd: 20,
    daysOverdue: 3,
    status: 'active',
    promiseDate: null,
    promiseStatus: null,
    senales: { ...SIN_HECHOS, ...h },
    ...parte,
  }
}

const claves = (f: FilaParaSenales) => senalesDe(f, CTX).map((s) => s.clave)

console.log('── Leer lo que manda la base ────────────────────────────────')
{
  const h = leerHechos({
    ultima_apertura: '2026-09-27T02:00:00Z',
    avisos: 'apagados',
    avisos_motivo: 'DeviceNotRegistered',
    avisos_entregados: 3,
    ultimo_reporte: { estado: 'rejected', en: '2026-09-25T15:00:00Z', revisado_en: null, nota: 'Referencia no aparece' },
    cuotas_pagadas: 2,
    pagadas_tarde: 0,
  })
  comprueba(h.avisos === 'apagados' && h.avisosEntregados === 3, 'lee los avisos')
  comprueba(h.ultimoReporte?.estado === 'rejected' && h.ultimoReporte.nota === 'Referencia no aparece', 'lee el último reporte')
  comprueba(leerHechos(null) === SIN_HECHOS, 'sin señales, nada')
  comprueba(leerHechos({ avisos: 'raro' }).avisos === null, 'un estado de avisos desconocido no se inventa')
}

console.log('\n── Cuánto hace ──────────────────────────────────────────────')
{
  comprueba(haceCuanto('2026-09-28T18:40:00Z', AHORA) === 'hace 20 min', 'minutos')
  comprueba(haceCuanto('2026-09-28T15:00:00Z', AHORA) === 'hace 4 h', 'horas del mismo día operativo')
  // 23:00 de Caracas del 27 (03:00 UTC del 28): ayer.
  comprueba(haceCuanto('2026-09-28T03:00:00Z', AHORA) === 'ayer', 'la noche anterior es de ayer', haceCuanto('2026-09-28T03:00:00Z', AHORA))
  comprueba(haceCuanto('2026-09-20T20:00:00Z', AHORA) === 'hace 8 días', 'días')
  comprueba(diasEntre('2026-09-28', '2026-09-29') === 1, 'días entre dos fechas')
}

console.log('\n── Las señales ──────────────────────────────────────────────')
{
  const revision = fila({ enRevisionDesde: '2026-09-28T16:00:00Z', entroAPagar: '2026-09-28T15:00:00Z' })
  const s = senalesDe(revision, CTX)
  comprueba(s[0]?.clave === 'en_revision', 'un pago en revisión va primero')
  comprueba(!s.some((x) => x.clave === 'entro_a_pagar'), 'con un pago en revisión, «entró a pagar» sobra')
  comprueba(intencionDe(s) === 'quiere', 'con un pago en revisión, quiere pagar')

  comprueba(
    claves(fila({ entroAPagar: '2026-09-28T15:00:00Z', copioDatos: '2026-09-28T15:02:00Z' })).join() === 'entro_a_pagar,copio_datos',
    'entró a pagar y copió los datos',
  )
  comprueba(
    !claves(fila({ entroAPagar: '2026-09-20T15:00:00Z', ultimoReporte: { estado: 'reconciled', en: '2026-09-21T15:00:00Z', revisadoEn: null, nota: null } })).includes('entro_a_pagar'),
    'entrar a pagar antes de su último pago no cuenta',
  )
  comprueba(
    !claves(fila({ entroAPagar: '2026-09-10T15:00:00Z' })).includes('entro_a_pagar'),
    'entrar a pagar hace más de una semana no cuenta',
  )

  comprueba(claves(fila({ avisos: 'apagados', avisosMotivo: 'DeviceNotRegistered' })).includes('sin_avisos'), 'sin avisos')
  comprueba(
    senalesDe(fila({ avisos: 'nunca' }), CTX).find((x) => x.clave === 'sin_avisos')?.ayuda.includes('Nunca dio permiso') === true,
    'dice por qué no recibe avisos',
  )

  // Avisos entregados: sin medir, solo se dice que le llegaron.
  const sinMedir = fila({ avisos: 'activos', avisosEntregados: 3, vencidaDesde: '2026-09-25' })
  comprueba(claves(sinMedir).includes('avisos_entregados') && !claves(sinMedir).includes('avisos_sin_abrir'), 'sin la OTA no se afirma que no los abrió')
  const medido = fila({ avisos: 'activos', avisosEntregados: 3, vencidaDesde: '2026-09-25', gestosDesde: '2026-09-20T12:00:00Z' })
  comprueba(claves(medido).includes('avisos_sin_abrir'), 'con la OTA desde antes del vencimiento, sí')
  const abrio = fila({ avisos: 'activos', avisosEntregados: 3, avisosAbiertos: 1, abrioAviso: '2026-09-27T20:00:00Z', vencidaDesde: '2026-09-25', gestosDesde: '2026-09-20T12:00:00Z' })
  comprueba(claves(abrio).includes('abrio_aviso') && !claves(abrio).includes('avisos_sin_abrir'), 'abrió un aviso')

  // La app.
  comprueba(claves(fila({ ultimaApertura: '2026-09-22T20:00:00Z', vencidaDesde: '2026-09-25' })).includes('no_abre'), 'no abre desde que venció')
  const abrioApp = senalesDe(fila({ ultimaApertura: '2026-09-27T20:00:00Z', vencidaDesde: '2026-09-25' }), CTX)
  comprueba(abrioApp.some((x) => x.clave === 'abrio_app' && x.tono === 'intencion'), 'abrió la app después de vencer: cuenta a favor')
  const alDia = senalesDe(fila({ ultimaApertura: '2026-09-27T20:00:00Z' }, { overdueUsd: 0, daysOverdue: 0 }), CTX)
  comprueba(alDia.some((x) => x.clave === 'abrio_app' && x.peso === 0), 'sin nada vencido, abrir la app no empuja')

  // Promesas.
  comprueba(claves(fila({}, { promiseDate: '2026-09-28', promiseStatus: 'vence_hoy' })).includes('promete'), 'promete pagar hoy')
  comprueba(claves(fila({ ultimaPromesaRota: '2026-09-24', promesasRotas: 2 })).includes('promesa_rota'), 'promesa rota')
  comprueba(
    !claves(fila({ ultimaPromesaRota: '2026-09-24' }, { promiseDate: '2026-09-30', promiseStatus: 'pendiente' })).includes('promesa_rota'),
    'una promesa nueva tapa la rota',
  )

  // Historia y cuenta.
  comprueba(claves(fila({ cuotasPagadas: 0 })).includes('nunca_pago'), 'nunca ha pagado')
  comprueba(claves(fila({ cuotasPagadas: 3, pagadasTarde: 0 })).includes('siempre_a_tiempo'), 'siempre a tiempo')
  comprueba(claves(fila({ cuotasPagadas: 3, pagadasTarde: 2, atrasoMedioAlPagar: 4.2 })).includes('suele_tarde'), 'suele pagar tarde')
  comprueba(claves(fila({}, { status: 'frozen' })).includes('congelada'), 'cuenta congelada')
  comprueba(claves(fila({}, { daysOverdue: 26 })).includes('baja_pronto'), 'baja de nivel en 4 días')
  comprueba(!claves(fila({}, { daysOverdue: 10 })).includes('baja_pronto'), 'a 20 días de la baja, no se avisa')
}

console.log('\n── La intención ─────────────────────────────────────────────')
{
  comprueba(intencionDe([]) === 'dudosa', 'sin señales, no está claro')
  const evita = senalesDe(fila({ cuotasPagadas: 0, gestionesSinRespuesta: 2, ultimaApertura: '2026-09-15T20:00:00Z', vencidaDesde: '2026-09-25' }), CTX)
  comprueba(intencionDe(evita) === 'evita', 'nunca pagó, no contesta y no abre: lo evita')
  const quiere = senalesDe(fila({ entroAPagar: '2026-09-28T15:00:00Z', cuotasPagadas: 0 }), CTX)
  comprueba(intencionDe(quiere) === 'quiere', 'entró a pagar pesa más que no haber pagado nunca')
}

console.log('\n── Los grupos de la cola ────────────────────────────────────')
{
  const hoy = '2026-09-28'
  comprueba(grupoDe({ overdueUsd: 10, prioridad: 'alta', nextDueDate: '2026-09-20' }, hoy) === 'primero', 'vencido y prioridad alta')
  comprueba(grupoDe({ overdueUsd: 10, prioridad: 'baja', nextDueDate: '2026-09-20' }, hoy) === 'despues', 'vencido y prioridad baja')
  comprueba(grupoDe({ overdueUsd: 10, prioridad: null, nextDueDate: '2026-09-20' }, hoy) === 'despues', 'vencido sin perfil (perdido)')
  comprueba(grupoDe({ overdueUsd: 0, prioridad: null, nextDueDate: '2026-09-28' }, hoy) === 'recordar', 'vence hoy')
  comprueba(grupoDe({ overdueUsd: 0, prioridad: null, nextDueDate: '2026-09-29' }, hoy) === 'recordar', 'vence mañana')
  comprueba(grupoDe({ overdueUsd: 0, prioridad: 'baja', nextDueDate: '2026-10-01' }, hoy) === 'vigilar', 'vence más adelante')
  comprueba(GRUPOS_DE_COLA.length === 4, 'cuatro grupos')
}

console.log('\n── El orden por días de atraso ──────────────────────────────')
{
  const f = (id: string, daysOverdue: number, overdueUsd: number, nextDueDate: string, upcomingUsd = 0) => ({
    id,
    daysOverdue,
    overdueUsd,
    nextDueDate,
    upcomingUsd,
  })
  const orden = ordenarPorAtraso([
    f('manana', 0, 0, '2026-09-29', 10),
    f('3d', 3, 10, '2026-09-25'),
    f('40d-poco', 40, 5, '2026-08-19'),
    f('hoy', 0, 0, '2026-09-28', 5),
    f('40d-mucho', 40, 50, '2026-08-19'),
  ]).map((x) => x.id)
  comprueba(
    orden.join() === '40d-mucho,40d-poco,3d,hoy,manana',
    'de más días a menos, a igual atraso quien más debe, y detrás lo que vence antes',
    orden.join(),
  )
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
