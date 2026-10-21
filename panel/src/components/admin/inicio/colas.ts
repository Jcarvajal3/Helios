import { formatUsd, formatWaiting } from '@/components/ui'
import type { MerchantPayable, QueueItem } from '@/features/admin/api'
import { desgloseCorto, idsSinRepetir, pasaElFiltro, recuentoPorFiltro, sumasDeCartera } from '@/features/admin/cobranza/cartera'
import type { CollectionRow, FilaCartera } from '@/features/admin/cobranza/cartera'
import { promesasDelEstado } from '@/features/admin/cobranza/promesas'
import type { Promesas } from '@/features/admin/cobranza/promesas'
import { filtrarPagos } from '@/features/admin/colaDePagos'
import { payablesTotals } from '@/features/admin/definitions'
import type { UnmatchedDeposit } from '@/features/admin/deposits'
import type { RecuentoDeAlertas } from '@/features/admin/riesgo/alertas'
import { colaDeTrabajo, rebotadosSinCorregir } from '@/features/admin/avisos/avisos'
import type { Aviso } from '@/features/admin/avisos/avisos'
import type { CambioPropuesto } from '@/features/admin/pacientes/datos'

// ═══════════════════════════════════════════════════════════════════════════
// «Tu cola»: una fila por cada lista de trabajo de los equipos de la persona.
//
// Módulo puro. Cada cola se resume en cuántos hay, el dato que urge y su
// plazo, y la lista se ordena por ese plazo: arriba lo que ya se pasó,
// después lo de hoy y al final lo que puede esperar. Las colas vacías van
// abajo del todo. Los números salen de las mismas reglas que sus pantallas,
// así que la fila y la lista a la que lleva no pueden discrepar.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Cuánto urge una cola.
 *
 *   pasado         alguien ya esperó más de lo que debía, o la deuda venció
 *   hoy            hay que hacerlo hoy
 *   puede_esperar  hay trabajo, pero nadie se queda sin poder usar Ronda
 */
export type Plazo = 'pasado' | 'hoy' | 'puede_esperar'

/**
 * Horas que puede esperar un pago reportado antes de contar como tarde. Es
 * el primer tramo de la cola de pagos en `admin_reconciliation_health`.
 */
export const HORAS_DE_ESPERA = 24

export type IdCola =
  | 'pagos-reportados'
  | 'abonos'
  | 'pagos-a-locales'
  | 'pago-de-hoy'
  | 'promesas-hoy'
  | 'sin-contactar'
  | 'alertas-altas'
  | 'avisos-hoy'
  | 'correos-rebotados'
  | 'cambios-propuestos'

/** Lo que dice una cola que se pudo leer. */
export type Resumen = {
  cantidad: number
  /** La consulta llegó a su tope: hay al menos `cantidad`, quizá más. */
  alTope: boolean
  /** El dato que urge, en una frase. `null` si no hay nada que decir. */
  detalle: string | null
  plazo: Plazo
  /** Los ids en el orden en que se recorren, para el modo cola. */
  ids: string[]
}

/** Una cola que todavía no se leyó, que falló o que ya está. */
export type Lectura =
  | { estado: 'cargando' }
  | { estado: 'error'; reintentar: () => void }
  | { estado: 'listo'; resumen: Resumen }

function resumen(parte: Partial<Resumen> & Pick<Resumen, 'cantidad' | 'plazo' | 'ids'>): Resumen {
  return { alTope: false, detalle: null, ...parte }
}

function segundosDesde(instante: string, ahora: number): number {
  return Math.max(0, Math.round((ahora - new Date(instante).getTime()) / 1000))
}

function plazoPorEspera(segundos: number | null): Plazo {
  return segundos !== null && segundos >= HORAS_DE_ESPERA * 3600 ? 'pasado' : 'hoy'
}

function suma<T>(filas: ReadonlyArray<T>, valor: (f: T) => number): number {
  return filas.reduce((s, f) => s + valor(f), 0)
}

// ── Caja ───────────────────────────────────────────────────────────────────

/** Los pagos por aprobar, del más viejo al más nuevo: el orden de su lista. */
export function resumirPagosReportados(items: ReadonlyArray<QueueItem>, ahora: number): Resumen {
  const orden = filtrarPagos(items, {}, 'pendientes')
  const primero = orden.at(0)
  const espera = primero ? segundosDesde(primero.createdAt, ahora) : null
  return resumen({
    cantidad: orden.length,
    detalle: espera === null ? null : `El más viejo espera ${formatWaiting(espera)}`,
    plazo: plazoPorEspera(espera),
    ids: orden.map((p) => p.reportId),
  })
}

/**
 * El dinero que entró y nadie reclamó. Un abono sin tasa del día no tiene
 * equivalente en euros y no se suma: se dice cuántos son.
 */
