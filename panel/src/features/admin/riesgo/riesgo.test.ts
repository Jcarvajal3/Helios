/**
 * Pruebas de la lectura de Riesgo: el flujo entre tramos, la mora por tramo,
 * las cosechas y sus curvas, el volumen de la ventana, las alertas y la URL.
 *
 *   npx tsx src/features/admin/riesgo/riesgo.test.ts
 *
 * Lo que se comprueba aquí no se ve mirando la pantalla: una celda de la
 * matriz que cae en otra columna, una cosecha a medias dibujada como si
 * estuviera entera, o un «no hay dato» que se vuelve un cero.
 */
import type { CortesDeTramo } from '@/features/admin/tramos'
import { alertasDeLaClinica, describirAlerta, filtrarAlertas, leerAlertas } from './alertas'
import { cosechaEnCurso, leerCosechas, leerCurvas, rangoDelMes, rotuloDeMes, seriesDeCurvas } from './cosechas'
import {
  filaDeLaMismaClave,
  impagoDeLaCuota2,
  leerLocalesPorVolumen,
  leerPrimeraCuota,
  leerUsoDelCupo,
  otraCuota,
} from './credito'
import { deudaPorTramo, leerFlujo, matrizDeFlujo, resumenDelFlujo, sentidoDelPaso } from './flujo'
import { volumenDeLaVentana } from './volumen'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const CORTES: CortesDeTramo = { gracia: 3, intervalo: 7, baja: 30, expulsion: 60 }

console.log('── El paso entre tramos ─────────────────────────────────────')
{
  // La forma de `admin_collection_flow` (CONTRATOS-D1), con una semana.
  const flujo = leerFlujo({
    business_date: '2026-09-24',
    weeks_requested: 1,
    tramos: { grace_days: 3, interval_days: 7, demotion_days: 30, expulsion_days: 60, buckets: [] },
    weeks: [
      {
        cut_date: '2026-09-14',
        people_total: 6,
        people: { al_dia: 2, t1: 2, t2: 1, t3: 1, t4: 0, t5: 0 },
        overdue_usd: { t1: 4.785, t2: 15, t3: 20, t4: 0, t5: 0 },
        transitions: [
          { from: 'al_dia', to: 'al_dia', people: 1 },
          { from: 'al_dia', to: 't1', people: 2 },
          { from: 'al_dia', to: 't2', people: 1 },
          { from: 't3', to: 'al_dia', people: 1 },
          { from: 't3', to: 't3', people: 1 },
          { from: 'nuevo', to: 'al_dia', people: 3 },
          { from: 'raro', to: 't1', people: 9 },
        ],
        cure: {
          t3: { from_people: 2, cured: 1, pct: 50 },
          t1: { from_people: 0, cured: 0, pct: null },
        },
      },
    ],
  })

  comprueba(
    flujo.cortes.gracia === 3 && flujo.cortes.expulsion === 60,
    'los cortes salen de la respuesta, no de números escritos aquí',
  )
  const semana = flujo.semanas[0]
  comprueba(semana.pasos.length === 6, 'un origen desconocido se descarta', String(semana.pasos.length))
  comprueba(semana.deudaVencida.t2 === 15, 'la deuda por tramo se lee', String(semana.deudaVencida.t2))
  comprueba(semana.cura.t1.pct === null, 'una cura sin nadie es «sin dato», no 0 %')
  comprueba(semana.cura.t4.estaban === 0 && semana.cura.t4.pct === null, 'un tramo que no viene es cero pacientes y sin porcentaje')

  const matriz = matrizDeFlujo(semana)
  comprueba(
    matriz.map((f) => f.desde).join(',') === 'al_dia,t3,nuevo',
    'la matriz solo trae los orígenes con gente, del mejor al peor y los nuevos al final',
    matriz.map((f) => f.desde).join(','),
  )
  const alDia = matriz.find((f) => f.desde === 'al_dia')
  comprueba(
    alDia?.hacia.t1 === 2 && alDia.hacia.t5 === 0 && alDia.total === 4,
    'cada celda cae en su columna y lo que falta vale cero',
  )

  comprueba(sentidoDelPaso('t3', 'al_dia') === 'mejora', 't3 → al día es mejorar')
  comprueba(sentidoDelPaso('t1', 't4') === 'empeora', 't1 → t4 es empeorar')
  comprueba(sentidoDelPaso('t2', 't2') === 'igual', 'quedarse es igual')
  comprueba(sentidoDelPaso('nuevo', 't1') === 'entra', 'un nuevo entra, no mejora ni empeora')

  const r = resumenDelFlujo(semana)
  comprueba(
    r.empeoran === 3 && r.mejoran === 1 && r.curados === 1 && r.estabanVencidos === 2,
    'el resumen cuenta a quien empeora, mejora y se cura',
    JSON.stringify(r),
  )
}

