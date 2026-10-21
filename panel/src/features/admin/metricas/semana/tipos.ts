import type { Desglose, SemanaUsada } from '@/features/admin/metricas/lectura'

// ═══════════════════════════════════════════════════════════════════════════
// La respuesta de `admin_metricas_semanas`, ya leída (`lectura.ts`).
//
// Cada semana (y la anterior que sirve de comparación) trae las mismas cifras,
// que salen de UNA función de la base, `metricas.semana_periodo`: la columna
// y la comparación no se pueden contar de dos maneras.
//
// Dinero: `Desglose` es lo que se paga en cuotas (payable) y lleva siempre su
// consumo y su Comisión Helios al lado. Lo demás lleva la clase en el nombre:
// `consumoUsd` sin comisión, `servicioUsd` (la Comisión Helios) sin IVA,
// `cargosPorAtrasoUsd` aparte. `null` es «no se parte por local» o «no hay con qué medirlo»; nunca
// un cero.
// ═══════════════════════════════════════════════════════════════════════════

/** Una tasa de cobro a tiempo: cuántas se juzgaron y cuántas llegaron. */
export type TasaATiempo = {
  /** Cuotas con el plazo cerrado (vencimiento + gracia ya pasados). */
  juzgadas: number
  aTiempo: number
  /** `null` sin ninguna juzgada: un 0 % sobre nada no es un dato. */
  pct: number | null
}

/** Todas las cifras de un tramo de días: una semana, o sus primeros días. */
export type CifrasDePeriodo = {
  consumo: {
    /** Consumo, sin la Comisión Helios (financed). */
    consumoUsd: number
    consumos: number
    /** `null` sin consumos. */
    ticketMedioUsd: number | null
    /** Pacientes distintos con cuota. */
    personas: number
    locales: number
  }
  ingreso: {
    /** La Comisión Helios de Helios SIN IVA. Nunca se suma al consumo. */
    servicioUsd: number
    /** Cargos por atraso devengados, sin IVA y sin los condonados. */
    cargosPorAtrasoUsd: number
    cargosPorAtraso: number
  }
  cobro: {
    /** Lo que se pagaba en las cuotas que vencían en el tramo. */
    vencian: Desglose & { cuotas: number }
    /** El último vencimiento que se juzgó. `null`: ninguno todavía. */
    juzgadoHasta: string | null
    aTiempo: TasaATiempo
    cuota1: TasaATiempo
    cuota2: TasaATiempo
  }
  riesgo: {
    /** El día a cuyo cierre se tomó la foto (hoy = ahora). */
    alCierreDe: string
    vencido: Desglose & { cuotas: number; personas: number }
    porVencer: Desglose
    /** Vencido ÷ (vencido + por vencer), en payable. `null` sin nada vivo. */
    moraPct: number | null
    /** Dado por perdido dentro del tramo y sin pagar al cierre. */
    perdido: Desglose & { cuotas: number }
  }
  gente: {
    /**
     * Registros: pacientes que una clínica dio de alta en el tramo. `null`
     * con una clínica: los registros no se parten por clínica.
     */
    registros: number | null
    /** La misma cifra que `registros` (heredada de Ronda: allí era el KYC aprobado). */
    verificados: number | null
    primerConsumo: number
    /** Heredado de Ronda (pidieron el código por SMS). En Helios no hay código: no se enseña. `null` con una clínica. */
    solicitaron: number | null
  }
  caja: {
    transferidoALocalesUsd: number
    pagosALocales: number
    /** Según el libro, al cierre. `null` con un local. */
    enCajaUsd: number | null
  }
}

/** Una columna de la tabla: una semana. */
export type SemanaConCifras = {
  /** El lunes. */
  desde: string
  /** El domingo. */
  hasta: string
  /** El último día con datos: el domingo, o hoy si está en curso. */
  hastaDato: string
  /** Los días que cuenta: 7, o los que lleva la en curso (hoy incluido). */
  dias: number
  enCurso: boolean
  cifras: CifrasDePeriodo
}

/** Contra qué se compara la semana elegida. */
export type Comparacion = {
  desde: string
  hasta: string
  dias: number
  /** La elegida está en curso: se compara con la anterior hasta el mismo momento. */
  mismaAltura: boolean
  /**
   * El instante hasta el que cuentan los flujos de la anterior (`timestamptz`):
   * ahora menos siete días. `null`: la anterior entera. Las fotos (vencido,
   * mora, caja) van al cierre del día equivalente.
   */
  corte: string | null
  juzgadoHasta: string | null
  cifras: CifrasDePeriodo
}

export type RespuestaSemanas = {
  /** El día operativo que usó la base. */
  hoy: string
  graciaDias: number
  /** El local que filtró la base, o `null`. */
  local: string | null
  /** La semana elegida, tal como la entendió la base. */
  semana: SemanaUsada
  /** De la más vieja a la elegida, que es la última. */
  semanas: SemanaConCifras[]
  comparacion: Comparacion
}
