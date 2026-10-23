import { comoDia } from '@/lib/busqueda'
import { comoFila, filas, numero, numeroONulo, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// La lectura de Métricas › Juan Pablo: `admin_metricas_juan_pablo`, una sola
// RPC para las cifras y la tabla de los médicos.
//
// La pantalla pinta el periodo que USÓ la base (recorta el futuro a hoy), no
// el que pidió. La llamada se arma en `api.ts`.
//
// Puro: se prueba en `periodo.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export const RPC_JUAN_PABLO = 'admin_metricas_juan_pablo'

export type MedicoDeJuanPablo = {
  merchantId: string
  /** El titular con su título; sin titular, la clínica. */
  medico: string
  clinica: string
  ordenes: number
  /** Su parte de las órdenes del periodo, de 0 a 100. */
  pct: number | null
  gtvUsd: number
  revenueUsd: number
}

export type JuanPablo = {
  desde: string
  hasta: string
  dias: number
  ordenes: number
  /** Lo que suman las consultas, sin la Comisión Helios. */
  gtvUsd: number
  /** La Comisión Helios, sin su IVA. */
  revenueUsd: number
  /** El revenue sobre el GTV, de 0 a 100 (el 12% del parámetro). */
  revenuePct: number | null
  ticketMedioUsd: number | null
  medicos: {
    afiliados: number
    conOrdenes: number
    /** Los médicos con órdenes entre los afiliados, de 0 a 100. */
    conOrdenesPct: number | null
    /** Las órdenes entre los médicos que las generaron. */
    ordenesPorMedico: number | null
  }
  porMedico: MedicoDeJuanPablo[]
}

export function leerJuanPablo(crudo: unknown): JuanPablo {
  const r = comoFila(crudo)
  const m = comoFila(r.medicos)
  const desde = comoDia(r.desde) ?? ''
  return {
    desde,
    hasta: comoDia(r.hasta) ?? desde,
    dias: numero(r.dias),
    ordenes: numero(r.ordenes),
    gtvUsd: numero(r.gtv_usd),
    revenueUsd: numero(r.revenue_usd),
    revenuePct: numeroONulo(r.revenue_pct),
    ticketMedioUsd: numeroONulo(r.ticket_medio_usd),
    medicos: {
      afiliados: numero(m.afiliados),
      conOrdenes: numero(m.con_ordenes),
      conOrdenesPct: numeroONulo(m.con_ordenes_pct),
      ordenesPorMedico: numeroONulo(m.ordenes_por_medico),
    },
    porMedico: filas(r.por_medico).map((f) => ({
      merchantId: texto(f.merchant_id),
      medico: textoONulo(f.medico) ?? texto(f.clinica),
      clinica: texto(f.clinica),
      ordenes: numero(f.ordenes),
      pct: numeroONulo(f.pct),
      gtvUsd: numero(f.gtv_usd),
      revenueUsd: numero(f.revenue_usd),
    })),
  }
}
