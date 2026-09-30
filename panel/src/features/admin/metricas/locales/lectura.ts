import { VALORES_ESTADO_LOCAL } from '@/features/admin/estados'
import { leerDesglose, leerHoyUsado, leerSemanaUsada } from '@/features/admin/metricas/lectura'
import type { Desglose } from '@/features/admin/metricas/lectura'
import { comoDia } from '@/lib/busqueda'
import { booleano, comoFila, comoLista, filaONula, numero, numeroONulo, numeros, texto, textoONulo } from '@/lib/json'

import type {
  ATiempoDeLaSemana,
  CohortesDeLocal,
  CuotaDeCohorte,
  FilaLocal,
  LocalesDeLaSemana,
  SerieDeLocal,
  Transferencia,
  VencidoDeSuGente,
} from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// La respuesta de `admin_metricas_locales`, leída campo a campo.
//
// Lo que falte llega vacío o nulo —nunca un cero inventado donde la base dijo
// «no hay dato»— y una respuesta rota no tira la pestaña. Aquí no nace
// ninguna cifra: solo se traducen los nombres.
//
// Puro: se prueba en `lectura.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

const SIN_DESGLOSE: Desglose = { payableUsd: 0, financedUsd: 0, feeUsd: 0 }

function desglose(v: unknown): Desglose {
  return leerDesglose(v) ?? SIN_DESGLOSE
}

function leerATiempo(v: unknown): ATiempoDeLaSemana {
  const a = comoFila(v)
  const juzgadas = numero(a.juzgadas)
  return {
    vencen: numero(a.vencen),
    juzgadas,
    aTiempo: numero(a.a_tiempo),
    // Sin juzgadas no hay porcentaje, aunque la base mandara algo.
    pct: juzgadas > 0 ? numeroONulo(a.pct) : null,
  }
}

function leerVencido(v: unknown): VencidoDeSuGente {
  const f = comoFila(v)
  return { ...desglose(f), cuotas: numero(f.cuotas), personas: numero(f.personas) }
}

function leerTransferencia(v: unknown): Transferencia {
  const t = comoFila(v)
  return {
    generadoUsd: numero(t.generado_usd),
    transferidoUsd: numero(t.transferido_usd),
    pendienteUsd: numero(t.pendiente_usd),
    previstoUsd: numero(t.previsto_usd),
    atrasadoUsd: numero(t.atrasado_usd),
  }
}

export function leerFilaLocal(v: unknown): FilaLocal {
  const l = comoFila(v)
  const mejor = filaONula(l.mejor_noche)
  const fechaMejor = mejor ? (comoDia(mejor.fecha) ?? null) : null
  const consumos = numero(l.consumos)

  return {
    merchantId: textoONulo(l.merchant_id),
    nombre: texto(l.nombre, 'Sin nombre'),
    estado: VALORES_ESTADO_LOCAL.find((e) => e === l.estado) ?? null,
    ciudad: textoONulo(l.ciudad),
    consumoUsd: numero(l.consumo_usd),
    consumos,
    ticketMedioUsd: consumos > 0 ? numeroONulo(l.ticket_medio_usd) : null,
    consumoAnteriorUsd: numero(l.consumo_anterior_usd),
    consumosAnteriores: numero(l.consumos_anteriores),
    personas: numero(l.personas),
    nuevas: numero(l.nuevas),
    noches: numero(l.noches),
    consumosEnGrupo: numero(l.consumos_en_grupo),
    mejorNoche: mejor && fechaMejor ? { fecha: fechaMejor, consumoUsd: numero(mejor.consumo_usd) } : null,
    partePct: numeroONulo(l.parte_pct),
    aTiempo: leerATiempo(l.a_tiempo),
    vencido: leerVencido(l.vencido),
    transferencia: leerTransferencia(l.transferencia),
  }
}

/**
 * Una lista de cifras semana a semana, con tantas como semanas. Si la base
 * mandara de menos, se completa con ceros por el principio (lo más viejo): la
 * semana elegida siempre es la última.
 */
