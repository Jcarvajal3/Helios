/**
 * Pruebas de «Hoy en cifras» y de la tira de la charla de Inicio.
 *
 *   npx tsx src/components/admin/inicio/cifras.test.ts
 *
 * Lo que se vigila: que cada tarjeta enseñe su pastilla solo cuando toca (la
 * mora siempre, con color solo al cruzar el umbral), que el medidor del pago
 * a clínicas no se salga ni mienta con la caja a cero, que la semana en barras
 * distinga un día sin consumos de uno que no ha llegado, y que la tira de la
 * charla diga lo mismo que las tarjetas, sin ceros en lugar de fallos.
 */
import { pastillasDeLaCharla } from './charla'
import type { PastillaDeLaCharla } from './charla'
import {
  barrasDeLaSemana,
  desgloseQueSuma,
  deudaVencida,
  diaDelCierre,
  globoDeDeudaVencida,
  pieDeDeudaVencida,
  impagoPrimeraCuota,
  medidorDelCierre,
  porcentajeDeUmbral,
  semanaCorta,
  senalDelCierre,
} from './cifras'
import type { FilaPrimeraCuota } from '@/features/admin/riesgo/credito'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const MORA = { alerta: 7, critico: 15 }
const IMPAGO = { alerta: 5, critico: 8 }

function mes(clave: string, maduras: number, impagas: number, enGracia: number): FilaPrimeraCuota {
  return {
    clave,
    rotulo: clave,
    maduras,
    impagas,
    impagoPct: maduras > 0 ? (impagas / maduras) * 100 : null,
    madurasMonto: 0,
    impagasMonto: 0,
    maduras30: 0,
    impagas30: 0,
    impago30Pct: null,
    impagas30Monto: 0,
    enGracia,
    trasPagarLaAnterior: null,
  }
}

console.log('── Cobranza ─────────────────────────────────────────────────')
{
  comprueba(porcentajeDeUmbral(7) === '7 %' && porcentajeDeUmbral(7.5) === '7,5 %', 'el umbral, sin decimales de más')

  const d = deudaVencida({ overdueDebtUsd: 2.39, openDebtUsd: 30.65, overduePct: 7.8 }, MORA)
  comprueba(d.vencido === 2.39 && d.porCobrar === 30.65, 'vencido y deuda viva, de la misma fila')
  comprueba(d.senal?.texto === 'Mora 7,8 %' && d.senal.tone === 'warning', 'pasada la alerta, la mora en ámbar', JSON.stringify(d.senal))

  const baja = deudaVencida({ overdueDebtUsd: 1, openDebtUsd: 100, overduePct: 1 }, MORA)
  comprueba(baja.senal?.texto === 'Mora 1,0 %' && baja.senal.tone === 'neutral', 'por debajo, la tasa se ve igual, sin color')

  const alta = deudaVencida({ overdueDebtUsd: 20, openDebtUsd: 100, overduePct: 20 }, MORA)
  comprueba(alta.senal?.tone === 'error', 'pasado el crítico, en rojo')

  const sinDeuda = deudaVencida({ overdueDebtUsd: 0, openDebtUsd: 0, overduePct: null }, MORA)
  comprueba(sinDeuda.senal === undefined, 'sin deuda viva no hay tasa: nada de «0 %»')

  const sinUmbral = deudaVencida({ overdueDebtUsd: 20, openDebtUsd: 100, overduePct: 20 }, null)
  comprueba(sinUmbral.senal?.tone === 'neutral', 'sin umbrales leídos, ningún color inventado')

  // El desglose: consumo + service fee, solo si la base lo manda y suma.
  const conDesglose = deudaVencida(
    {
      overdueDebtUsd: 777.73,
      overdueFinancedUsd: 631.17,
      overdueFeeUsd: 146.56,
      openDebtUsd: 2715.61,
      openFinancedUsd: 2204.17,
      openFeeUsd: 511.44,
      overduePct: 28.64,
    },
    MORA,
  )
  comprueba(
    conDesglose.desgloseVencido?.financedUsd === 631.17 && conDesglose.desgloseVencido.feeUsd === 146.56,
    'lo vencido trae sus dos partes',
  )
  comprueba(conDesglose.desglosePorCobrar?.feeUsd === 511.44, 'lo que queda por cobrar, también')
  comprueba(d.desgloseVencido === null && d.desglosePorCobrar === null, 'sin las claves en la base, no se inventa')
  comprueba(desgloseQueSuma(10, 2, 13) === null, 'un desglose que no suma la cifra no se enseña')
  comprueba(desgloseQueSuma(10, 2.004, 12) !== null, 'a un céntimo, sí')

  const pie = pieDeDeudaVencida(conDesglose, 12)
  comprueba(pie === 'financiamiento $631,17 · fee $146,56 · 12 pacientes', 'el pie: las dos partes de lo vencido y los pacientes', String(pie))
  comprueba(!pie?.includes('2.715'), 'el pie no lleva lo que se debe en total sin sus partes', String(pie))
  comprueba(pieDeDeudaVencida(d, null) === null, 'sin desglose ni gente, no hay pie')
  comprueba(pieDeDeudaVencida(d, 1) === '1 paciente', 'sin desglose, los pacientes solos')

  const globo = globoDeDeudaVencida(conDesglose, 'var(--area)')
  comprueba(
    globo.filas.length === 2 &&
      globo.filas[0].valor === '$777,73' &&
      globo.filas[0].rotulo === 'vencido · financiamiento $631,17 · fee $146,56' &&
      globo.filas[1].rotulo === 'vencido + por vencer · financiamiento $2.204,17 · fee $511,44',
    'el globo: lo vencido y lo que queda por cobrar, cada uno con sus partes',
    JSON.stringify(globo.filas.map((f) => [f.valor, f.rotulo])),
  )
}

