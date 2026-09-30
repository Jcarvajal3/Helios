/**
 * Pruebas de la semana del Resumen, las metas, el semáforo de capital y las
 * flechas.
 *
 *   npx tsx src/features/admin/semana.test.ts
 *
 * Sin framework, como el resto. Lo que se rompe aquí no da error: un lunes
 * mal calculado enseña la semana de al lado con toda naturalidad, y un jueves
 * comparado con un miércoles parece una caída de ventas.
 */
import type { DayPoint } from './metrics'
import type { SemanaResumen } from './resumen'
import {
  aEstasAlturas,
  ayerFrenteASemanaPasada,
  diaDeLaSemana,
  domingoDe,
  elegirSemana,
  lunesDe,
  progresoDeMeta,
  referenciaDe,
  ritmoSemanal,
  semaforoDeCapital,
  semanasAPedir,
  semanasDeUnCiclo,
  semanasEntre,
  ventanaHasta,
} from './semana'
import { tendencia, tendenciaEnPuntos } from './tendencia'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function semana(weekStart: string, parcial: Partial<SemanaResumen> = {}): SemanaResumen {
  return {
    weekStart,
    weekEnd: domingoDe(weekStart),
    complete: true,
    daysElapsed: 7,
    financedUsd: 0,
    chargeCount: 0,
    serviceFeeUsd: 0,
    lateFeeUsd: 0,
    lateFeeCollectedUsd: 0,
    activeUsers: 0,
    merchantsWithSales: 0,
    newUsers: 0,
    firstTimeBuyers: 0,
    writtenOffFinancedUsd: 0,
    writtenOffDebtUsd: 0,
    openDebtUsd: 0,
    overdueDebtUsd: 0,
    overduePct: null,
    ...parcial,
  }
}

function dia(businessDate: string, financedUsd = 0): DayPoint {
  return {
    businessDate,
    financedUsd,
    chargeCount: 0,
    collectedUsd: 0,
    settledUsd: 0,
    serviceFeeUsd: 0,
    lateFeeUsd: 0,
    activeUsers: 0,
    merchantsWithSales: 0,
    newUsers: 0,
    firstTimeBuyers: 0,
    writtenOffFinancedUsd: 0,
  }
}

console.log('── El lunes de cada día ─────────────────────────────────────')
for (const [d, lunes] of [
  ['2026-09-21', '2026-09-21'],
  ['2026-09-25', '2026-09-21'],
  ['2026-09-27', '2026-09-21'],
  ['2026-09-28', '2026-09-28'],
  ['2027-01-01', '2026-12-28'],
  ['2028-03-01', '2028-02-28'],
] as const) {
  comprueba(lunesDe(d) === lunes, `${d} → ${lunes}`, lunesDe(d))
}
comprueba(domingoDe('2026-09-21') === '2026-09-27', 'el domingo cierra la semana')
comprueba(diaDeLaSemana('2026-09-24') === 'jueves', 'el 24-09-2026 es jueves', diaDeLaSemana('2026-09-24'))
comprueba(semanasEntre('2026-09-14', '2026-09-28') === 2, 'dos semanas de lunes a lunes')
comprueba(semanasEntre('2026-09-28', '2026-09-14') === -2, 'negativo al revés')

console.log('\n── Cuántas semanas se piden ─────────────────────────────────')
comprueba(semanasAPedir(undefined, '2026-09-21') === 13, 'la en curso pide trece')
comprueba(semanasAPedir('2026-09-14', '2026-09-21') === 13, 'una atrás no vuelve a pedir')
comprueba(semanasAPedir('2026-09-07', '2026-09-21') === 26, 'dos atrás piden veintiséis')
comprueba(semanasAPedir('2025-01-06', '2026-09-21') === 52, 'nunca más de cincuenta y dos')
comprueba(semanasAPedir('2026-10-05', '2026-09-21') === 13, 'una semana futura pide lo mínimo')

