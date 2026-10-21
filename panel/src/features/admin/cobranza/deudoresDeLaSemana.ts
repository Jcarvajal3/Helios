import { unoDe } from '@/lib/busqueda'
import { comoFila, comoLista, numero, texto, textoONulo } from '@/lib/json'
import { leerUmbralesDePerfil } from '@/features/admin/metricas/cobranza/deudores'
import type { UmbralesDePerfil } from '@/features/admin/metricas/cobranza/perfiles'
import type { Desglose } from '@/features/admin/metricas/lectura'
import { leerFilaDeCartera } from './cartera'
import type { CollectionRow } from './cartera'

// ═══════════════════════════════════════════════════════════════════════════
// Por cobrar › Cohortes: quién debe algo de lo consumido una semana
// (`admin_deudores_de_la_semana`, 20260928201000).
//
// Cada persona trae su fila de la cartera entera (a 30 días: lo que debe en
// total, su última gestión, su perfil y sus señales) y, aparte, lo que debe
// DE ESA SEMANA cuota a cuota. Las cuotas salen de la misma fuente que las
// cifras de la semana, así que lo vencido y lo por vencer de esta lista suman
// lo de las tarjetas de arriba.
//
// Puro: se prueba en `deudoresDeLaSemana.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export const ESTADOS_QUE_SE_DEBEN = ['vencida', 'por_vencer', 'perdida'] as const
export type EstadoQueSeDebe = (typeof ESTADOS_QUE_SE_DEBEN)[number]

export const ROTULO_ESTADO_QUE_SE_DEBE: Record<EstadoQueSeDebe, string> = {
  vencida: 'Vencida',
  por_vencer: 'Por vencer',
  perdida: 'Perdida',
}

/** Una cuota de la semana que esta persona todavía debe. */
export type CuotaQueSeDebe = {
  numero: 1 | 2
  estado: EstadoQueSeDebe
  vence: string
  diasAtraso: number
  importe: Desglose
  local: string | null
}

export type DeudorDeLaSemana = CollectionRow & {
  /** Lo que debe de esa semana: la suma de sus cuotas, con comisión y su desglose. */
  deLaSemana: Desglose
  cuotas: ReadonlyArray<CuotaQueSeDebe>
}

export type DeudoresDeLaSemana = {
  semana: string
  hoy: string
  /** Hasta cuántos días mira la cartera entera de cada persona. */
  horizonteDias: number
  demotionDays: number
  umbralesDePerfil: UmbralesDePerfil
  filas: ReadonlyArray<DeudorDeLaSemana>
}

function leerDesglose(raw: unknown): Desglose {
  const r = comoFila(raw)
  return {
    payableUsd: numero(r.payable_usd),
    financedUsd: numero(r.financed_usd),
    feeUsd: numero(r.fee_usd),
  }
}

function leerCuota(raw: unknown): CuotaQueSeDebe | null {
  const r = comoFila(raw)
  const estado = unoDe(ESTADOS_QUE_SE_DEBEN, r.estado)
  if (!estado) return null
  return {
    numero: numero(r.numero) === 2 ? 2 : 1,
    estado,
    vence: texto(r.vence),
    diasAtraso: numero(r.dias_atraso),
    importe: leerDesglose(r),
    local: textoONulo(r.local),
  }
}

function leerDeudor(raw: unknown): DeudorDeLaSemana {
  const r = comoFila(raw)
  const semana = comoFila(r.de_la_semana)
  return {
    ...leerFilaDeCartera(r),
    deLaSemana: leerDesglose(semana),
    cuotas: comoLista(semana.cuotas)
      .map(leerCuota)
      .filter((c): c is CuotaQueSeDebe => c !== null),
  }
}

export function leerDeudoresDeLaSemana(raw: unknown): DeudoresDeLaSemana {
  const d = comoFila(raw)
  return {
    semana: texto(d.semana),
    hoy: texto(d.business_date),
    horizonteDias: numero(d.horizonte_dias),
    demotionDays: numero(d.demotion_days),
    umbralesDePerfil: leerUmbralesDePerfil(d.umbrales_perfil),
    filas: comoLista(d.rows).map(leerDeudor),
  }
}

/** Qué cuotas se enseñan: las dos, o solo la 1 o la 2. */
export type FiltroDeCuota = 'todas' | '1' | '2'

/**
 * Las filas con alguna cuota del número pedido, y en cada una solo esas
 * cuotas y su suma. Con «todas», tal cual.
 */
export function deLaCuota(
  filas: ReadonlyArray<DeudorDeLaSemana>,
  cuota: FiltroDeCuota,
): DeudorDeLaSemana[] {
  if (cuota === 'todas') return [...filas]
  const n = cuota === '2' ? 2 : 1
  const out: DeudorDeLaSemana[] = []
  for (const f of filas) {
    const cuotas = f.cuotas.filter((c) => c.numero === n)
    if (cuotas.length === 0) continue
    out.push({ ...f, cuotas, deLaSemana: sumar(cuotas.map((c) => c.importe)) })
  }
  return out
}

export function sumar(partes: ReadonlyArray<Desglose>): Desglose {
  return partes.reduce(
    (a, p) => ({
      payableUsd: a.payableUsd + p.payableUsd,
      financedUsd: a.financedUsd + p.financedUsd,
      feeUsd: a.feeUsd + p.feeUsd,
    }),
    { payableUsd: 0, financedUsd: 0, feeUsd: 0 },
  )
}

/** Lo que se debe de la semana en cada estado, para la línea de la lista. */
export function sumasPorEstado(
  filas: ReadonlyArray<DeudorDeLaSemana>,
): Record<EstadoQueSeDebe, { importe: Desglose; personas: number }> {
  const out = {} as Record<EstadoQueSeDebe, { importe: Desglose; personas: number }>
  for (const e of ESTADOS_QUE_SE_DEBEN) {
    const con = filas.filter((f) => f.cuotas.some((c) => c.estado === e))
    out[e] = {
      importe: sumar(con.flatMap((f) => f.cuotas.filter((c) => c.estado === e).map((c) => c.importe))),
      personas: con.length,
    }
  }
  return out
}