console.log('\n── La mora de hoy por tramo ─────────────────────────────────')
{
  const d = deudaPorTramo(
    [
      { diasDeAtraso: 0, vencido: 0 },
      { diasDeAtraso: 2, vencido: 10 },
      { diasDeAtraso: 3, vencido: 5 },
      { diasDeAtraso: 4, vencido: 7 },
      { diasDeAtraso: 30, vencido: 20 },
      { diasDeAtraso: 61, vencido: 50 },
      { diasDeAtraso: 5, vencido: 0 },
    ],
    CORTES,
  )
  comprueba(d.t1.personas === 2 && d.t1.vencido === 15, 'el día de la gracia sigue en t1')
  comprueba(d.t2.personas === 1, 'el día siguiente a la gracia ya es t2 (y sin deuda no cuenta)')
  comprueba(d.t4.vencido === 20, 'el día de la baja ya es t4')
  comprueba(d.t5.vencido === 50, 'pasada la expulsión es t5')
  comprueba(d.t3.personas === 0, 'nadie inventado en un tramo vacío')
}

console.log('\n── Las cosechas ─────────────────────────────────────────────')
{
  comprueba(rotuloDeMes('2026-09') === 'sep 2026', 'el mes se lee en castellano', rotuloDeMes('2026-09'))
  comprueba(
    JSON.stringify(rangoDelMes('2026-02')) === '{"desde":"2026-02-01","hasta":"2026-02-28"}' &&
      rangoDelMes('2026-12').hasta === '2026-12-31',
    'el rango de un mes acaba en su último día, también en diciembre',
  )

  const viejas = leerCosechas({
    business_date: '2026-09-24',
    months: 6,
    season_days: 74,
    rows: [{ month: '2026-08', charge_count: 1, financed_usd: 7.9, overdue_pct: 50, matured: false }],
  })
  comprueba(
    viejas.filas[0].financiado === null && viejas.filas[0].impagoPct === null,
    'sin los campos en financiamiento, el monto es «sin dato» y no el payable de siempre',
  )
  const nuevas = leerCosechas({
    business_date: '2026-09-24',
    months: 6,
    season_days: 74,
    rows: [
      {
        month: '2026-08',
        charge_count: 1,
        financed_volume_usd: 7.5,
        written_off_financed_pct: 0,
        overdue_pct: 50,
        matured: false,
      },
    ],
  })
  comprueba(nuevas.filas[0].financiado === 7.5, 'el financiado es el financiamiento sin fee')
  comprueba(nuevas.filas[0].impagoPct === 0, 'un 0 % que la base manda es un 0 %')

  const sinVencido = leerCosechas({
    rows: [
      { month: '2026-09', billed_debt_usd: 52.8, overdue_pct: null, matured: false },
      { month: '2026-10', overdue_pct: null, matured: false },
    ],
  })
  comprueba(
    sinVencido.filas[0].moraPct === 0 && sinVencido.filas[1].moraPct === null,
    'una mora nula con deuda detrás es un 0 %; sin deuda, «sin dato»',
    JSON.stringify(sinVencido.filas.map((f) => f.moraPct)),
  )

  const curvas = leerCurvas({
    business_date: '2026-09-24',
    rows: [
      { month: '2026-09', financed_usd: 44, charge_count: 7, last_day: '2026-09-24', curve: [] },
      {
        month: '2026-08',
        financed_usd: 7.5,
        charge_count: 1,
        last_day: '2026-08-28',
        curve: [
          { week: 1, reached_financed_usd: 7.5, overdue_pct: 0, written_off_pct: 0, complete: true },
          { week: 2, reached_financed_usd: 7.5, overdue_pct: 0, written_off_pct: 0, complete: true },
          { week: 3, reached_financed_usd: 7.5, overdue_pct: 50, written_off_pct: 0, complete: true },
          { week: 4, reached_financed_usd: 3, overdue_pct: 80, written_off_pct: 0, complete: false },
        ],
      },
    ],
  })
  const { series, points, enCurso } = seriesDeCurvas(curvas, 'vencido', { diasDeTemporada: 74 })
  comprueba(series.length === 1, 'una cosecha sin ninguna semana entera no se dibuja', String(series.length))
  comprueba(points.length === 3, 'el eje llega hasta la última semana entera', String(points.length))
  comprueba(
    points.map((p) => p.values[0]).join(',') === '0,0,50',
    'solo entran los puntos completos',
    points.map((p) => p.values[0]).join(','),
  )
  comprueba(enCurso.includes('2026-08') && series[0].label.includes('en curso'), 'una cosecha que no ha recorrido la temporada va «en curso»')
  comprueba(
    !cosechaEnCurso(curvas.cosechas[1], '2026-12-01', 74),
    'pasada la temporada ya no está en curso',
  )
}

