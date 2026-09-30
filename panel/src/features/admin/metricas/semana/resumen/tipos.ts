import type { SemanaUsada } from '@/features/admin/metricas/lectura'

// ═══════════════════════════════════════════════════════════════════════════
// La respuesta de `admin_metricas_semana_resumen`, ya en camelCase.
//
// Dos clases de dinero que no se mezclan (la regla del fee):
//   financedUsd  el consumo SIN el fee: el «Total facturado».
//   payableUsd   lo que se cobra: consumo + service fee con su IVA. Nunca se
//                enseña sin sus dos partes (`financedUsd` y `feeUsd`) al lado.
// ═══════════════════════════════════════════════════════════════════════════

/** Las cifras de un tramo de días (la semana, la anterior, una de la chispa). */
export type CifrasDelTramo = {
  /** Total facturado: el consumo en los locales, sin el fee. */
  financedUsd: number
  /** El service fee con su IVA: `payable − financed`. */
  feeUsd: number
  /** Total a cobrar: facturado + service fee + IVA. Solo con sus dos partes. */
  payableUsd: number
  /** El service fee SIN IVA (el ingreso de Helios). */
  servicioUsd: number
  /** El IVA del service fee: `fee − servicio`. */
  ivaUsd: number
  consumos: number
  /** Sin el fee. `null` sin consumos: no hay ticket de nada. */
  ticketMedioUsd: number | null
  /** Personas con cuota: quien vino dos noches cuenta una vez. */
  personas: number
  /** Personas cuya primera cuota en un local cae en el tramo, contadas una vez. */
  nuevas: number
}

/** Una semana de la chispa, con su tramo. */
export type SemanaDeLaChispa = CifrasDelTramo & {
  desde: string
  hasta: string
  /** El último día con datos: hoy, si está en curso. */
  hastaDato: string
  dias: number
  enCurso: boolean
}

/** Una fila de la tabla: una noche (día operativo) en un local. */
export type NocheDeLocal = {
  dia: string
  merchantId: string
  nombre: string
  consumos: number
  personas: number
  /** Las que tenían en esa noche su primera cuota en ESE local. */
  nuevas: number
  financedUsd: number
  feeUsd: number
  payableUsd: number
  ticketMedioUsd: number | null
}

/** La semana anterior con la que se compara. */
export type Anterior = {
  desde: string
  hasta: string
  dias: number
  /** La elegida va a medias y se compara con la anterior hasta el mismo momento. */
  mismaAltura: boolean
  /**
   * El instante hasta el que cuenta la anterior (`timestamptz`): ahora menos
   * siete días, si la elegida está en curso. `null`: la anterior entera.
   */
  corte: string | null
}

export type RespuestaResumen = {
  /** El día operativo que usó la base como «hoy». */
  hoy: string
  local: string | null
  /** La semana elegida (lunes a domingo), como la usó la base. */
  semana: SemanaUsada
  /** El último día contado: el domingo, o hoy si está en curso. */
  hasta: string
  dias: number
  anterior: Anterior
  cifras: CifrasDelTramo
  comparacion: CifrasDelTramo
  /** Las ocho últimas, de la más vieja a la elegida. */
  semanas: SemanaDeLaChispa[]
  /** De la noche más reciente a la más vieja; en cada noche, de más a menos consumo. */
  noches: NocheDeLocal[]
}