console.log('\n── Caja ─────────────────────────────────────────────────────')
{
  comprueba(senalDelCierre('cubre').tone === 'success' && senalDelCierre('cubre').texto === 'Cubre', 'cubre, en verde')
  comprueba(senalDelCierre('en_camino').tone === 'neutral', 'en camino no es un aviso')
  comprueba(senalDelCierre('urgente').tone === 'error' && senalDelCierre('urgente').texto === 'No cubre', 'no cubre, en rojo')

  comprueba(diaDelCierre('2026-09-28') === 'lunes 28', 'el día del cierre con su nombre', diaDelCierre('2026-09-28'))

  const normal = medidorDelCierre(8.61, 35.13)
  comprueba(normal.valor === 8.61 && normal.max === 35.13, 'lo que sale, sobre la caja')
  const deMas = medidorDelCierre(50, 35)
  comprueba(deMas.valor === deMas.max, 'si sale más de lo que hay, la barra se llena y no se sale')
  const sinCaja = medidorDelCierre(10, 0)
  comprueba(sinCaja.valor === sinCaja.max && sinCaja.max > 0, 'con la caja a cero, llena: todo lo que sale falta')
  comprueba(medidorDelCierre(0, 35).valor === 0, 'si no sale nada, vacía')
}

console.log('\n── Riesgo ───────────────────────────────────────────────────')
{
  const filas = [mes('2026-09', 0, 0, 7), mes('2026-08', 2, 2, 0), mes('2026-07', 10, 1, 0)]
  const r = impagoPrimeraCuota(filas, IMPAGO)
  comprueba(r.mes?.clave === '2026-08', 'el último mes maduro, no el que está a medias')
  comprueba(r.pct === 100 && r.senal?.texto === 'Crítico · desde 8 %', 'con su pastilla de umbral', JSON.stringify(r.senal))

  const nada = impagoPrimeraCuota([mes('2026-09', 0, 0, 7)], IMPAGO)
  comprueba(nada.mes === null && nada.pct === null && nada.senal === undefined, 'sin mes maduro, ni cifra ni pastilla')
}

console.log('\n── Gerencia ─────────────────────────────────────────────────')
{
  const serie = [
    { businessDate: '2026-09-21', chargeCount: 0 },
    { businessDate: '2026-09-22', chargeCount: 3 },
    { businessDate: '2026-09-24', chargeCount: 3 },
    { businessDate: '2026-09-25', chargeCount: 1 },
  ]
  const barras = barrasDeLaSemana('2026-09-21', '2026-09-25', serie)
  comprueba(barras.map((b) => b.rotulo).join('') === 'LMXJVSD', 'de lunes a domingo')
  comprueba(barras[2]?.titulo === 'miércoles 23', 'el globo dice el día entero', String(barras[2]?.titulo))
  comprueba(barras[2]?.valor === 0, 'un día pasado sin fila es un cero, no un hueco')
  comprueba(barras[5]?.valor === null && barras[6]?.valor === null, 'el sábado y el domingo todavía no llegan')
  comprueba(barras[4]?.destacado === true && barras.filter((b) => b.destacado).length === 1, 'solo hoy va destacado')
  comprueba(
    barras.reduce((s, b) => s + (b.valor ?? 0), 0) === 7,
    'las barras suman los financiamientos de la semana',
  )

  comprueba(semanaCorta('2026-09-21') === 'Semana del 21 al 27 sep', 'una semana dentro del mes', semanaCorta('2026-09-21'))
  comprueba(semanaCorta('2026-09-28') === 'Semana del 28 sep al 4 oct', 'una que cambia de mes', semanaCorta('2026-09-28'))
}