console.log('\n── Qué semana se enseña ─────────────────────────────────────')
{
  const rows = [
    semana('2026-09-07'),
    semana('2026-09-14'),
    semana('2026-09-21', { complete: false, daysElapsed: 4 }),
  ]
  const enCurso = elegirSemana(rows)
  comprueba(
    enCurso.tipo === 'semana' && enCurso.indice === 2 && enCurso.enCurso,
    'sin semana, la en curso y marcada',
  )
  const pasada = elegirSemana(rows, '2026-09-14')
  comprueba(pasada.tipo === 'semana' && !pasada.enCurso, 'una cerrada no va marcada')
  comprueba(elegirSemana(rows, '2026-09-28').tipo === 'futura', 'una que no ha empezado')
  comprueba(elegirSemana(rows, '2026-08-31').tipo === 'fuera', 'una más vieja que la respuesta')
  comprueba(elegirSemana([]).tipo === 'vacia', 'sin filas')
  comprueba(ventanaHasta(rows, 1, 12).length === 2, 'la ventana no inventa semanas antes de la primera')
  comprueba(ventanaHasta([1, 2, 3, 4, 5], 3, 2).join() === '3,4', 'la ventana acaba en la elegida')
}

console.log('\n── Contra qué se compara ────────────────────────────────────')
{
  const rows = [
    semana('2026-09-14', { financedUsd: 100, activeUsers: 9 }),
    semana('2026-09-21', { complete: false, daysElapsed: 3, financedUsd: 40, activeUsers: 3 }),
  ]
  const serie = [
    dia('2026-09-14', 10),
    dia('2026-09-15', 20),
    dia('2026-09-16', 5),
    dia('2026-09-17', 65),
    dia('2026-09-21', 10),
    dia('2026-09-22', 10),
    dia('2026-09-23', 20),
  ]
  comprueba(
    aEstasAlturas(serie, '2026-09-21', 3, 'financedUsd') === 35,
    'a estas alturas: lunes a miércoles de la anterior',
    String(aEstasAlturas(serie, '2026-09-21', 3, 'financedUsd')),
  )
  comprueba(
    aEstasAlturas(serie.slice(1), '2026-09-21', 3, 'financedUsd') === null,
    'si falta un día no se compara',
  )
  const enCurso = referenciaDe(rows, 1, 'financedUsd', serie)
  comprueba(
    enCurso?.cual === 'mismos-dias' && enCurso.valor === 35,
    'la semana en curso se mide contra los mismos días',
  )
  comprueba(
    referenciaDe(rows, 1, 'activeUsers', serie) === null,
    'los pacientes de una semana en curso no se comparan',
  )
  comprueba(
    referenciaDe([rows[0], semana('2026-09-21', { financedUsd: 1 })], 1, 'activeUsers', undefined)
      ?.valor === 9,
    'una cerrada se mide contra la anterior entera',
  )
  comprueba(referenciaDe(rows, 0, 'financedUsd', serie) === null, 'la primera no tiene anterior')
}

console.log('\n── El ritmo y el mismo día ──────────────────────────────────')
{
  const rows = [
    semana('2026-08-24', { financedUsd: 999 }),
    semana('2026-08-31', { financedUsd: 10 }),
    semana('2026-09-07', { financedUsd: 20 }),
    semana('2026-09-14', { financedUsd: 30 }),
    semana('2026-09-21', { financedUsd: 40, complete: false }),
  ]
  const ritmo = ritmoSemanal(rows, 3)
  comprueba(ritmo?.media === 20 && ritmo.semanas === 3, 'la media de las últimas cerradas, sin la en curso')
  comprueba(ritmoSemanal([semana('2026-09-21', { complete: false })]) === null, 'sin semanas cerradas no hay ritmo')

  const serie = Array.from({ length: 14 }, (_, i) =>
    dia(`2026-09-${String(11 + i).padStart(2, '0')}`, i),
  )
  const par = ayerFrenteASemanaPasada(serie)
  comprueba(
    par?.ayer.businessDate === '2026-09-23' && par.hace.businessDate === '2026-09-16',
    'ayer es el penúltimo y se compara con siete días antes',
  )
  comprueba(ayerFrenteASemanaPasada(serie.slice(-8)) === null, 'con menos de nueve días no hay par')
  comprueba(
    ayerFrenteASemanaPasada([...serie.slice(0, 5), ...serie.slice(6)]) === null,
    'con un día de menos no compara un jueves con un miércoles',
  )
}

