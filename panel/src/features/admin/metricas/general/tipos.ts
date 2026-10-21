import type { Desglose } from '@/features/admin/metricas/lectura'

// ═══════════════════════════════════════════════════════════════════════════
// La respuesta de `admin_metricas_general`, ya leída (`lectura.ts`).
//
// Lo global del negocio desde el primer día. Cada importe lleva su clase en
// el tipo: un `Desglose` es lo que se paga en cuotas (payable) y trae SIEMPRE
// su consumo y su Comisión Helios (IVA incluido); lo demás (`…Usd` suelto) es
// consumo sin comisión, o la Comisión Helios de Helios sin IVA (`servicioUsd`), o un
// cargo por atraso, y ninguno se suma con otro.
//
// `null` es «no se parte por el local elegido» (registros, caja…) o «no hay
// con qué calcularlo» (una tasa sin denominador). Nunca es un cero.
// ═══════════════════════════════════════════════════════════════════════════

export type GenteGeneral = {
  /**
   * Registros: pacientes que una clínica dio de alta (con su primer
   * financiamiento). `null` con clínica.
   */
  registros: number | null
  /** La misma cifra que `registros` (heredada de Ronda: allí era el KYC aprobado). `null` con clínica. */
  verificados: number | null
  /** Registros que se han financiado alguna vez. `null` con clínica. */
  hanComprado: number | null
  /** `hanComprado` sobre `registros`, de 0 a 100. `null` con local o sin registros. */
  hanCompradoPct: number | null
  /** Pacientes con cuota de un financiamiento de los últimos `ventanaDias` días (de la clínica, si la hay). */
  activos: number
  /** Pacientes con cuota en dos días distintos o más (en esa clínica, si la hay). */
  repiten: number
  /**
   * Heredado de Ronda (pidieron el código por SMS). En Helios no hay app ni
   * código: la pantalla ya no lo enseña. `null` con clínica.
   */
  solicitaron: number | null
  /** Heredado de Ronda (confirmaron el teléfono). No se enseña. `null` con clínica. */
  telefonoConfirmado: number | null
}

export type ConsumoGeneral = {
  /** Consumo, sin la Comisión Helios. */
  financedUsd: number
  consumos: number
  /** Consumo ÷ consumos. `null` sin consumos. */
  ticketUsd: number | null
  /** Pacientes distintos con cuota. */
  personas: number
  /** Clínicas que han financiado alguna vez. `null` con clínica. */
  locales: number | null
  /** Locales con ventas en los últimos `ventanaDias` días. `null` con local. */
  localesActivos: number | null
}

/** Cuotas que se pagan (payable), con su desglose y a quién tocan. */
export type CuotasConDesglose = Desglose & { cuotas: number; personas: number }

export type DineroGeneral = {
  /**
   * Todas las cuotas de todos los consumos, cobradas o no: lo cobrado + lo
   * por cobrar + lo perdido. `null` si la base todavía no la manda
   * (20260928210000 sin aplicar).
   */
  movido: (Desglose & { cuotas: number; consumos: number }) | null
  /** Cuotas vivas (vencidas y por vencer), sin lo perdido ni los cargos por atraso. */
  porCobrar: CuotasConDesglose
  /** De lo anterior, lo que ya venció. */
  vencido: CuotasConDesglose
  /** Las cuotas pagadas desde el primer día. */
  cobrado: Desglose & { cuotas: number }
  /** La Comisión Helios de Helios SIN IVA: su ingreso. Nunca sumado al consumo. */
  servicioUsd: number
  /** Los cargos por atraso: ingreso aparte, sin IVA. */
  cargos: { devengadoUsd: number; cobradoUsd: number; cargos: number }
  /** Lo dado por perdido y sin pagar. Su `financedUsd` es la pérdida. */
  perdido: Desglose & { personas: number }
  /** La caja del libro. `null` con local. */
  cajaUsd: number | null
  /** Lo que se les debe a los locales (a ese local, si lo hay). */
  porPagarLocales: { totalUsd: number; atrasadoUsd: number; locales: number }
}

/** El cobro a tiempo de un número de cuota, sobre las que cerraron su plazo. */
export type CobroATiempo = {
  cuota: number
  /** Cuotas con el plazo cerrado: el vencimiento más la gracia ya pasó. */
  juzgadas: number
  aTiempo: number
  /** `null` si ninguna ha cerrado su plazo todavía. */
  pct: number | null
}

export type RiesgoGeneral = {
  /** Vencido ÷ (vencido + por vencer), en payable. `null` sin nada vivo. */
  moraPct: number | null
  /** Consumo perdido ÷ consumo. `null` sin consumo. */
  impagoPct: number | null
  /** El impago con el que Helios ni gana ni pierde. `null` sin ventas. */
  empatePct: number | null
  /** La cuota 1 y la cuota 2, en ese orden. */
  aTiempo: CobroATiempo[]
}

export type PorCadaCien = {
  /** El consumo de todos los consumos: el denominador. */
  financedUsd: number
  consumos: number
  /** El consumo cuya cosecha ya terminó su ciclo de cobro. */
  financedMaduroUsd: number
  servicioUsd: number
  cargosUsd: number
  /** Lo que Helios le paga al personal de las clínicas por esas órdenes: un coste. */
  personalUsd: number
  /** Consumo perdido y sin pagar. */
  perdidoUsd: number
  /** Cada cifra por cada $100 financiados. `null` sin financiamientos. */
  por100: {
    servicioUsd: number
    cargosUsd: number
    personalUsd: number
    perdidoUsd: number
    margenUsd: number
  } | null
}

/** Una semana de la curva: lo de esa semana y lo acumulado hasta ella. */
export type SemanaDeLaCurva = {
  /** El lunes. */
  semana: string
  /** `null` con local: los registros no son de ningún local. */
  registros: number | null
  registrosAcum: number | null
  consumos: number
  financedUsd: number
  financedAcumUsd: number
}

export type General = {
  /** El día operativo que usó la base. */
  hoy: string
  /** El primer día con registro o consumo (del local, si lo hay). `null` sin nada. */
  desde: string | null
  local: string | null
  /** La ventana de «activos», en días. */
  ventanaDias: number
  /** Los días de gracia del cobro a tiempo. */
  graciaDias: number
  /** Lo que tarda un consumo en cerrar su ciclo de cobro, en días. */
  temporadaDias: number
  gente: GenteGeneral
  consumo: ConsumoGeneral
  dinero: DineroGeneral
  riesgo: RiesgoGeneral
  porCadaCien: PorCadaCien
  /** Del lunes de `desde` al de `hoy`, sin huecos. */
  curva: SemanaDeLaCurva[]
}
