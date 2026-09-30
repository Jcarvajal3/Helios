import type { Resumen } from '@/components/admin/inicio/colas'

/**
 * Lo que dice el contador de un ítem del menú: cuántos esperan y si alguno ya
 * se pasó de su plazo. Neutro casi siempre; rojo solo si `urgente`.
 */
export type Contador = { n: number; urgente: boolean }

/**
 * El contador de una cola, a partir del mismo resumen que pinta Inicio.
 *
 * Urgente es exactamente lo que Inicio pone arriba del todo en «Tu cola»
 * (`plazo: 'pasado'`): un pago reportado o una verificación que ya esperó más
 * de un día, o deuda vencida sin ninguna gestión. Lo de hoy y lo que puede
 * esperar va en neutro. Así el rojo del menú y el orden de Inicio no pueden
 * discrepar: salen de la misma regla.
 */
export function contadorDeCola(resumen: Pick<Resumen, 'cantidad' | 'plazo'>): Contador {
  return { n: resumen.cantidad, urgente: resumen.cantidad > 0 && resumen.plazo === 'pasado' }
}

/**
 * Varios contadores en uno: dos colas en la misma pantalla, o un grupo del
 * menú plegado. Sin leer ninguno, nada; urgente si lo es cualquiera.
 */
export function sumarContadores(
  contadores: ReadonlyArray<Contador | undefined>,
): Contador | undefined {
  const leidos = contadores.filter((c): c is Contador => c !== undefined)
  if (leidos.length === 0) return undefined
  return {
    n: leidos.reduce((suma, c) => suma + c.n, 0),
    urgente: leidos.some((c) => c.urgente),
  }
}

/** La cifra que cabe en la pastilla. */
export function cifraDelContador(n: number): string {
  return n > 99 ? '99+' : String(n)
}

/** Lo que oye un lector de pantalla en lugar del número suelto. */
export function rotuloDelContador(contador: Contador): string {
  const cuantos = `${contador.n} ${contador.n === 1 ? 'pendiente' : 'pendientes'}`
  return contador.urgente ? `${cuantos}, con atraso` : cuantos
}
