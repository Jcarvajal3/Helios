import type { Desglose, SemanaUsada } from '@/features/admin/metricas/lectura'

// ═══════════════════════════════════════════════════════════════════════════
// La forma de las cohortes de consumo, ya leídas del JSON de
// `admin_metricas_cohortes` y `admin_metricas_cohorte` (20260927530000, y
// `a_cobrar` desde 20260927610000).
//
// Una COHORTE es lo consumido en una semana (de lunes a domingo, por día
// operativo) seguido hasta cobrar sus dos cuotas. Cohortes habla en lo que
// hay que COBRAR (decisión de Javier del 27-09):
//   - lo de la semana entera es el TOTAL A COBRAR (`aCobrar`): la cuota 1 + la
//     cuota 2, con el service fee dentro, SIEMPRE con su desglose (`Desglose`:
//     consumo sin fee + service fee). Es la excepción aprobada a la regla de
//     no sumar el fee a un total, y solo vale aquí porque los sumandos se ven;
//   - cada cuota va aparte, también con su desglose;
//   - el consumo sin fee (`consumoUsd`) queda como dato secundario.
// ═══════════════════════════════════════════════════════════════════════════

/** Los cinco estados de una cuota hoy, excluyentes (`metricas.cuotas.estado_hoy`). */
export const ESTADOS_DE_CUOTA = ['a_tiempo', 'tarde', 'vencida', 'por_vencer', 'perdida'] as const
export type EstadoDeCuota = (typeof ESTADOS_DE_CUOTA)[number]

/** Las cuotas de un consumo. */
export const NUMEROS_DE_CUOTA = [1, 2] as const
export type NumeroDeCuota = (typeof NUMEROS_DE_CUOTA)[number]

/** Las cuotas que están en un estado (o en un grupo de estados: lo cobrado, lo que falta). */
export type ParteDeCuota = {
  cuotas: number
  /** Personas distintas: quien tiene las dos cuotas en ese estado cuenta una vez. */
  personas: number
  /** Lo que se cobra (payable) con su consumo sin fee y su service fee. */
  importe: Desglose
}

/**
 * Lo que se cobra en algo —una cuota, o las dos juntas— y en qué estado
 * está. Los porcentajes son sobre lo que se cobra en ello (payable).
 */
export type Cobro = {
  cuotas: number
  personas: number
  /** Lo que se cobra: consumo (sin fee) + service fee (IVA incluido). */
  importe: Desglose
  /** De lo que se cobra, qué parte ya se pagó (a tiempo o tarde). `null` sin nada que cobrar. */
  cobradoPct: number | null
  aTiempoPct: number | null
  vencidoPct: number | null
  estados: Record<EstadoDeCuota, ParteDeCuota>
}

/** Una cuota (la 1 o la 2) de una cohorte. */
export type CuotaDeCohorte = Cobro & {
  numero: NumeroDeCuota
  /** El primer y el último vencimiento de las cuotas de esa semana. */
  venceDesde: string
  venceHasta: string
}

/**
 * Lo que hay que cobrar de una semana: la cuota 1 + la cuota 2, con el
 * service fee dentro y su desglose. Lo cobrado es lo pagado a tiempo o tarde;
 * lo que falta, lo vencido y lo por vencer; lo dado por perdido va en su
 * estado. Las personas de cada parte son personas distintas.
 */
export type ACobrar = Cobro & {
  /** El primer y el último vencimiento de las dos cuotas. `null` si no hay cuotas. */
  venceDesde: string | null
  venceHasta: string | null
  faltaPct: number | null
  /** A tiempo + tarde. */
  cobrado: ParteDeCuota
  /** Vencido + por vencer: lo que queda por cobrar y se puede cobrar. */
  falta: ParteDeCuota
}

/** Una cohorte: lo que hay que cobrar de la semana y sus dos cuotas. */
export type Cohorte = {
  /** El lunes. */
  semana: string
  /** El domingo. */
  hasta: string
  enCurso: boolean
  consumos: number
  /** El consumo, sin el fee: dato secundario (va en el desglose del total a cobrar). */
  consumoUsd: number
  /** Pacientes con alguna cuota de esos financiamientos. */
  personas: number
  /** El total a cobrar: la cuota 1 + la 2, con su desglose. */
  aCobrar: ACobrar
  /** La cuota 1 y la 2, en ese orden (la que no exista, falta). */
  cuotas: ReadonlyArray<CuotaDeCohorte>
}

/** La fila de un local en «Por local»: la misma cohorte, solo con lo de ese local. */
export type CohorteDeLocal = Cohorte & {
  merchantId: string
  nombre: string
}

/** Lo que devuelve `admin_metricas_cohortes`: todas las semanas. */
export type ListaDeCohortes = {
  /** El día operativo que usó la base. */
  hoy: string
  /** Los días de gracia de «a tiempo» (`on_time_grace_days`). */
  graciaDias: number
  semanaEnCurso: string
  /** De la más reciente a la más vieja. */
  cohortes: ReadonlyArray<Cohorte>
}

/** Un día de la curva de cobro de una cuota. */
export type PuntoDeCurva = {
  /** Días desde el vencimiento: 0 es el día en que vence. */
  dia: number
  /** Lo cobrado de esta semana a ese día, en % de lo que se cobra. `null`: el día no ha cerrado. */
  estaPct: number | null
  /** La media de las semanas anteriores que ya cerraron ese día. `null`: ninguna. */
  mediaPct: number | null
  semanasEnMedia: number
}

export type CurvaDeCuota = {
  numero: NumeroDeCuota
  /** Las semanas de la media (lunes), de la más reciente a la más vieja. */
  semanasMedia: ReadonlyArray<string>
  puntos: ReadonlyArray<PuntoDeCurva>
}

/** Lo que devuelve `admin_metricas_cohorte`: una semana con su detalle. */
export type DetalleDeCohorte = {
  semana: SemanaUsada
  hoy: string
  graciaDias: number
  /** `null`: esa semana no hubo consumos (o no en ese local). */
  cohorte: Cohorte | null
  curvas: ReadonlyArray<CurvaDeCuota>
  porLocal: ReadonlyArray<CohorteDeLocal>
}