console.log('\n── Primera cuota, cupo y clínicas ────────────────────────────')
{
  const fpd = leerPrimeraCuota(
    {
      business_date: '2026-09-24',
      from: '2026-04-01',
      months: 6,
      dim: 'grupo',
      grace_days: 3,
      late_days: 30,
      level_basis: null,
      total: { matured_count: 2, defaulted_count: 2, defaulted_pct: 100, defaulted_financed_usd: 3.75, in_grace_count: 7 },
      rows: [{ key: '1', label: 'Un paciente', matured_count: 0, defaulted_pct: null, in_grace_count: 7 }],
    },
    'grupo',
  )
  comprueba(fpd.filas[0].impagoPct === null, 'sin cuotas maduras el porcentaje es «sin dato»')
  comprueba(fpd.total.impagasMonto === 3.75 && fpd.baseDelNivel === null, 'el total y la base del nivel se leen')
  comprueba(fpd.cuota === 1, 'sin la clave cuota, la base juzgó la 1 (Inicio la llama así)')

  // La cuota 2: la misma forma, y la otra cuota se lee fila a fila por su clave.
  const fpd2 = leerPrimeraCuota(
    {
      cuota: 2,
      dim: 'grupo',
      total: { matured_count: 3, defaulted_count: 1, defaulted_pct: 33.3 },
      rows: [
        { key: '2', label: 'Dos pacientes', matured_count: 3, defaulted_pct: 33.3 },
        { key: '1', label: 'Un paciente', matured_count: 0, defaulted_pct: null },
      ],
    },
    'grupo',
  )
  comprueba(fpd2.cuota === 2 && fpd2.total.impagoPct === 33.3, 'la cuota 2 se lee igual que la 1')
  comprueba(otraCuota(1) === 2 && otraCuota(2) === 1, 'la otra cuota es la que no se mira')
  comprueba(filaDeLaMismaClave(fpd2, '2')?.impagoPct === 33.3, 'la fila de la otra cuota con la misma clave')
  comprueba(
    filaDeLaMismaClave(fpd2, '5+') === null && filaDeLaMismaClave(undefined, '2') === null,
    'sin esa clave, o sin leer todavía, no hay fila (ni un cero)',
  )

  // De quien pagó la cuota 1, qué parte no paga la 2 (`previous_paid`).
  const tras = leerPrimeraCuota(
    {
      cuota: 2,
      dim: 'semana',
      total: {
        matured_count: 290,
        defaulted_count: 58,
        defaulted_pct: 20,
        previous_paid: {
          matured_count: 250,
          defaulted_count: 18,
          defaulted_pct: 7.2,
          matured_financed_usd: 1842.77,
          defaulted_financed_usd: 130.12,
          matured_30_count: 98,
          defaulted_30_count: 1,
          defaulted_30_pct: 1,
        },
      },
      rows: [
        { key: '2026-09-07', matured_count: 4, previous_paid: { matured_count: 0, defaulted_count: 0, defaulted_pct: null } },
        { key: '2026-08-31', matured_count: 9, previous_paid: null },
      ],
    },
    'semana',
  )
  const t = tras.total.trasPagarLaAnterior
  comprueba(
    t !== null && t.maduras === 250 && t.impagas === 18 && t.impagoPct === 7.2 && t.impagasMonto === 130.12,
    'la cuota 2 de quien pagó la 1 se lee del total',
    JSON.stringify(t),
  )
  comprueba(
    tras.filas[0].trasPagarLaAnterior?.impagoPct === null && tras.filas[0].trasPagarLaAnterior.maduras === 0,
    'una semana sin nadie que pagara la 1 es «sin dato», no un 0 %',
  )
  comprueba(tras.filas[1].trasPagarLaAnterior === null, 'sin la clave, no hay cifra (ni un cero)')
  comprueba(fpd.total.trasPagarLaAnterior === null, 'la cuota 1 no tiene anterior')
  comprueba(impagoDeLaCuota2(tras, undefined) === tras, 'mirando la 2, la cifra sale de ella')
  comprueba(
    impagoDeLaCuota2({ ...fpd, dimension: 'semana' }, tras) === tras,
    'mirando la 1, sale de la otra si es la 2 y con la misma dimensión',
  )
  comprueba(
    impagoDeLaCuota2(fpd, tras) === undefined && impagoDeLaCuota2(fpd, undefined) === undefined,
    'con otra dimensión, o sin leer todavía, no hay cifra',
  )

  const uso = leerUsoDelCupo({
    business_date: '2026-09-24',
    levels: [
      {
        level: 1,
        label: 'Nivel 1',
        limit_usd: 30,
        user_count: 2,
        used_financed_usd: 24.74,
        usage_pct: 41.2,
        buckets: [
          { key: '1-25', count: 1 },
          { key: '51-75', count: 1 },
          { key: 'otro', count: 5 },
        ],
      },
    ],
    outside_levels: { user_count: 0 },
    total: { usage_pct: null },
  })
  comprueba(
    uso.niveles[0].tramos['1-25'] === 1 && uso.niveles[0].tramos['100'] === 0,
    'los tramos de uso se leen y los que faltan son cero',
  )
  comprueba(uso.total.usoPct === null, 'un uso sin pacientes es «sin dato»')

  const locales = leerLocalesPorVolumen([
    { merchant_id: 'a', merchant_name: 'Chico', charge_count: 1, financed_volume_usd: 5 },
    { merchant_id: 'b', merchant_name: 'Grande', charge_count: 4, financed_volume_usd: 50, overdue_debt_pct: null },
  ])
  comprueba(locales[0].nombre === 'Grande', 'las clínicas se ordenan por financiamiento sin fee')
  comprueba(locales[0].moraPct === null, 'una mora sin deuda es «sin dato»')
}

