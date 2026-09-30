import { comoFila, comoLista, filaONula, numeroONulo, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Las cifras de crédito de Riesgo que no son cosechas: el impago de la primera
// cuota, el uso del cupo por nivel y los locales por volumen.
//
// Solo se leen y se tipan. Los montos de consumo son financed (sin el service
// fee); los de deuda, payable, y cada campo lo dice en su nombre.
// ═══════════════════════════════════════════════════════════════════════════

// ── Impago de una cuota tras la gracia (`admin_first_payment_default`) ─────

/**
 * Qué cuota se juzga. Cada consumo se paga en dos: la 1 es la señal más
 * temprana y la 2 dice si quien pagó una sigue pagando. Sin `p_cuota`, la
 * base juzga la 1 (Inicio la llama así).
 */
export type NumeroDeCuota = 1 | 2

export const CUOTAS: ReadonlyArray<NumeroDeCuota> = [1, 2]

/** La otra cuota: la 2 si se mira la 1, y al revés. Es con la que se compara. */
export function otraCuota(c: NumeroDeCuota): NumeroDeCuota {
  return c === 1 ? 2 : 1
}

/**
 * Por qué se parte el impago de una cuota. `semana` es la cohorte de
 * consumo (su clave es el lunes), la de Métricas.
 */
export type DimensionPrimeraCuota = 'mes' | 'semana' | 'local' | 'nivel' | 'grupo' | 'primera_compra'

export const DIMENSIONES_PRIMERA_CUOTA: ReadonlyArray<{
  value: DimensionPrimeraCuota
  label: string
}> = [
  { value: 'mes', label: 'Mes' },
  { value: 'semana', label: 'Semana' },
  { value: 'local', label: 'Clínica' },
  { value: 'nivel', label: 'Nivel' },
  { value: 'grupo', label: 'Pacientes en el financiamiento' },
  { value: 'primera_compra', label: 'Primer financiamiento' },
]

export type CifrasPrimeraCuota = {
  /** Cuotas (la 1 o la 2) que ya pasaron la gracia. */
  maduras: number
  impagas: number
  /** Sobre cuotas, no sobre euros. `null` sin cuotas maduras. */
  impagoPct: number | null
  /** Consumo (financed, sin el service fee) de esas cuotas. */
  madurasMonto: number
  impagasMonto: number
  /** Lo mismo a los 30 días del vencimiento. */
  maduras30: number
  impagas30: number
  impago30Pct: number | null
  impagas30Monto: number
  /** Cuotas que todavía están dentro de la gracia: no entran en ningún porcentaje. */
  enGracia: number
  /**
   * Lo mismo contado solo sobre quien ya había pagado la cuota anterior el
   * día en que se juzga esta: con la 2, «de quien pagó la cuota 1, qué parte
   * no paga la 2». `null` con la cuota 1 (no tiene anterior) o si la base
   * todavía no lo manda.
   */
  trasPagarLaAnterior: CifrasTrasPagarLaAnterior | null
}

/**
 * La cuota de quien ya había pagado la anterior (`previous_paid`). «Pagada»
 * se mira el mismo día que se juzga esta, al acabar su gracia (o a los 30
 * días): quien paga la 1 después no entra, porque entonces no la había pagado.
 */
export type CifrasTrasPagarLaAnterior = {
  maduras: number
  impagas: number
  /** Sobre cuotas. `null` si nadie que pagó la anterior tiene esta madura. */
  impagoPct: number | null
  /** Consumo (financed, sin el service fee). */
  madurasMonto: number
  impagasMonto: number
  maduras30: number
  impagas30: number
  impago30Pct: number | null
}

export type FilaPrimeraCuota = CifrasPrimeraCuota & { clave: string; rotulo: string }

export type PrimeraCuota = {
  businessDate: string
  desde: string
  meses: number
  /** La cuota que se juzgó: la que dice la base, no la que se pidió. */
  cuota: NumeroDeCuota
  dimension: DimensionPrimeraCuota
  diasDeGracia: number
  diasTarde: number
  /** Solo por nivel: de dónde salió el nivel al consumir. */
  baseDelNivel: { historial: number; actual: number } | null
  total: CifrasPrimeraCuota
  filas: FilaPrimeraCuota[]
}

function leerTrasPagarLaAnterior(raw: unknown): CifrasTrasPagarLaAnterior | null {
  const f = filaONula(raw)
  if (!f) return null
  return {
    maduras: Number(f.matured_count ?? 0),
    impagas: Number(f.defaulted_count ?? 0),
    impagoPct: numeroONulo(f.defaulted_pct),
    madurasMonto: Number(f.matured_financed_usd ?? 0),
    impagasMonto: Number(f.defaulted_financed_usd ?? 0),
    maduras30: Number(f.matured_30_count ?? 0),
    impagas30: Number(f.defaulted_30_count ?? 0),
    impago30Pct: numeroONulo(f.defaulted_30_pct),
  }
}

function leerCifrasPrimeraCuota(raw: unknown): CifrasPrimeraCuota {
  const f = comoFila(raw)
  return {
    maduras: Number(f.matured_count ?? 0),
    impagas: Number(f.defaulted_count ?? 0),
    impagoPct: numeroONulo(f.defaulted_pct),
    madurasMonto: Number(f.matured_financed_usd ?? 0),
    impagasMonto: Number(f.defaulted_financed_usd ?? 0),
    maduras30: Number(f.matured_30_count ?? 0),
    impagas30: Number(f.defaulted_30_count ?? 0),
    impago30Pct: numeroONulo(f.defaulted_30_pct),
    impagas30Monto: Number(f.defaulted_30_financed_usd ?? 0),
    enGracia: Number(f.in_grace_count ?? 0),
    trasPagarLaAnterior: leerTrasPagarLaAnterior(f.previous_paid),
  }
}

export function leerPrimeraCuota(raw: unknown, dimension: DimensionPrimeraCuota): PrimeraCuota {
  const f = comoFila(raw)
  const base = f.level_basis === null || f.level_basis === undefined ? null : comoFila(f.level_basis)
  return {
    businessDate: textoONulo(f.business_date) ?? '',
    desde: textoONulo(f.from) ?? '',
    meses: Number(f.months ?? 0),
    // Sin la clave, la base es de antes de juzgar la 2: lo que dio es la 1.
    cuota: Number(f.cuota) === 2 ? 2 : 1,
    dimension,
    diasDeGracia: Number(f.grace_days ?? 0),
    diasTarde: Number(f.late_days ?? 30),
    baseDelNivel: base
      ? { historial: Number(base.history ?? 0), actual: Number(base.current ?? 0) }
      : null,
    total: leerCifrasPrimeraCuota(f.total),
    filas: comoLista(f.rows).map((r) => {
      const fila = comoFila(r)
      return {
        ...leerCifrasPrimeraCuota(r),
        clave: String(fila.key),
        rotulo: textoONulo(fila.label) ?? String(fila.key),
      }
    }),
  }
}

/**
 * La fila de la misma clave (la misma semana, el mismo local…) en el impago
 * de la otra cuota: para leer las dos cuotas de los mismos consumos lado a
 * lado. `null` si la otra aún no se leyó o no tiene esa clave.
 */
export function filaDeLaMismaClave(otra: PrimeraCuota | undefined, clave: string): FilaPrimeraCuota | null {
  return otra?.filas.find((f) => f.clave === clave) ?? null
}

/**
 * El impago de la cuota 2 entre lo que hay en pantalla: la elegida si es la
 * 2, o la otra si ya llegó y es la 2. De ahí sale «de quien pagó la cuota 1,
 * qué parte no paga la 2», que se enseña se mire la cuota que se mire.
 */
export function impagoDeLaCuota2(
  elegida: PrimeraCuota,
  otra: PrimeraCuota | undefined,
): PrimeraCuota | undefined {
  if (elegida.cuota === 2) return elegida
  return otra?.cuota === 2 && otra.dimension === elegida.dimension ? otra : undefined
}

// ── Uso del cupo (`admin_credit_utilization`) ──────────────────────────────

/** Qué parte de su límite tiene ocupada cada persona. */
export type TramoDeUso = '0' | '1-25' | '26-50' | '51-75' | '76-99' | '100'

export const TRAMOS_DE_USO: ReadonlyArray<{ clave: TramoDeUso; rotulo: string }> = [
  { clave: '0', rotulo: 'Sin usar' },
  { clave: '1-25', rotulo: 'Hasta el 25 %' },
  { clave: '26-50', rotulo: 'Del 26 al 50 %' },
  { clave: '51-75', rotulo: 'Del 51 al 75 %' },
  { clave: '76-99', rotulo: 'Del 76 al 99 %' },
  { clave: '100', rotulo: 'Al tope' },
]

/** Montos de consumo (financed). */
export type UsoDeNivel = {
  nivel: number
  rotulo: string
  /** Límite por persona. */
  limite: number
  personas: number
  activas: number
  /** Con algo de cupo ocupado. */
  usando: number
  cupoTotal: number
  ocupado: number
  /** El cupo sin ocupar: el límite menos lo ocupado, sin mirar si hoy se puede gastar. */
  disponible: number
  /**
   * Lo que se puede gastar hoy: el disponible de quien puede tomar deuda, y
   * cero para quien tiene una cuota vencida, la cuenta sin activar o un
   * bloqueo. `null` si la base no lo manda.
   */
  gastableHoy: number | null
  /** El principal que falta por volver. */
  exposicion: number
  usoPct: number | null
  tramos: Record<TramoDeUso, number>
}

export type UsoDelCupo = {
  businessDate: string
  niveles: UsoDeNivel[]
  /** Gente en nivel 0 o en un nivel apagado que aun así debe algo. */
  fueraDeNivel: { personas: number; ocupado: number; exposicion: number }
  total: {
    personas: number
    usando: number
    cupoTotal: number
    /** Estos dos suman a todo el mundo, niveles y `fueraDeNivel`. */
    ocupado: number
    exposicion: number
    disponible: number
    /** Ver `UsoDeNivel.gastableHoy`. Solo los niveles activos. */
    gastableHoy: number | null
    usoPct: number | null
  }
}

function leerTramosDeUso(raw: unknown): Record<TramoDeUso, number> {
  const salida: Record<TramoDeUso, number> = {
    '0': 0,
    '1-25': 0,
    '26-50': 0,
    '51-75': 0,
    '76-99': 0,
    '100': 0,
  }
  for (const t of comoLista(raw)) {
    const f = comoFila(t)
    const tramo = TRAMOS_DE_USO.find((x) => x.clave === f.key)
    if (tramo) salida[tramo.clave] = Number(f.count ?? 0)
  }
  return salida
}

export function leerUsoDelCupo(raw: unknown): UsoDelCupo {
  const f = comoFila(raw)
  const fuera = comoFila(f.outside_levels)
  const total = comoFila(f.total)
  return {
    businessDate: textoONulo(f.business_date) ?? '',
    niveles: comoLista(f.levels).map((r) => {
      const n = comoFila(r)
      return {
        nivel: Number(n.level),
        rotulo: textoONulo(n.label) ?? `Nivel ${String(n.level)}`,
        limite: Number(n.limit_usd ?? 0),
        personas: Number(n.user_count ?? 0),
        activas: Number(n.active_count ?? 0),
        usando: Number(n.using_count ?? 0),
        cupoTotal: Number(n.limit_total_usd ?? 0),
        ocupado: Number(n.used_financed_usd ?? 0),
        disponible: Number(n.available_financed_usd ?? 0),
        gastableHoy: numeroONulo(n.spendable_now_usd),
        exposicion: Number(n.exposure_financed_usd ?? 0),
        usoPct: numeroONulo(n.usage_pct),
        tramos: leerTramosDeUso(n.buckets),
      }
    }),
    fueraDeNivel: {
      personas: Number(fuera.user_count ?? 0),
      ocupado: Number(fuera.used_financed_usd ?? 0),
      exposicion: Number(fuera.exposure_financed_usd ?? 0),
    },
    total: {
      personas: Number(total.user_count ?? 0),
      usando: Number(total.using_count ?? 0),
      cupoTotal: Number(total.limit_total_usd ?? 0),
      ocupado: Number(total.used_financed_usd ?? 0),
      exposicion: Number(total.exposure_financed_usd ?? 0),
      disponible: Number(total.available_financed_usd ?? 0),
      gastableHoy: numeroONulo(total.spendable_now_usd),
      usoPct: numeroONulo(total.usage_pct),
    },
  }
}

// ── Locales por volumen (`admin_merchant_risk`) ────────────────────────────

export type LocalPorVolumen = {
  id: string
  nombre: string
  consumos: number
  /** Consumo (financed). `null` si la base aún no lo manda. */
  financiado: number | null
  /** Personas con cuotas en sus consumos. */
  personas: number | null
  /** Consumos por cada persona que los abrió: un número alto con poca gente es la forma del fraude de local. */
  consumosPorPersona: number
  /** Deuda vencida y cobrable sobre la deuda que generó (payable sobre payable). */
  moraPct: number | null
  /** Su parte del consumo total del periodo. */
  cuotaDelVolumen: number | null
}

export function leerLocalesPorVolumen(raw: unknown): LocalPorVolumen[] {
  return comoLista(raw)
    .map((r) => {
      const f = comoFila(r)
      return {
        id: String(f.merchant_id),
        nombre: textoONulo(f.merchant_name) ?? 'Clínica sin nombre',
        consumos: Number(f.charge_count ?? 0),
        financiado: numeroONulo(f.financed_volume_usd),
        personas: numeroONulo(f.distinct_people),
        consumosPorPersona: Number(f.repeat_ratio ?? 0),
        moraPct: numeroONulo(f.overdue_debt_pct),
        cuotaDelVolumen: numeroONulo(f.volume_share_financed_pct),
      }
    })
    .sort((a, b) => (b.financiado ?? -1) - (a.financiado ?? -1))
}