export function resumirAbonos(
  todos: ReadonlyArray<Pick<UnmatchedDeposit, 'id' | 'amountUsd'> & { deHelios?: boolean }>,
  tope: number,
): Resumen {
  // Los que casi seguro son de Ronda (misma cuenta del BNC) no son trabajo de Helios.
  const abonos = todos.filter((a) => a.deHelios !== false)
  const enEuros = suma(abonos, (a) => a.amountUsd ?? 0)
  const sinTasa = abonos.filter((a) => a.amountUsd === null).length
  return resumen({
    cantidad: abonos.length,
    alTope: abonos.length >= tope,
    detalle:
      abonos.length === 0
        ? null
        : `${formatUsd(enEuros)} sin asignar${sinTasa > 0 ? `, y ${sinTasa} sin tasa del día` : ''}`,
    plazo: 'hoy',
    ids: abonos.map((a) => a.id),
  })
}

/**
 * Las clínicas a las que toca pagarles hoy (sin lo atrasado, que es su propia
 * cola). Es la tarea de cada día: a la clínica se le paga el día siguiente a
 * cada vencimiento, así que casi todos los días hay algo.
 */
export function resumirPagoDeHoy(liquidaciones: ReadonlyArray<MerchantPayable>): Resumen {
  const deHoy = liquidaciones.filter((m) => !m.isTest && m.nextRunUsd - m.overdueUsd > 0.005)
  const usd = deHoy.reduce((s, m) => s + (m.nextRunUsd - m.overdueUsd), 0)
  return resumen({
    cantidad: deHoy.length,
    detalle: deHoy.length > 0 ? `${formatUsd(usd)} por transferir hoy` : null,
    plazo: 'hoy',
    ids: deHoy.map((m) => m.merchantId),
  })
}

/** Los locales con pagos de días anteriores sin transferir. Ya es un atraso. */
export function resumirPagosALocales(liquidaciones: ReadonlyArray<MerchantPayable>): Resumen {
  const totales = payablesTotals([...liquidaciones])
  return resumen({
    cantidad: totales.localesAtrasados,
    detalle: totales.localesAtrasados > 0 ? `${formatUsd(totales.atrasado)} sin transferir` : null,
    plazo: 'pasado',
    ids: liquidaciones.filter((m) => !m.isTest && m.overdueUsd > 0).map((m) => m.merchantId),
  })
}

// ── Cobranza ───────────────────────────────────────────────────────────────

/**
 * Las promesas que vencen hoy. La deuda se suma una vez por usuario: quien
 * prometió dos veces no debe el doble. Es deuda (consumo + fee): va con sus
 * dos partes.
 */
export function resumirPromesasDeHoy(p: Promesas): Resumen {
  const filas = promesasDelEstado(p.filas, 'vence_hoy')
  const ids = idsSinRepetir(filas.map((f) => f.userId))
  const una = (id: string) => filas.find((f) => f.userId === id)
  const deuda = suma(ids, (id) => una(id)?.vencidoHoyUsd ?? 0)
  const partes = {
    financedUsd: suma(ids, (id) => una(id)?.vencidoHoyFinancedUsd ?? 0),
    feeUsd: suma(ids, (id) => una(id)?.vencidoHoyFeeUsd ?? 0),
  }
  return resumen({
    cantidad: p.recuento.vence_hoy,
    detalle:
      filas.length === 0
        ? null
        : deuda > 0
          ? `Deben ${formatUsd(deuda)} vencidos (${desgloseCorto(partes)}) y no han reportado el pago`
          : 'Todavía no han reportado el pago',
    plazo: 'hoy',
    ids,
  })
}

/**
 * El orden de la cartera vencida: el más atrasado primero y, a igual atraso,
 * el que más debe. Es el mismo que usa `CarteraVencida`, para que la cola que
 * se abre desde aquí sea la misma que se abre desde la lista.
 */
export function ordenarComoLaCartera<T extends Pick<CollectionRow, 'daysOverdue' | 'overdueUsd'>>(
  filas: ReadonlyArray<T>,
): T[] {
  return [...filas].sort((a, b) => b.daysOverdue - a.daysOverdue || b.overdueUsd - a.overdueUsd)
}

/** Lo que se lee de cada fila de la cartera para estas dos colas. */
export type FilaParaLaCola = FilaCartera &
  Pick<CollectionRow, 'userId' | 'upcomingUsd'> &
  Partial<Pick<CollectionRow, 'overdueDesglose' | 'upcomingDesglose'>>

/**
 * «Vencidos sin contactar», con la regla de la cartera vencida: el número
 * es el del filtro que abre su enlace. El importe es
 * deuda (consumo + fee) y va con sus dos partes cuando la base las manda.
 */