console.log('\n── El volumen de la ventana ─────────────────────────────────')
{
  // La forma de admin_overview en dev (CONTRATOS-D3 §1): 63,78 lleva el service fee.
  const volumen = {
    financedUsd: 63.78,
    previousUsd: 0,
    chargeCount: 8,
    activeUsers: 1,
    avgTicketUsd: 7.97,
    financedVolumeUsd: 51.5,
    previousFinancedVolumeUsd: 0,
    financedChangePct: null,
    avgTicketFinancedUsd: 6.44,
    activePeople: 2,
  }
  const v = volumenDeLaVentana({ businessDate: '2026-09-24', windowDays: 30, volume: volumen })
  comprueba(v.financiado === 51.5 && v.ticket === 6.44, 'el financiado y el ticket van sin el service fee', JSON.stringify(v))
  comprueba(v.personas === 2, 'los pacientes salen de las cuotas, no de quien abrió el financiamiento', String(v.personas))
  comprueba(
    v.desde === '2026-08-26' && v.hasta === '2026-09-24',
    'la ventana son 30 días operativos que terminan hoy',
    `${v.desde} a ${v.hasta}`,
  )
  const sin = volumenDeLaVentana({
    businessDate: '2026-09-24',
    windowDays: 7,
    volume: { ...volumen, chargeCount: 0, avgTicketFinancedUsd: null },
  })
  comprueba(sin.ticket === null, 'sin financiamientos no hay ticket')
  comprueba(sin.desde === '2026-09-18', 'una semana empieza seis días antes', sin.desde)
}

