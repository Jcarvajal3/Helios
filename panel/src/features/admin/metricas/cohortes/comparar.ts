import { csvDinero, csvEntero } from '@/lib/csv'
import type { CsvColumn } from '@/lib/csv'
import type { Desglose } from '@/features/admin/metricas/lectura'
import { cuotaDe } from './estados'
import { rotuloDeSemana, semanaLarga } from './semanas'
import { ESTADOS_DE_CUOTA, NUMEROS_DE_CUOTA } from './tipos'
import type { Cohorte, CuotaDeCohorte, EstadoDeCuota, NumeroDeCuota, ParteDeCuota } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// «Comparar todas»: el gráfico de lo que hay que cobrar semana a semana y la
// tabla (y su CSV) con todas las cohortes.
//
// Todo en lo que se COBRA (payable). El total a cobrar de una semana es la
// cuota 1 + la cuota 2, con el service fee dentro, y va SIEMPRE con su
// desglose: en el globo, en la tabla del gráfico y en dos columnas más del
// CSV (consumo sin fee y service fee).
//
// Puro: se prueba en `comparar.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Cuántas semanas enseña el gráfico: las más recientes. */
export const SEMANAS_EN_EL_GRAFICO = 12

/** Una columna del gráfico: una semana, partida por estado. */
export type ColumnaDelCobro = {
  semana: string
  /** Lo que se lee en el eje: '14–20 sep'. */
  rotulo: string
  /** Para el globo y la tabla: 'del 14 al 20 de septiembre'. */
  titulo: string
  /** Lo que se cobra en cada estado, en el orden de `ESTADOS_DE_CUOTA`. */
  valores: ReadonlyArray<number>
  /** El total a cobrar, con su desglose. */
  total: Desglose
  cobradoPct: number | null
}

/** Las columnas del gráfico, de la más vieja a la más nueva: las `cuantas` más recientes. */
export function columnasDelCobro(
  cohortes: ReadonlyArray<Cohorte>,
  cuantas = SEMANAS_EN_EL_GRAFICO,
): ColumnaDelCobro[] {
  return [...cohortes]
    .sort((a, b) => (a.semana < b.semana ? -1 : a.semana > b.semana ? 1 : 0))
    .slice(-cuantas)
    .map((c) => ({
      semana: c.semana,
      rotulo: rotuloDeSemana(c.semana),
      titulo: semanaLarga(c.semana),
      valores: ESTADOS_DE_CUOTA.map((e) => c.aCobrar.estados[e].importe.payableUsd),
      total: c.aCobrar.importe,
      cobradoPct: c.aCobrar.cobradoPct,
    }))
}

// ── El CSV de la tabla comparada ───────────────────────────────────────────

/** Tres columnas por importe: lo que se cobra y sus dos partes. Nunca un importe sin sus sumandos. */
function columnasDeImporte<T>(
  nombre: string,
  de: (x: T) => Desglose | null,
): Array<CsvColumn<T>> {
  const dinero = (f: (d: Desglose) => number) => (x: T) => {
    const d = de(x)
    return d ? csvDinero(f(d)) : null
  }
  return [
    { header: `${nombre} ($)`, value: dinero((d) => d.payableUsd) },
    { header: `${nombre}: financiado, sin fee ($)`, value: dinero((d) => d.financedUsd) },
    { header: `${nombre}: service fee + IVA ($)`, value: dinero((d) => d.feeUsd) },
  ]
}

const NOMBRE_EN_CSV: Record<EstadoDeCuota, string> = {
  a_tiempo: 'cobrado a tiempo',
  tarde: 'cobrado con atraso',
  vencida: 'vencido',
  por_vencer: 'por vencer',
  perdida: 'perdido',
}

function porcentaje<T>(f: (x: T) => number | null) {
  return (x: T) => {
    const v = f(x)
    return v === null ? null : csvDinero(v)
  }
}