export function resumirCartera(
  filas: ReadonlyArray<FilaParaLaCola>,
  filtro: 'sin_contactar',
  hoy: string,
): Resumen {
  // Este filtro no depende de los tramos: no hacen falta los cortes.
  const ctx = { hoy, cortes: null }
  const del = ordenarComoLaCartera(filas.filter((f) => pasaElFiltro(f, filtro, ctx)))
  const cantidad = recuentoPorFiltro(filas, ctx)[filtro]
  const sumas = sumasDeCartera(del)
  const partes = (p: typeof sumas.vencidoDesglose) => (p ? ` (${desgloseCorto(p)})` : '')
  const detalle =
    del.length === 0
      ? null
      : `${formatUsd(sumas.vencidoUsd)} vencidos${partes(sumas.vencidoDesglose)} sin gestión desde que vencieron`
  return resumen({
    cantidad,
    detalle,
    plazo: 'pasado',
    ids: del.map((f) => f.userId),
  })
}

// ── Riesgo ─────────────────────────────────────────────────────────────────

/**
 * Las alertas de gravedad alta sin revisar, de los contadores de la base
 * (`admin_risk_alert_counts`): la misma cifra que la insignia y que Riesgo.
 * Las alertas no tienen ficha, así que la cola no lleva ids: abre la lista.
 */
export function resumirAlertasAltas(r: RecuentoDeAlertas): Resumen {
  return resumen({
    cantidad: r.pendientesAltas,
    detalle:
      r.pendientesMedias > 0
        ? `Además hay ${r.pendientesMedias} de gravedad media sin revisar`
        : null,
    plazo: 'hoy',
    ids: [],
  })
}


// ── Avisos y datos de los pacientes ────────────────────────────────────────

/**
 * Los avisos de WhatsApp de hoy que nadie ha mandado, en el orden de su
 * pantalla (grupo a grupo). Son de hoy: mañana ya no sirven.
 */
export function resumirAvisosDeHoy(avisos: ReadonlyArray<Aviso>): Resumen {
  const cola = colaDeTrabajo(avisos)
  const grupos = new Set(cola.map((a) => a.templateLabel))
  return resumen({
    cantidad: cola.length,
    detalle:
      cola.length === 0
        ? null
        : `Por mandar por WhatsApp: ${[...grupos].slice(0, 3).join(', ')}${grupos.size > 3 ? '…' : ''}`,
    plazo: 'hoy',
    ids: cola.map((a) => a.id),
  })
}

/**
 * Los comprobantes que rebotaron y nadie ha reenviado a un correo que
 * funcione: esos pacientes no tienen el papel de lo que deben.
 */
export function resumirCorreosRebotados(correos: ReadonlyArray<Aviso>): Resumen {
  const rebotados = rebotadosSinCorregir(correos)
  return resumen({
    cantidad: rebotados.length,
    detalle: rebotados.length === 0 ? null : 'El comprobante no les llegó: corrige el correo y reenvíalo',
    plazo: 'hoy',
    ids: rebotados.flatMap((c) => (c.profileId ? [c.profileId] : [])),
  })
}

/** Los cambios de datos que propusieron las clínicas y esperan a Helios. */
export function resumirCambiosPropuestos(cambios: ReadonlyArray<Pick<CambioPropuesto, 'profileId'>>): Resumen {
  return resumen({
    cantidad: cambios.length,
    detalle: cambios.length === 0 ? null : 'Una clínica registró a un paciente conocido con otros datos',
    plazo: 'puede_esperar',
    ids: idsSinRepetir(cambios.map((c) => c.profileId)),
  })
}

// ── El orden de la lista ───────────────────────────────────────────────────

/**
 * El puesto de una cola en la lista. Una lectura fallida va detrás de lo
 * urgente y delante de lo que puede esperar: puede esconder trabajo de hoy.
 */
export function puestoDe(lectura: Lectura): number {
  if (lectura.estado === 'error') return 2
  if (lectura.estado === 'cargando') return 4
  if (lectura.resumen.cantidad === 0) return 5
  return { pasado: 0, hoy: 1, puede_esperar: 3 }[lectura.resumen.plazo]
}

/** Las colas por urgencia. A igual puesto, el orden en que llegaron. */
export function ordenarColas<T extends { lectura: Lectura }>(colas: ReadonlyArray<T>): T[] {
  return colas
    .map((cola, i) => ({ cola, i, puesto: puestoDe(cola.lectura) }))
    .sort((a, b) => a.puesto - b.puesto || a.i - b.i)
    .map((x) => x.cola)
}

/** Si la cola tiene algo que empezar. */
export function tieneTrabajo(lectura: Lectura): boolean {
  return lectura.estado === 'listo' && lectura.resumen.cantidad > 0
}