console.log('\n── Metas ────────────────────────────────────────────────────')
comprueba(progresoDeMeta(50, 200, 'subir')?.pct === 25, 'una meta a la que se llega: 25 %')
comprueba(progresoDeMeta(250, 200, 'subir')?.cumplida === true, 'pasarla es cumplirla')
comprueba(progresoDeMeta(8, 5, 'bajar')?.cumplida === false, 'una mora por encima del techo no cumple')
comprueba(progresoDeMeta(8, 5, 'bajar')?.distancia === 3, 'y sobra la diferencia')
comprueba(progresoDeMeta(null, 5, 'bajar') === null, 'sin valor no hay progreso')
comprueba(progresoDeMeta(3, null, 'subir') === null, 'sin meta no hay progreso')

console.log('\n── Semáforo de capital ──────────────────────────────────────')
{
  const ciclo = semanasDeUnCiclo(7)
  comprueba(ciclo === 2, 'con cuotas cada siete días, un ciclo son dos semanas')
  comprueba(semanasDeUnCiclo(null) === null, 'sin intervalo no hay ciclo')

  const holgado = semaforoDeCapital({
    capital: 1000,
    consumoSinSaldar: 200,
    ritmo: 100,
    semanasDeCiclo: ciclo,
  })
  comprueba(holgado.comprometido === 200 && holgado.usadoPct === 20, 'comprometido y porcentaje')
  comprueba(holgado.semanas === 8 && holgado.tono === 'success', 'ocho semanas: verde')

  const justo = semaforoDeCapital({
    capital: 1000,
    consumoSinSaldar: 700,
    ritmo: 100,
    semanasDeCiclo: ciclo,
  })
  comprueba(justo.tono === 'warning', 'tres semanas, menos de dos ciclos: ámbar', justo.tono)

  const corto = semaforoDeCapital({
    capital: 1000,
    consumoSinSaldar: 900,
    ritmo: 100,
    semanasDeCiclo: ciclo,
  })
  comprueba(corto.tono === 'error', 'una semana, menos de un ciclo: rojo', corto.tono)

  const pasado = semaforoDeCapital({
    capital: 100,
    consumoSinSaldar: 110,
    ritmo: null,
    semanasDeCiclo: ciclo,
  })
  comprueba(pasado.semanas === 0 && pasado.tono === 'error', 'comprometido por encima del capital: rojo')

  const sinCiclo = semaforoDeCapital({
    capital: 1000,
    consumoSinSaldar: 0,
    ritmo: 10,
    semanasDeCiclo: null,
  })
  comprueba(sinCiclo.tono === 'neutral', 'sin el intervalo de cuotas no se inventa un color')
}

console.log('\n── Flechas ──────────────────────────────────────────────────')
comprueba(tendencia(0, 0) === undefined, 'de nada a nada no hay flecha')
comprueba(tendencia(5, 0)?.label === 'nuevo', 'de nada a algo es «nuevo»')
comprueba(tendencia(142, 141)?.direction === 'flat', 'menos del 1 % es «igual»')
comprueba(tendencia(135, 100)?.label === '35 % más', 'sube un 35 %', tendencia(135, 100)?.label)
comprueba(tendencia(50, 100)?.direction === 'down', 'baja')
comprueba(
  tendenciaEnPuntos(7.8, 5.7)?.label === '2,1 puntos más',
  'una tasa sube en puntos',
  tendenciaEnPuntos(7.8, 5.7)?.label,
)
comprueba(tendenciaEnPuntos(5, 6)?.label === '1,0 punto menos', 'un punto, en singular')
comprueba(tendenciaEnPuntos(7.8, null) === undefined, 'sin la anterior no hay flecha')
comprueba(tendenciaEnPuntos(7.8, 5)?.upIsGood === false, 'en una tasa, subir es malo')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