function serie(v: unknown, n: number): number[] {
  const leidos = numeros(v).slice(-n)
  return [...Array.from({ length: n - leidos.length }, () => 0), ...leidos]
}

function leerSerie(v: unknown, n: number): SerieDeLocal {
  const s = comoFila(v)
  return {
    merchantId: texto(s.merchant_id),
    nombre: texto(s.nombre, 'Sin nombre'),
    primerConsumo: comoDia(s.primer_consumo) ?? null,
    consumoUsd: serie(s.consumo_usd, n),
    consumos: serie(s.consumos, n),
    personas: serie(s.personas, n),
    nuevas: serie(s.nuevas, n),
  }
}

function leerCuota(v: unknown): CuotaDeCohorte | null {
  const c = filaONula(v)
  if (!c) return null
  const juzgadas = numero(c.juzgadas)
  return {
    cuotas: numero(c.cuotas),
    juzgadas,
    aTiempoJuzgadas: numero(c.a_tiempo_juzgadas),
    pctATiempo: juzgadas > 0 ? numeroONulo(c.pct_a_tiempo) : null,
    aTiempo: numero(c.a_tiempo),
    tarde: numero(c.tarde),
    vencidas: numero(c.vencidas),
    porVencer: numero(c.por_vencer),
    perdidas: numero(c.perdidas),
    vencido: desglose(c.vencido),
  }
}

/** Las semanas de un local, alineadas con `semanas`: la que falte es «no vendió». */
function leerCohortes(v: unknown, semanas: ReadonlyArray<string>): CohortesDeLocal {
  const c = comoFila(v)
  const porSemana = new Map(
    comoLista(c.semanas).map((x) => {
      const s = comoFila(x)
      return [comoDia(s.semana) ?? '', s] as const
    }),
  )
  return {
    merchantId: texto(c.merchant_id),
    nombre: texto(c.nombre, 'Sin nombre'),
    semanas: semanas.map((semana) => {
      const s = porSemana.get(semana)
      return { semana, cuota1: leerCuota(s?.cuota_1), cuota2: leerCuota(s?.cuota_2) }
    }),
  }
}

function dias(v: unknown): string[] {
  return comoLista(v)
    .map((d) => comoDia(d))
    .filter((d): d is string => d !== undefined)
}

/** La respuesta entera. La semana y el «hoy» son los que usó la base. */
export function leerLocalesDeLaSemana(data: unknown): LocalesDeLaSemana {
  const r = comoFila(data)
  const anterior = comoFila(r.anterior)
  const cierre = comoFila(r.cierre)
  const series = comoFila(r.series)
  const cohortes = comoFila(r.cohortes)
  const semanasSerie = dias(series.semanas)
  const semanasCohorte = dias(cohortes.semanas)
  const hoy = leerHoyUsado(r.hoy) ?? ''
  const semana = leerSemanaUsada(r.semana) ?? { desde: '', hasta: '', enCurso: false }

  return {
    semana,
    hoy,
    hasta: comoDia(r.hasta) ?? semana.hasta,
    dias: numero(r.dias),
    anterior: {
      desde: comoDia(anterior.desde) ?? '',
      hasta: comoDia(anterior.hasta) ?? '',
      mismaAltura: booleano(anterior.misma_altura),
    },
    cierre: { lunes: comoDia(cierre.lunes) ?? '', pasado: booleano(cierre.pasado) },
    graciaDias: numero(r.gracia_dias),
    local: textoONulo(r.local),
    // Se reordena por consumo aunque la base ya lo mande así: el primero es
    // «el que más consumió» y no puede depender de un `order by`.
    locales: comoLista(r.locales)
      .map(leerFilaLocal)
      .sort((a, b) => b.consumoUsd - a.consumoUsd || a.nombre.localeCompare(b.nombre, 'es')),
    totales: leerFilaLocal(r.totales),
    series: {
      semanas: semanasSerie,
      locales: comoLista(series.locales).map((s) => leerSerie(s, semanasSerie.length)),
    },
    cohortes: {
      semanas: semanasCohorte,
      locales: comoLista(cohortes.locales).map((c) => leerCohortes(c, semanasCohorte)),
    },
  }
}