console.log('\n── La tira de la charla ─────────────────────────────────────')
{
  const textos = (ps: PastillaDeLaCharla[]) => ps.map((p) => `${p.texto} [${p.tono}]`).join(' · ')

  const nada = pastillasDeLaCharla({
    pendiente: { estado: 'cargando' },
    mora: { estado: 'cargando' },
    cierre: { estado: 'cargando' },
    impago: { estado: 'cargando' },
  })
  comprueba(nada.length === 0, 'lo que todavía carga no se pinta')

  const todo = pastillasDeLaCharla({
    pendiente: { estado: 'con-trabajo', tarjetas: [], total: 4, pendientes: 4, principal: null, urgencia: 'error' },
    mora: { estado: 'listo', datos: { senal: { tone: 'warning', texto: 'Mora 7,8 %' } } },
    cierre: { estado: 'listo', datos: { veredicto: 'cubre' } },
    impago: { estado: 'listo', datos: { pct: 100, senal: { tone: 'error', texto: 'Crítico · desde 8 %' } } },
  })
  comprueba(
    textos(todo) === '4 pendientes [error] · Mora 7,8 % [warning] · Pago de hoy: cubre [success] · Impago cuota 1 100,0 % [error]',
    'lo pendiente y las tres cifras, en el orden de la pantalla',
    textos(todo),
  )
  comprueba(todo[0]?.destino === null, 'lo pendiente lleva de vuelta a Inicio')
  comprueba(todo[1]?.destino?.to === '/admin/cobranza', 'la mora lleva a Cobranza')
  comprueba(todo[2]?.destino?.to === '/admin/pagos-clinicas', 'el cierre, a Pagos a clínicas')
  comprueba(
    todo[3]?.destino?.to === '/admin/metricas' &&
      JSON.stringify(todo[3].destino.search) === JSON.stringify({ vista: 'cobros', sub: 'impago-por-cuota' }),
    'el impago, a Métricas › Cobros › Impago por cuota',
  )

  const uno = pastillasDeLaCharla({
    pendiente: { estado: 'con-trabajo', tarjetas: [], total: 1, pendientes: 1, principal: null, urgencia: 'warning' },
    mora: { estado: 'listo', datos: null },
    cierre: { estado: 'listo', datos: { veredicto: 'urgente' } },
    impago: { estado: 'listo', datos: { pct: null, senal: undefined } },
  })
  comprueba(
    textos(uno) === '1 pendiente [warning] · Pago de hoy: no cubre [error]',
    'en singular, y sin mora ni impago que dar no se inventa un 0 %',
    textos(uno),
  )

  const conFallos = pastillasDeLaCharla({
    pendiente: { estado: 'con-trabajo', tarjetas: [], total: 1, pendientes: 0, principal: null, urgencia: 'neutral' },
    mora: { estado: 'error', reintentar: () => undefined },
    cierre: { estado: 'listo', datos: { veredicto: 'en_camino' } },
    impago: { estado: 'error', reintentar: () => undefined },
  })
  comprueba(
    textos(conFallos) ===
      'Pendiente: no se pudo leer [neutral] · Mora: no se pudo leer [neutral] · Pago de hoy: en camino [neutral] · Impago cuota 1: no se pudo leer [neutral]',
    'lo que falló lo dice, nunca con un cero',
    textos(conFallos),
  )

  const alDia = pastillasDeLaCharla({
    pendiente: { estado: 'al-dia' },
    mora: { estado: 'cargando' },
    cierre: { estado: 'cargando' },
    impago: { estado: 'cargando' },
  })
  comprueba(textos(alDia) === 'Todo al día [success]', 'sin nada pendiente, «Todo al día» en verde')
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
