import type { PaymentReportStatus, QueueItem, StatementMatch } from '@/features/admin/api'
import { comoDia, comoTexto, unoDe } from '@/lib/busqueda'

// ═══════════════════════════════════════════════════════════════════════════
// La lista de Pagos reportados: sus filtros, su orden y el cotejo con el
// extracto. Módulo puro, sin React ni Supabase, para poder probarlo
// (`npx tsx src/features/admin/colaDePagos.test.ts`).
//
// `admin_payment_queue` filtra por estado y, en los resueltos, por el día
// operativo de la revisión (`p_from`, `p_to`). La búsqueda y el banco se
// aplican aquí, sobre lo que devuelve.
// ═══════════════════════════════════════════════════════════════════════════

/** Los tres momentos de la vida de un pago. Viajan en `?tab=`. */
export type EstadoCola = 'pendientes' | 'aprobados' | 'rechazados'

export const ESTADOS_DE_LA_COLA: ReadonlyArray<{ value: EstadoCola; label: string }> = [
  { value: 'pendientes', label: 'Pendientes' },
  { value: 'aprobados', label: 'Aprobados' },
  { value: 'rechazados', label: 'Rechazados' },
]

/** Qué estados de la base caen en cada uno. */
export const ESTADOS_POR_COLA: Record<EstadoCola, PaymentReportStatus[]> = {
  pendientes: ['reported', 'in_review'],
  aprobados: ['reconciled'],
  rechazados: ['rejected', 'duplicate'],
}

const VALORES_COLA: readonly EstadoCola[] = ['pendientes', 'aprobados', 'rechazados']

/**
 * Los filtros de la lista, tal como viajan en la URL.
 *
 * Los lee la lista y también la ficha de un pago: así «← Pagos reportados»
 * vuelve a la lista con los mismos filtros, y la cola que se recorre es la
 * que se estaba mirando.
 */
export type FiltrosPagos = {
  tab?: EstadoCola
  /** Persona, cédula, teléfono o referencia. */
  q?: string
  /** El nombre del banco, como lo guarda el reporte. */
  banco?: string
  /**
   * Día operativo en que se aprobó o se rechazó. Solo cuenta en Aprobados y
   * Rechazados, y lo aplica la base.
   */
  desde?: string
  hasta?: string
}

export function leerFiltrosPagos(s: Record<string, unknown>): FiltrosPagos {
  return {
    tab: unoDe(VALORES_COLA, s.tab),
    q: comoTexto(s.q, 80),
    banco: comoTexto(s.banco, 60),
    desde: comoDia(s.desde),
    hasta: comoDia(s.hasta),
  }
}

/** El estado de la cola que se mira; sin `tab`, los pendientes. */
export function colaDe(tab: string | undefined): EstadoCola {
  return unoDe(VALORES_COLA, tab) ?? 'pendientes'
}

// ── Búsqueda ──────────────────────────────────────────────────────────────

/** Minúsculas y sin tildes: «Pérez» y «perez» son la misma búsqueda. */
export function normalizarTexto(s: string): string {
  return s
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .trim()
}

function soloDigitos(s: string | null): string {
  return (s ?? '').replace(/\D/g, '')
}

/**
 * Si el pago es de quien se busca.
 *
 * El nombre se compara como texto. Las cifras se comparan por sus dígitos,
 * porque cada lado las escribe distinto: la base guarda el teléfono como
 * 584241234567 y la gente lo dicta como 0424-1234567, y la cédula llega con y
 * sin puntos. Con tres dígitos o menos no se busca por cifra: casarían todas.
 */
export function coincideBusqueda(item: QueueItem, q: string): boolean {
  const texto = normalizarTexto(q)
  if (texto === '') return true

  if (normalizarTexto(item.fullName ?? '').includes(texto)) return true
  if (normalizarTexto(item.reference ?? '').includes(texto)) return true

  const digitos = soloDigitos(q)
  if (digitos.length < 4) return false
  // El cero de «0424» no está en la base, que guarda el 58 delante.
  const sinCero = digitos.replace(/^0+/, '')

  return [item.phone, item.payerPhone, item.userDocument, item.payerDocument, item.reference]
    .map(soloDigitos)
    .some((campo) => campo !== '' && (campo.includes(digitos) || campo.includes(sinCero)))
}

// ── La lista ──────────────────────────────────────────────────────────────

/**
 * Los pagos que se ven, en el orden en que se trabajan.
 *
 * Los pendientes van del más viejo al más nuevo: la cola se despacha por
 * antigüedad. Los resueltos, al revés: lo último que se hizo, arriba. Las
 * fechas no se miran aquí: las aplica la base al pedir los resueltos.
 */
