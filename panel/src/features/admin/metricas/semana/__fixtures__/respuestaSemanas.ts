import type { Parametro, Parametros } from '@/features/admin/parametros'

// ═══════════════════════════════════════════════════════════════════════════
// Datos de prueba de la pestaña Semana: una respuesta de
// `admin_metricas_semanas` tal como llega de la base (snake_case), con las
// cifras de la maqueta, y unos parámetros con metas y umbrales.
//
// Solo lo importan los `*.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Las cifras de un tramo, como las escribe `metricas.semana_periodo`. */
export type PeriodoCrudo = {
  consumo: number
  consumos: number
  personas: number
  locales: number
  servicio: number
  cargos: number
  vencianFinanced: number
  vencianFee: number
  vencianCuotas: number
  juzgadas: number
  aTiempo: number
  juzgadas1: number
  aTiempo1: number
  juzgadas2: number
  aTiempo2: number
  vencidoFinanced: number
  vencidoFee: number
  vencidoCuotas: number
  porVencerFinanced: number
  porVencerFee: number
  mora: number | null
  perdidoFinanced: number
  perdidoFee: number
  perdidoCuotas: number
  registros: number | null
  verificados: number | null
  solicitaron: number | null
  primerConsumo: number
  transferido: number
  pagos: number
  caja: number | null
  alCierreDe: string
  juzgadoHasta: string | null
}

const VACIO: PeriodoCrudo = {
  consumo: 0,
  consumos: 0,
  personas: 0,
  locales: 0,
  servicio: 0,
  cargos: 0,
  vencianFinanced: 0,
  vencianFee: 0,
  vencianCuotas: 0,
  juzgadas: 0,
  aTiempo: 0,
  juzgadas1: 0,
  aTiempo1: 0,
  juzgadas2: 0,
  aTiempo2: 0,
  vencidoFinanced: 0,
  vencidoFee: 0,
  vencidoCuotas: 0,
  porVencerFinanced: 0,
  porVencerFee: 0,
  mora: null,
  perdidoFinanced: 0,
  perdidoFee: 0,
  perdidoCuotas: 0,
  registros: 0,
  verificados: 0,
  solicitaron: 0,
  primerConsumo: 0,
  transferido: 0,
  pagos: 0,
  caja: 0,
  alCierreDe: '2026-09-20',
  juzgadoHasta: null,
}

function pct(a: number, n: number): number | null {
  return n === 0 ? null : Math.round((10000 * a) / n) / 100
}

/** Un tramo en snake_case, con todo lo que no se diga a cero. */
export function periodoCrudo(p: Partial<PeriodoCrudo> = {}): Record<string, unknown> {
  const x = { ...VACIO, ...p }
  return {
    consumo: {
      financed_usd: x.consumo,
      consumos: x.consumos,
      ticket_medio_usd: x.consumos === 0 ? null : Math.round((100 * x.consumo) / x.consumos) / 100,
      personas: x.personas,
      locales: x.locales,
    },
    ingreso: { servicio_usd: x.servicio, cargos_por_atraso_usd: x.cargos, cargos_por_atraso: x.cargos > 0 ? 1 : 0 },
    cobro: {
      vencian: {
        payable_usd: x.vencianFinanced + x.vencianFee,
        financed_usd: x.vencianFinanced,
        fee_usd: x.vencianFee,
        cuotas: x.vencianCuotas,
      },
      juzgado_hasta: x.juzgadoHasta,
      a_tiempo: { juzgadas: x.juzgadas, a_tiempo: x.aTiempo, pct: pct(x.aTiempo, x.juzgadas) },
      cuota_1: { juzgadas: x.juzgadas1, a_tiempo: x.aTiempo1, pct: pct(x.aTiempo1, x.juzgadas1) },
      cuota_2: { juzgadas: x.juzgadas2, a_tiempo: x.aTiempo2, pct: pct(x.aTiempo2, x.juzgadas2) },
    },
    riesgo: {
      al_cierre_de: x.alCierreDe,
      vencido: {
        payable_usd: x.vencidoFinanced + x.vencidoFee,
        financed_usd: x.vencidoFinanced,
        fee_usd: x.vencidoFee,
        cuotas: x.vencidoCuotas,
        personas: x.vencidoCuotas,
      },
      por_vencer: {
        payable_usd: x.porVencerFinanced + x.porVencerFee,
        financed_usd: x.porVencerFinanced,
        fee_usd: x.porVencerFee,
      },
      mora_pct: x.mora,
      perdido: {
        payable_usd: x.perdidoFinanced + x.perdidoFee,
        financed_usd: x.perdidoFinanced,
        fee_usd: x.perdidoFee,
        cuotas: x.perdidoCuotas,
      },
    },
    gente: {
      solicitaron: x.solicitaron,
      registros: x.registros,
      verificados: x.verificados,
      primer_consumo: x.primerConsumo,
    },
    caja: { transferido_a_locales_usd: x.transferido, pagos_a_locales: x.pagos, en_caja_usd: x.caja },
  }
}

/** Una semana de la lista `filas`. */
export function semanaCruda(
  lunes: string,
  p: Partial<PeriodoCrudo> = {},
  { enCurso = false, hastaDato, dias = 7 }: { enCurso?: boolean; hastaDato?: string; dias?: number } = {},
): Record<string, unknown> {
  const domingo = sumar(lunes, 6)
  return {
    desde: lunes,
    hasta: domingo,
    hasta_dato: hastaDato ?? domingo,
    dias,
    en_curso: enCurso,
    ...periodoCrudo({ alCierreDe: hastaDato ?? domingo, ...p }),
  }
}

