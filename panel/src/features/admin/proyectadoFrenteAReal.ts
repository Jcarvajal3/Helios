import { booleano, comoFila, comoLista, numero, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Lo proyectado frente a lo que pasó.
//
// Cada lunes a las 10:30 la base guarda una foto de la proyección de caja de
// las 8 semanas siguientes (`cash_forecast_snapshots`). Pasada la semana, lo
// que se proyectó se compara con lo que dice el libro. Módulo puro: la
// lectura de la base está en `proyeccionDeCaja.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Una semana, lunes a domingo en días operativos. */
export type SemanaProyectadaYReal = {
  weekStart: string
  weekEnd: string
  /** `false` para la semana de hoy: todavía puede cambiar. */
  completa: boolean
  /** El lunes de la foto de donde sale lo proyectado. */
  fotoDelLunes: string
  /** Cuántas semanas antes se tomó la foto: 0 es la del mismo lunes. */
  semanasDeAntelacion: number
  /** PAYABLE: lo que vencía esa semana, sin ajustar. */
  proyectadoVenceUsd: number
  /** PAYABLE: lo que se esperaba cobrar (lo que vencía × el cobro a tiempo). */
  proyectadoCobrarUsd: number
  proyectadoTransferirUsd: number
  proyectadoNetoUsd: number
  proyectadoCajaFinalUsd: number
  /** PAYABLE: lo que entró por pagos de cuotas, con los cargos por atraso. */
  cobradoUsd: number
  transferidoUsd: number
  /** Cualquier otro movimiento de caja del libro, neto. */
  otrosUsd: number
  netoUsd: number
  cajaFinalUsd: number
}

export type ProyectadoFrenteAReal = {
  businessDate: string
  /** Cuántas fotos hay en total. */
  fotos: number
  primeraFoto: string | null
  /** El lunes de la próxima foto. */
  proximaFoto: string
  semanas: SemanaProyectadaYReal[]
}

export function leerProyectadoFrenteAReal(raw: unknown): ProyectadoFrenteAReal {
  const d = comoFila(raw)
  return {
    businessDate: texto(d.business_date),
    fotos: numero(d.snapshots),
    primeraFoto: textoONulo(d.first_snapshot_week),
    proximaFoto: texto(d.next_snapshot_on),
    semanas: comoLista(d.rows).map((fila) => {
      const r = comoFila(fila)
      return {
        weekStart: texto(r.week_start),
        weekEnd: texto(r.week_end),
        completa: booleano(r.complete),
        fotoDelLunes: texto(r.snapshot_week),
        semanasDeAntelacion: numero(r.lead_weeks),
        proyectadoVenceUsd: numero(r.projected_gross_usd),
        proyectadoCobrarUsd: numero(r.projected_in_usd),
        proyectadoTransferirUsd: numero(r.projected_out_usd),
        proyectadoNetoUsd: numero(r.projected_net_usd),
        proyectadoCajaFinalUsd: numero(r.projected_cash_end_usd),
        cobradoUsd: numero(r.collected_usd),
        transferidoUsd: numero(r.paid_to_merchants_usd),
        otrosUsd: numero(r.other_cash_usd),
        netoUsd: numero(r.actual_net_usd),
        cajaFinalUsd: numero(r.actual_cash_end_usd),
      }
    }),
  }
}

/**
 * Cuánto se desvió el cobro de lo esperado en las semanas ya cerradas: lo
 * cobrado menos lo que se esperaba cobrar, sumado. `null` si todavía no hay
 * ninguna semana cerrada, que no es un desvío de cero.
 */
export function desvioDelCobro(semanas: ReadonlyArray<SemanaProyectadaYReal>): number | null {
  const cerradas = semanas.filter((s) => s.completa)
  if (cerradas.length === 0) return null
  return cerradas.reduce((suma, s) => suma + s.cobradoUsd - s.proyectadoCobrarUsd, 0)
}