export function filtrarPagos(
  items: ReadonlyArray<QueueItem>,
  filtros: Pick<FiltrosPagos, 'q' | 'banco'>,
  cola: EstadoCola,
): QueueItem[] {
  return items
    .filter((p) => (filtros.q ? coincideBusqueda(p, filtros.q) : true))
    .filter((p) => (filtros.banco ? p.bank === filtros.banco : true))
    .sort((a, b) =>
      cola === 'pendientes'
        ? a.createdAt.localeCompare(b.createdAt)
        : b.createdAt.localeCompare(a.createdAt),
    )
}

/**
 * Los bancos que se pueden elegir: los de la lista de siempre y, además, los
 * que traigan los pagos y no estén en ella. Un banco que no se ofrece no se
 * puede filtrar, y es justo el raro el que se quiere mirar.
 */
export function bancosParaElFiltro(
  conocidos: ReadonlyArray<string>,
  items: ReadonlyArray<QueueItem>,
): string[] {
  const deLaCola = items.map((p) => p.bank).filter((b): b is string => b !== null)
  const extra = [...new Set(deLaCola)].filter((b) => !conocidos.includes(b)).sort()
  return [...conocidos, ...extra]
}

// ── El extracto ───────────────────────────────────────────────────────────

/**
 * A partir de cuántos días sin importar el extracto se avisa.
 *
 * No es un parámetro del negocio sino de la rutina de Caja: con el extracto
 * al día la cola se coteja sola, y a los tres días ya se aprueba a ciegas.
 */
export const DIAS_EXTRACTO_VIEJO = 3

/** `null` es que nunca se ha importado: también es viejo. */
export function extractoViejo(diasDesdeElUltimo: number | null): boolean {
  return diasDesdeElUltimo === null || diasDesdeElUltimo >= DIAS_EXTRACTO_VIEJO
}

/**
 * Lo que dice el extracto de un pago, en cinco casos y no en un conteo.
 *
 * Verde, ámbar y gris significan cosas distintas para quien decide: que el
 * banco confirma el pago, que hay que elegir entre varios movimientos, que el
 * único que encaja ya respalda otro pago, que la referencia está pero por otra
 * cifra (suele ser un error de tecleo), o que no hay nada con esa referencia.
 *
 * Solo cuentan como respaldo los movimientos libres: uno que ya respalda otro
 * pago o que se descartó sale en la lista, apagado, pero no vale.
 */
export type ResultadoCotejo =
  | { tipo: 'encontrado'; movimientos: StatementMatch[]; libre: StatementMatch }
  | { tipo: 'varios'; movimientos: StatementMatch[] }
  | { tipo: 'ya_usado'; movimientos: StatementMatch[] }
  | { tipo: 'monto_distinto'; movimientos: StatementMatch[] }
  | { tipo: 'no_encontrado' }

/**
 * Lo que dice el extracto de un pago en la lista, en pocas palabras. Un pago
 * con su movimiento ligado está encontrado aunque la referencia reportada no
 * case con la del banco: el movimiento lo eligió una persona. Sin ligar, solo
 * cuentan los movimientos libres; «Ya usado» es que el único que encaja
 * respalda otro pago.
 */
export function enElExtracto(
  p: Pick<QueueItem, 'statementMatches' | 'statementMatchesAvailable' | 'statementLine'>,
): string {
  if (p.statementLine !== null || p.statementMatchesAvailable === 1) return 'Encontrado'
  if (p.statementMatchesAvailable > 1) return `${p.statementMatchesAvailable} coinciden`
  if (p.statementMatches > 0) return 'Ya usado'
  return 'No aparece'
}

/**
 * @param coincidencias cuántos movimientos encajan del todo, según la cola.
 * @param exactos los movimientos con la tolerancia normal de monto.
 * @param amplios los que tienen la referencia, sea cual sea el monto.
 */
export function clasificarCotejo(
  coincidencias: number,
  exactos: ReadonlyArray<StatementMatch>,
  amplios: ReadonlyArray<StatementMatch>,
): ResultadoCotejo {
  if (coincidencias > 0 && exactos.length > 0) {
    const libres = exactos.filter((m) => m.disponible)
    if (libres.length === 1) return { tipo: 'encontrado', movimientos: [...exactos], libre: libres[0] }
    if (libres.length > 1) return { tipo: 'varios', movimientos: [...exactos] }
    return { tipo: 'ya_usado', movimientos: [...exactos] }
  }
  if (amplios.length > 0) return { tipo: 'monto_distinto', movimientos: [...amplios] }
  return { tipo: 'no_encontrado' }
}