function sumar(dia: string, n: number): string {
  const [y = 0, m = 1, d = 1] = dia.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10)
}

// ── La semana de la maqueta ────────────────────────────────────────────────

/** La semana del 21 al 27 de septiembre, en curso el sábado 26: seis días. */
export const SEMANA_EN_CURSO: Partial<PeriodoCrudo> = {
  consumo: 912.4,
  consumos: 30,
  personas: 44,
  locales: 2,
  servicio: 182.48,
  cargos: 2,
  vencianFinanced: 862.8,
  vencianFee: 200.17,
  vencianCuotas: 60,
  juzgadas: 40,
  aTiempo: 32,
  juzgadas1: 20,
  aTiempo1: 17,
  juzgadas2: 20,
  aTiempo2: 15,
  vencidoFinanced: 146.72,
  vencidoFee: 34.04,
  vencidoCuotas: 9,
  porVencerFinanced: 1415,
  porVencerFee: 328.3,
  mora: 9.39,
  registros: 64,
  verificados: 64,
  solicitaron: 71,
  primerConsumo: 18,
  transferido: 400,
  pagos: 2,
  caja: 2611,
  juzgadoHasta: '2026-09-23',
}

/** Los mismos seis días de la semana anterior. */
export const ANTERIOR_A_LA_MISMA_ALTURA: Partial<PeriodoCrudo> = {
  consumo: 815,
  consumos: 27,
  personas: 38,
  locales: 2,
  servicio: 163,
  cargos: 6,
  vencianFinanced: 700,
  vencianFee: 162.4,
  vencianCuotas: 50,
  juzgadas: 36,
  aTiempo: 30,
  juzgadas1: 18,
  aTiempo1: 16,
  juzgadas2: 18,
  aTiempo2: 14,
  vencidoFinanced: 96.2,
  vencidoFee: 22.4,
  vencidoCuotas: 6,
  porVencerFinanced: 1200,
  porVencerFee: 278.4,
  mora: 7.41,
  registros: 57,
  verificados: 57,
  solicitaron: 63,
  primerConsumo: 21,
  transferido: 350,
  pagos: 2,
  caja: 2468,
  alCierreDe: '2026-09-19',
  juzgadoHasta: '2026-09-16',
}

/**
 * La respuesta de `admin_metricas_semanas` para `n` semanas que acaban en la
 * del 21-09 (en curso), con la de la maqueta al final y semanas más flojas
 * delante.
 */
export function respuestaCruda({
  n = 3,
  local = null,
  ultima = SEMANA_EN_CURSO,
  anterior = ANTERIOR_A_LA_MISMA_ALTURA,
}: {
  n?: number
  local?: string | null
  ultima?: Partial<PeriodoCrudo>
  anterior?: Partial<PeriodoCrudo>
} = {}): Record<string, unknown> {
  const lunesElegido = '2026-09-21'
  const filas = Array.from({ length: n }, (_, i) => {
    const lunes = sumar(lunesElegido, -7 * (n - 1 - i))
    if (i === n - 1) return semanaCruda(lunes, ultima, { enCurso: true, hastaDato: '2026-09-26', dias: 6 })
    const k = i + 1
    return semanaCruda(lunes, {
      consumo: 100 * k,
      consumos: 4 * k,
      personas: 5 * k,
      locales: 1,
      servicio: 20 * k,
      mora: 5 + k / 10,
      registros: local ? null : 10 * k,
      verificados: local ? null : 10 * k,
      solicitaron: local ? null : 12 * k,
      caja: local ? null : 1000 + 100 * k,
    })
  })
  return {
    hoy: '2026-09-26',
    gracia_dias: 2,
    semanas_pedidas: n,
    local,
    semana: { desde: lunesElegido, hasta: '2026-09-27', en_curso: true },
    filas,
    comparacion: {
      desde: '2026-09-14',
      hasta: '2026-09-19',
      dias: 6,
      misma_altura: true,
      ...periodoCrudo(anterior),
    },
  }
}

// ── Parámetros ─────────────────────────────────────────────────────────────

function parametro(key: string, value: number | null, grupo: Parametro['grupo'], label: string | null = null): Parametro {
  return {
    key,
    value,
    effectiveFrom: value === null ? null : '2026-08-01',
    note: null,
    nextValue: null,
    nextFrom: null,
    history: [],
    label,
    unit: null,
    grupo,
  }
}

/** Metas y umbrales como los de producción, con una meta de consumo de €1.000. */
export function parametrosDePrueba({ conMetas = true }: { conMetas?: boolean } = {}): Parametros {
  return {
    businessDate: '2026-09-26',
    filas: [
      parametro('umbral_mora_alerta_pct', 7, 'umbral'),
      parametro('umbral_mora_critica_pct', 15, 'umbral'),
      parametro('umbral_cobro_a_tiempo_bueno_pct', 90, 'umbral'),
      parametro('umbral_cobro_a_tiempo_alerta_pct', 80, 'umbral'),
      parametro('meta_financiado_semana_usd', conMetas ? 1000 : null, 'meta', 'Financiamiento de la semana'),
      parametro('meta_mora_pct', conMetas ? 8 : null, 'meta'),
      parametro('meta_cobro_a_tiempo_pct', conMetas ? 90 : null, 'meta'),
      parametro('meta_personas_activas_semana', conMetas ? 50 : null, 'meta'),
      parametro('meta_locales_activos', null, 'meta'),
    ],
  }
}