function columnasDeCuota(n: NumeroDeCuota): Array<CsvColumn<Cohorte>> {
  const q = (c: Cohorte): CuotaDeCohorte | null => cuotaDe(c, n)
  const nombre = `Cuota ${n}`
  const estado = (e: EstadoDeCuota) => (c: Cohorte): ParteDeCuota | null => q(c)?.estados[e] ?? null
  return [
    { header: `${nombre} · vence desde`, value: (c) => q(c)?.venceDesde },
    { header: `${nombre} · vence hasta`, value: (c) => q(c)?.venceHasta },
    { header: `${nombre} · pacientes`, value: (c) => csvEntero(q(c)?.personas) },
    ...columnasDeImporte<Cohorte>(`${nombre} · total de la cuota`, (c) => q(c)?.importe ?? null),
    ...ESTADOS_DE_CUOTA.flatMap((e) =>
      columnasDeImporte<Cohorte>(`${nombre} · ${NOMBRE_EN_CSV[e]}`, (c) => estado(e)(c)?.importe ?? null),
    ),
    { header: `${nombre} · pacientes con vencido`, value: (c) => csvEntero(q(c)?.estados.vencida.personas) },
    { header: `${nombre} · cobrado (%)`, value: porcentaje((c: Cohorte) => q(c)?.cobradoPct ?? null) },
    { header: `${nombre} · cobrado a tiempo (%)`, value: porcentaje((c: Cohorte) => q(c)?.aTiempoPct ?? null) },
  ]
}

/**
 * Las columnas del CSV: la semana, lo que hay que cobrar de ella (la cuota 1
 * + la 2) con lo cobrado, lo vencido, lo por vencer y lo perdido, y cada
 * cuota en su bloque. Todo importe lleva sus dos partes en dos columnas más.
 * Un dato que no hay (una semana sin cuota 2) sale en blanco, no a cero.
 */
export function columnasCsvDeCohortes(): Array<CsvColumn<Cohorte>> {
  const parte = (f: (c: Cohorte) => ParteDeCuota) => (c: Cohorte) => f(c).importe
  return [
    { header: 'Semana (lunes)', value: (c) => c.semana },
    { header: 'Hasta (domingo)', value: (c) => c.hasta },
    { header: 'Financiamientos', value: (c) => csvEntero(c.consumos) },
    { header: 'Pacientes que se financiaron', value: (c) => csvEntero(c.personas) },
    ...columnasDeImporte<Cohorte>('Total a cobrar', (c) => c.aCobrar.importe),
    ...columnasDeImporte<Cohorte>('Cobrado', parte((c) => c.aCobrar.cobrado)),
    { header: 'Cobrado (%)', value: porcentaje((c: Cohorte) => c.aCobrar.cobradoPct) },
    ...columnasDeImporte<Cohorte>('Cobrado a tiempo', parte((c) => c.aCobrar.estados.a_tiempo)),
    ...columnasDeImporte<Cohorte>('Cobrado con atraso', parte((c) => c.aCobrar.estados.tarde)),
    ...columnasDeImporte<Cohorte>('Falta por cobrar', parte((c) => c.aCobrar.falta)),
    ...columnasDeImporte<Cohorte>('Vencido', parte((c) => c.aCobrar.estados.vencida)),
    { header: 'Pacientes con vencido', value: (c) => csvEntero(c.aCobrar.estados.vencida.personas) },
    ...columnasDeImporte<Cohorte>('Por vencer', parte((c) => c.aCobrar.estados.por_vencer)),
    ...columnasDeImporte<Cohorte>('Perdido', parte((c) => c.aCobrar.estados.perdida)),
    ...NUMEROS_DE_CUOTA.flatMap(columnasDeCuota),
  ]
}

/** El nombre del archivo, sin extensión. */
export function nombreDelCsv(hoy: string, nombreLocal: string | null): string {
  const local = nombreLocal
    ? `-${nombreLocal
        .normalize('NFD')
        .replace(/[̀-ͯ]/g, '')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-|-$/g, '')}`
    : ''
  return `cohortes-de-financiamiento${local}-${hoy}`
}