console.log('\n── Las alertas ──────────────────────────────────────────────')
{
  const a = leerAlertas({
    business_date: '2026-09-24',
    window_days: 90,
    counts: { consumo_sobre_cupo: { total: 1, unreviewed: 1, unreviewed_high: 1 } },
    total: 3,
    truncated: false,
    rows: [
      {
        alert_key: 'sobre_cupo:u1:c1',
        kind: 'consumo_sobre_cupo',
        severity: 'alta',
        user_id: 'u1',
        full_name: 'JAVIER',
        user_status: 'active',
        detected_at: '2026-09-25T02:47:48Z',
        detail: {
          charge_id: 'c1',
          order_number: 1209,
          business_date: '2026-09-24',
          merchant_name: 'Bar Nocturno',
          financed_usd: 6,
          used_usd: 28,
          limit_usd: 30,
          level: 1,
          reasons: ['sobre_cupo'],
        },
        reviewed: false,
      },
      {
        alert_key: 'relacionada:u2:u1',
        kind: 'cuenta_relacionada',
        severity: 'alta',
        user_id: 'u2',
        detail: { other_user_id: 'u1', other_name: 'JAVIER', reasons: ['cedula', 'dispositivo', 'otra'] },
        reviewed: true,
      },
      { alert_key: 'x', kind: 'desconocida', severity: 'alta', detail: {} },
    ],
  })
  comprueba(a.filas.length === 2, 'un tipo que el panel no conoce no rompe la lista')
  comprueba(a.recuentos.cuenta_relacionada.total === 0, 'un recuento que no viene es cero')
  const cupo = a.filas[0]
  comprueba(
    cupo.detalle.tipo === 'consumo_sobre_cupo' &&
      cupo.detalle.sobreCupo &&
      !cupo.detalle.enMora &&
      cupo.detalle.ocupado === 28,
    'el detalle se lee por su tipo',
  )
  comprueba(
    describirAlerta(cupo.detalle) ===
      'Se financió $6,00 (sin fee) en Bar Nocturno el 24/09/26 con $28,00 ya ocupados de un cupo de $30,00.',
    'la alerta se describe en una frase',
    describirAlerta(cupo.detalle),
  )
  comprueba(
    a.recuentos.consumo_sobre_cupo.pendientesAltas === 1,
    'el recuento del tipo nuevo se lee',
  )
  const rel = a.filas[1]
  comprueba(
    describirAlerta(rel.detalle) === 'Comparte la misma cédula y el mismo teléfono con otra cuenta.',
    'los motivos desconocidos se descartan y el resto se enumera',
    describirAlerta(rel.detalle),
  )
  comprueba(filtrarAlertas(a.filas, { estado: 'pendientes' }).length === 1, 'pendientes deja fuera las revisadas')
  comprueba(
    filtrarAlertas(a.filas, { estado: 'todas', gravedad: 'alta' }).length === 2 &&
      filtrarAlertas(a.filas, { estado: 'todas', gravedad: 'media' }).length === 0,
    'la gravedad filtra',
  )
}

