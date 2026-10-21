import type { EstadoLocal } from '@/features/admin/estados'
import type { Desglose, SemanaUsada } from '@/features/admin/metricas/lectura'

// ═══════════════════════════════════════════════════════════════════════════
// La forma de lo que lee la pestaña Locales, ya en camelCase.
//
// Sale de `admin_metricas_locales(p_semana, p_merchant_id)` (migración
// 20260927560000), que lo cuenta todo desde el esquema `metricas`. Los
// nombres dicen la clase de cada importe: `…Usd` suelto es consumo (sin el
// Comisión Helios); lo que se paga en cuotas llega como `Desglose`, con sus
// dos partes, y no se enseña nunca sin ellas.
// ═══════════════════════════════════════════════════════════════════════════

/** Las cuotas de su gente que vencían en la semana, y cuántas se cobraron a tiempo. */
export type ATiempoDeLaSemana = {
  /** Las que vencían entre el lunes y el domingo. */
  vencen: number
  /** Las que ya cerraron su plazo (vencimiento + gracia): solo esas se juzgan. */
  juzgadas: number
  /** De las juzgadas, las pagadas dentro del plazo. */
  aTiempo: number
  /** `aTiempo ÷ juzgadas`, de 0 a 100. `null` sin juzgadas: no hay veredicto. */
  pct: number | null
}

/** Lo vencido de su gente al cierre de la semana: cuotas, con su desglose. */
export type VencidoDeSuGente = Desglose & {
  cuotas: number
  personas: number
}

/** Lo que se le paga por las cuotas de la semana (de martes a lunes), para ese local. */
export type Transferencia = {
  /** Liquidaciones ya generadas para ese cierre. */
  generadoUsd: number
  /** De ellas, lo ya transferido. */
  transferidoUsd: number
  /** De ellas, lo que falta por transferir. */
  pendienteUsd: number
  /** Lo que se generará antes del cierre (solo si el cierre no ha llegado). */
  previstoUsd: number
  /**
   * Lo de semanas anteriores que sigue sin transferirse: no es de esta semana,
   * pero sigue saliendo como atrasado en los pagos diarios (solo si los
   * pagos de la semana no han terminado).
   */
  atrasadoUsd: number
}

/**
 * Un local en la semana, o todos juntos (`merchantId` nulo). En la fila de
 * todos, las personas y las nuevas están recontadas: quien fue a dos locales
 * cuenta una vez, así que no son la suma de las filas.
 */
export type FilaLocal = {
  merchantId: string | null
  nombre: string
  estado: EstadoLocal | null
  ciudad: string | null
  /** Consumo de la semana, sin la Comisión Helios. */
  consumoUsd: number
  consumos: number
  /** `null` sin consumos: un ticket de $0 no existe. */
  ticketMedioUsd: number | null
  /** La semana anterior a la misma altura (los mismos días si la elegida está en curso). */
  consumoAnteriorUsd: number
  consumosAnteriores: number
  /** Pacientes distintos con cuota. */
  personas: number
  /** Las que consumieron en ESTE local por primera vez esta semana. */
  nuevas: number
  noches: number
  consumosEnGrupo: number
  mejorNoche: { fecha: string; consumoUsd: number } | null
  /** Su parte del consumo de todos los locales, de 0 a 100. `null` si nadie consumió. */
  partePct: number | null
  aTiempo: ATiempoDeLaSemana
  vencido: VencidoDeSuGente
  transferencia: Transferencia
}

/** Las doce semanas de un local, la elegida la última (a medias si está en curso). */
export type SerieDeLocal = {
  merchantId: string
  nombre: string
  /** El día de su primer consumo, de toda su historia. */
  primerConsumo: string | null
  consumoUsd: number[]
  consumos: number[]
  personas: number[]
  nuevas: number[]
}

/** Una cuota (la 1 o la 2) de lo consumido en una semana, con su estado de hoy. */
export type CuotaDeCohorte = {
  cuotas: number
  /** Con el plazo cerrado: las que ya tienen veredicto. */
  juzgadas: number
  aTiempoJuzgadas: number
  /** `aTiempoJuzgadas ÷ juzgadas`, de 0 a 100. `null` sin juzgadas. */
  pctATiempo: number | null
  /** Los cinco estados de hoy; suman `cuotas`. */
  aTiempo: number
  tarde: number
  vencidas: number
  porVencer: number
  perdidas: number
  vencido: Desglose
}

export type SemanaDeCohorte = {
  /** El lunes de la semana en que se consumió. */
  semana: string
  /** `null`: ese local no vendió esa semana. */
  cuota1: CuotaDeCohorte | null
  cuota2: CuotaDeCohorte | null
}

export type CohortesDeLocal = {
  merchantId: string
  nombre: string
  /** Las ocho semanas, en el orden de `cohortes.semanas`. */
  semanas: SemanaDeCohorte[]
}

/** Toda la respuesta de `admin_metricas_locales`. */
export type LocalesDeLaSemana = {
  /** La semana que usó la base. */
  semana: SemanaUsada
  hoy: string
  /** El último día contado: el domingo, o hoy si la semana está en curso. */
  hasta: string
  dias: number
  /** Contra qué se compara: la semana anterior, o sus mismos días si la elegida va a medias. */
  anterior: { desde: string; hasta: string; mismaAltura: boolean }
  /** El último día de pago de lo que vence en la semana: el lunes siguiente. */
  cierre: { lunes: string; pasado: boolean }
  graciaDias: number
  local: string | null
  /** De más a menos consumo. Con un local pedido, solo ese. */
  locales: FilaLocal[]
  /** Todos los locales juntos, con o sin local pedido. */
  totales: FilaLocal
  series: { semanas: string[]; locales: SerieDeLocal[] }
  cohortes: { semanas: string[]; locales: CohortesDeLocal[] }
}
