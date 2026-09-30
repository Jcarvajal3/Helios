import { comoDia } from '@/lib/busqueda'
import { booleano, comoFila, comoLista, filaONula, numero, numeroONulo, textoONulo } from '@/lib/json'
import { leerDesglose, leerSemanaUsada } from '@/features/admin/metricas/lectura'
import type { Desglose } from '@/features/admin/metricas/lectura'
import type {
  CifrasDePeriodo,
  Comparacion,
  RespuestaSemanas,
  SemanaConCifras,
  TasaATiempo,
} from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// De la respuesta de `admin_metricas_semanas` (snake_case, `unknown`) a los
// tipos de `tipos.ts`. Aquí no se calcula nada: solo se traducen nombres.
//
// Lo que falta se queda en `null` cuando puede faltar de verdad (una tasa sin
// nada juzgado, una cifra que no se parte por local) y en 0 cuando la base lo
// manda siempre (un recuento, una suma con `coalesce`). Si falta lo que da
// sentido a todo —la semana, la lista de semanas—, es un fallo del contrato y
// se lanza: mejor «No se pudo leer» que una tabla de ceros.
//
// Puro: se prueba en `lectura.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

const CERO: Desglose = { payableUsd: 0, financedUsd: 0, feeUsd: 0 }

/** Un importe que se paga en cuotas y que la base manda siempre. */
function desglose(v: unknown): Desglose {
  return leerDesglose(v) ?? CERO
}

function tasa(v: unknown): TasaATiempo {
  const f = comoFila(v)
  return { juzgadas: numero(f.juzgadas), aTiempo: numero(f.a_tiempo), pct: numeroONulo(f.pct) }
}

/** Las cifras de un tramo (`metricas.semana_periodo`). */
export function leerCifras(v: unknown): CifrasDePeriodo {
  const f = comoFila(v)
  const consumo = comoFila(f.consumo)
  const ingreso = comoFila(f.ingreso)
  const cobro = comoFila(f.cobro)
  const riesgo = comoFila(f.riesgo)
  const gente = comoFila(f.gente)
  const caja = comoFila(f.caja)
  const vencian = comoFila(cobro.vencian)
  const vencido = comoFila(riesgo.vencido)
  const perdido = comoFila(riesgo.perdido)

  return {
    consumo: {
      consumoUsd: numero(consumo.financed_usd),
      consumos: numero(consumo.consumos),
      ticketMedioUsd: numeroONulo(consumo.ticket_medio_usd),
      personas: numero(consumo.personas),
      locales: numero(consumo.locales),
    },
    ingreso: {
      servicioUsd: numero(ingreso.servicio_usd),
      cargosPorAtrasoUsd: numero(ingreso.cargos_por_atraso_usd),
      cargosPorAtraso: numero(ingreso.cargos_por_atraso),
    },
    cobro: {
      vencian: { ...desglose(vencian), cuotas: numero(vencian.cuotas) },
      juzgadoHasta: comoDia(cobro.juzgado_hasta) ?? null,
      aTiempo: tasa(cobro.a_tiempo),
      cuota1: tasa(cobro.cuota_1),
      cuota2: tasa(cobro.cuota_2),
    },
    riesgo: {
      alCierreDe: comoDia(riesgo.al_cierre_de) ?? '',
      vencido: { ...desglose(vencido), cuotas: numero(vencido.cuotas), personas: numero(vencido.personas) },
      porVencer: desglose(riesgo.por_vencer),
      moraPct: numeroONulo(riesgo.mora_pct),
      perdido: { ...desglose(perdido), cuotas: numero(perdido.cuotas) },
    },
    gente: {
      registros: numeroONulo(gente.registros),
      verificados: numeroONulo(gente.verificados),
      primerConsumo: numero(gente.primer_consumo),
      solicitaron: numeroONulo(gente.solicitaron),
    },
    caja: {
      transferidoALocalesUsd: numero(caja.transferido_a_locales_usd),
      pagosALocales: numero(caja.pagos_a_locales),
      enCajaUsd: numeroONulo(caja.en_caja_usd),
    },
  }
}

function leerSemana(v: unknown): SemanaConCifras | null {
  const f = comoFila(v)
  const desde = comoDia(f.desde)
  const hasta = comoDia(f.hasta)
  if (!desde || !hasta) return null
  return {
    desde,
    hasta,
    hastaDato: comoDia(f.hasta_dato) ?? hasta,
    dias: numero(f.dias),
    enCurso: booleano(f.en_curso),
    cifras: leerCifras(f),
  }
}

function leerComparacion(v: unknown): Comparacion {
  const f = filaONula(v)
  const desde = f && comoDia(f.desde)
  const hasta = f && comoDia(f.hasta)
  if (!f || !desde || !hasta) {
    throw new Error('La respuesta de admin_metricas_semanas no trae la semana con la que comparar.')
  }
  return {
    desde,
    hasta,
    dias: numero(f.dias),
    mismaAltura: booleano(f.misma_altura),
    juzgadoHasta: comoDia(f.juzgado_hasta) ?? null,
    corte: textoONulo(f.corte),
    cifras: leerCifras(f),
  }
}

/** La respuesta entera. Lanza si no trae la semana o las semanas. */
export function leerRespuestaSemanas(crudo: unknown): RespuestaSemanas {
  const r = comoFila(crudo)
  const semana = leerSemanaUsada(r.semana)
  const hoy = comoDia(r.hoy)
  if (!semana || !hoy) {
    throw new Error('La respuesta de admin_metricas_semanas no trae la semana ni el día que usó.')
  }

  const semanas = comoLista(r.filas)
    .map(leerSemana)
    .filter((s): s is SemanaConCifras => s !== null)
  if (semanas.length === 0 || semanas.at(-1)?.desde !== semana.desde) {
    throw new Error('La respuesta de admin_metricas_semanas no trae la semana elegida.')
  }

  return {
    hoy,
    graciaDias: numero(r.gracia_dias),
    local: textoONulo(r.local),
    semana,
    semanas,
    comparacion: leerComparacion(r.comparacion),
  }
}