console.log('\n── Las alertas de Helios (H10) ──────────────────────────────')
{
  const a = leerAlertas({
    counts: { rafaga_de_altas: { total: 1, unreviewed: 1, unreviewed_high: 1 } },
    rows: [
      {
        alert_key: 'rafaga:m1:2026-10-05',
        kind: 'rafaga_de_altas',
        severity: 'alta',
        subject_type: 'clinica',
        subject_id: 'm1',
        subject_name: 'Clínica Norte',
        first_seen_at: '2026-10-05T15:00:00Z',
        detail: { charge_count: 14, threshold: 10, business_date: '2026-10-05' },
        reviewed: false,
      },
      {
        alert_key: 'tel:u1',
        kind: 'telefono_repetido',
        subject_type: 'paciente',
        subject_id: 'u1',
        subject_name: 'José Pérez',
        detail: { phone_e164: '+584141234567', patient_count: 3 },
      },
      {
        alert_key: 'sec:s1',
        kind: 'secretaria_concentrada',
        severity: 'media',
        subject_type: 'personal',
        subject_id: 's1',
        subject_name: 'Carla',
        detail: { merchant_id: 'm1', merchant_name: 'Clínica Norte', share_pct: 91.4 },
      },
      { alert_key: 'x', kind: 'consultas_de_cedula_excesivas', subject_type: 'personal', subject_id: 's2', detail: {} },
    ],
  })
  comprueba(a.filas.length === 4, 'los tipos nuevos se leen')
  const [rafaga, tel, sec, cedulas] = a.filas
  comprueba(rafaga.sujeto.tipo === 'clinica' && rafaga.personaId === null, 'una de clínica no tiene paciente')
  comprueba(rafaga.detectadaEn === '2026-10-05T15:00:00Z', 'detectada: first_seen_at')
  comprueba(
    describirAlerta(rafaga.detalle) === 'Registró 14 financiamientos el 05/10/26; el umbral es 10.',
    'la ráfaga se cuenta',
    describirAlerta(rafaga.detalle),
  )
  comprueba(tel.gravedad === 'media', 'sin gravedad, la de su tipo')
  comprueba(tel.personaId === 'u1', 'una de paciente enlaza al paciente')
  comprueba(
    describirAlerta(tel.detalle).includes('está en 3 pacientes'),
    'el teléfono repetido dice en cuántos',
    describirAlerta(tel.detalle),
  )
  comprueba(
    describirAlerta(sec.detalle) === 'Registró el 91 % de los financiamientos de la semana de Clínica Norte.',
    'la concentración, en porcentaje',
    describirAlerta(sec.detalle),
  )
  comprueba(
    describirAlerta(cedulas.detalle) === 'Hizo consultas de cédula.',
    'sin detalle, sin cifras inventadas',
    describirAlerta(cedulas.detalle),
  )
  comprueba(
    alertasDeLaClinica(a.filas, 'm1').map((x) => x.clave).join() === 'rafaga:m1:2026-10-05,sec:s1',
    'las de una clínica: suyas y de su personal',
  )
  comprueba(a.recuentos.rafaga_de_altas.pendientesAltas === 1, 'el recuento de un tipo nuevo')
}


console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
