// ═══════════════════════════════════════════════════════════════════════════
// Asignar un abono sin dueño: qué cuotas cuadran con el monto y qué cargos
// por atraso viajan con ellas. Módulo puro (`asignarAbono.test.ts`).
//
// Al asignar, el servidor cotiza como si la persona pagara desde la app
// (`helios_quote_installments`): las cuotas marcadas, más los cargos por atraso
// pendientes de esas cuotas, más los que ya no tienen cuota pendiente (los
// «huérfanos», que van con el siguiente pago sea cual sea). Esto reproduce esa
// cuenta para avisar ANTES de que el monto no cuadre.
// ═══════════════════════════════════════════════════════════════════════════

/** Una cuota de la persona, como llega en su ficha. */
export type CuotaDeLaPersona = {
  id: string
  chargeId: string
  sequence: number
  /** PAYABLE: lo que se paga por esta cuota, con el service fee dentro. */
  amountUsd: number
  dueDate: string
  status: 'pending' | 'paid'
  merchantName: string
}

/** Un cargo por atraso de la persona. */
export type CargoDeLaPersona = {
  id: string
  amountUsd: number
  status: 'pending' | 'paid' | 'written_off'
  waivedAt: string | null
  /** La cuota que lo originó. Nula en los de antes del reparto por cuota. */
  installmentId: string | null
  /** El número, el vencimiento y el local de esa cuota, para nombrarla. Nulos en los viejos. */
  sequence: number | null
  dueDate: string | null
  merchantName: string | null
}

/**
 * La tolerancia de la sugerencia. No es una regla del negocio sino del
 * redondeo: el abono va a la tasa de su día y la cuota a la de la cotización,
 * y entre las dos se van céntimos, nunca un euro.
 */
export const TOLERANCIA_EUR = 1

/** Cuántas cuotas tiene cada consumo de la persona: el N de «cuota n de N». */
export function cuotasPorConsumo(cuotas: ReadonlyArray<Pick<CuotaDeLaPersona, 'chargeId'>>): Map<string, number> {
  const total = new Map<string, number>()
  for (const c of cuotas) total.set(c.chargeId, (total.get(c.chargeId) ?? 0) + 1)
  return total
}

/** Las pendientes, de la que vence antes a la que vence después. */
export function cuotasPendientes<T extends CuotaDeLaPersona>(cuotas: ReadonlyArray<T>): T[] {
  return cuotas
    .filter((c) => c.status !== 'paid')
    .sort((a, b) => a.dueDate.localeCompare(b.dueDate) || a.sequence - b.sequence)
}

export type RepartoDeCargos = {
  /** Los cargos de cada cuota pendiente, por id de cuota. */
  porCuota: Map<string, CargoDeLaPersona[]>
  /** Los que no son de ninguna cuota pendiente: viajan con cualquier pago. */
  huerfanos: CargoDeLaPersona[]
}

/**
 * A qué cuota pendiente pertenece cada cargo por atraso pendiente.
 *
 * Por el id de su cuota (`installment_id`), el mismo enlace que usa el
 * servidor al cotizar. Uno cuya cuota no está entre las pendientes es
 * huérfano: su cuota ya se pagó, o es de antes del reparto por cuota.
 */
export function repartirCargos(
  pendientes: ReadonlyArray<CuotaDeLaPersona>,
  cargos: ReadonlyArray<CargoDeLaPersona>,
): RepartoDeCargos {
  const porCuota = new Map<string, CargoDeLaPersona[]>()
  const huerfanos: CargoDeLaPersona[] = []

  for (const cargo of cargos) {
    if (cargo.status !== 'pending' || cargo.waivedAt !== null) continue
    const cuota =
      cargo.installmentId === null
        ? undefined
        : pendientes.find((c) => c.id === cargo.installmentId)
    if (!cuota) {
      huerfanos.push(cargo)
      continue
    }
    porCuota.set(cuota.id, [...(porCuota.get(cuota.id) ?? []), cargo])
  }

  return { porCuota, huerfanos }
}

/** Los cargos que viajarían con esta selección de cuotas. */
export function cargosQueViajan(
  seleccion: ReadonlySet<string>,
  reparto: RepartoDeCargos,
): CargoDeLaPersona[] {
  const deLasCuotas = [...seleccion].flatMap((id) => reparto.porCuota.get(id) ?? [])
  return seleccion.size === 0 ? [] : [...deLasCuotas, ...reparto.huerfanos]
}

/** Lo que cobraría el servidor por una selección: cuotas más sus cargos. */
export function montoDeLaSeleccion(
  pendientes: ReadonlyArray<CuotaDeLaPersona>,
  seleccion: ReadonlySet<string>,
  reparto: RepartoDeCargos,
): { cuotasUsd: number; cargosUsd: number } {
  const cuotasUsd = pendientes
    .filter((c) => seleccion.has(c.id))
    .reduce((s, c) => s + c.amountUsd, 0)
  const cargosUsd = cargosQueViajan(seleccion, reparto).reduce((s, c) => s + c.amountUsd, 0)
  return { cuotasUsd, cargosUsd }
}

/**
 * Las cuotas que cuadran con el monto del abono, dentro de la tolerancia.
 *
 * Primero se prueban las más viejas en orden (la primera, las dos primeras…),
 * que es lo que paga casi todo el mundo. Si ninguna tanda cuadra, una cuota
 * suelta, también de la más vieja a la más nueva: quien paga la segunda cuota
 * de una noche antes que la primera de otra. `null` si nada cuadra.
 */
export function sugerirCuotas(
  montoUsd: number,
  pendientes: ReadonlyArray<CuotaDeLaPersona>,
  reparto: RepartoDeCargos,
  tolerancia = TOLERANCIA_EUR,
): string[] | null {
  const cuadra = (ids: string[]) => {
    const { cuotasUsd, cargosUsd } = montoDeLaSeleccion(pendientes, new Set(ids), reparto)
    return Math.abs(montoUsd - cuotasUsd - cargosUsd) <= tolerancia
  }

  const ids = pendientes.map((c) => c.id)
  for (let n = 1; n <= ids.length; n++) {
    const tanda = ids.slice(0, n)
    if (cuadra(tanda)) return tanda
  }
  for (const id of ids) {
    if (cuadra([id])) return [id]
  }
  return null
}
