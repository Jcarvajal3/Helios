// ═══════════════════════════════════════════════════════════════════════════
// El cierre de mes: qué mes se cierra y qué comprobaciones pasa.
//
// Módulo puro (`cierreMes.test.ts`). Cada comprobación recibe los datos que ya
// devuelven las funciones de siempre y dice «hecho», «falta» o «todavía no»;
// que una consulta falle lo decide la pantalla, que es quien lo sabe.
// ═══════════════════════════════════════════════════════════════════════════

const MESES = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
]

/** Un mes, 'YYYY-MM', y que exista. Para `validateSearch`. */
export function comoMes(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined
  const m = /^(\d{4})-(\d{2})$/.exec(v)
  if (!m) return undefined
  const mes = Number(m[2])
  return mes >= 1 && mes <= 12 ? v : undefined
}

/** El mes al que pertenece un día. */
export function mesDe(dia: string): string {
  return dia.slice(0, 7)
}

/** El mes anterior a uno dado. */
export function mesAnteriorA(mes: string): string {
  const [y = 0, m = 1] = mes.split('-').map(Number)
  return new Date(Date.UTC(y, m - 2, 1)).toISOString().slice(0, 7)
}

export function primerDia(mes: string): string {
  return `${mes}-01`
}

export function ultimoDia(mes: string): string {
  const [y = 0, m = 1] = mes.split('-').map(Number)
  return new Date(Date.UTC(y, m, 0)).toISOString().slice(0, 10)
}

/** 'septiembre de 2026'. */
export function nombreDelMes(mes: string): string {
  const [y = '', m = ''] = mes.split('-')
  return `${MESES[Number(m) - 1] ?? m} de ${y}`
}

// ── Las comprobaciones ─────────────────────────────────────────────────────

export type EstadoDelPunto = 'hecho' | 'falta' | 'todavia_no'

export type Veredicto = { estado: EstadoDelPunto; detalle: string }

/** Un euro de diferencia ya es algo que nadie anotó; un céntimo es redondeo. */
export const CUADRA_CON_EL_BANCO = 0.5

/** El extracto tiene que llegar, al menos, al último día del mes. */
export function puntoExtracto(ultimoMovimiento: string | null, mes: string, hoy: string): Veredicto {
  const fin = ultimoDia(mes)
  if (ultimoMovimiento !== null && ultimoMovimiento >= fin) {
    return { estado: 'hecho', detalle: `El extracto llega hasta el ${formatear(ultimoMovimiento)}.` }
  }
  if (hoy <= fin) {
    return { estado: 'todavia_no', detalle: 'El mes todavía no ha terminado.' }
  }
  return {
    estado: 'falta',
    detalle:
      ultimoMovimiento === null
        ? 'Nunca se ha importado un extracto del banco.'
        : `El extracto importado llega hasta el ${formatear(ultimoMovimiento)} y el mes termina el ${formatear(fin)}.`,
  }
}

/**
 * Ningún abono del extracto de ese mes (o de antes) puede quedar sin dueño.
 * Los que entraron después del mes no cuentan para este cierre.
 *
 * @param truncado si la consulta llegó a su tope: puede haber más.
 */
export function puntoAbonos(
  abonos: ReadonlyArray<{ movedOn: string }>,
  mes: string,
  truncado: boolean,
): Veredicto {
  const fin = ultimoDia(mes)
  const delMes = abonos.filter((a) => a.movedOn <= fin).length
  if (delMes === 0 && !truncado) {
    return { estado: 'hecho', detalle: 'Todo el dinero que entró hasta final de mes tiene dueño.' }
  }
  return {
    estado: 'falta',
    detalle:
      delMes === 0
        ? 'Hay demasiados abonos sin dueño para saber si alguno es de este mes.'
        : `${delMes} ${delMes === 1 ? 'abono entró' : 'abonos entraron'} hasta final de mes y ${delMes === 1 ? 'sigue' : 'siguen'} sin dueño.`,
  }
}

/**
 * El saldo del banco apuntado el último día del mes, y cuadrando con el libro.
 *
 * @param cortes los cortes apuntados, del más reciente al más viejo.
 * @param completos si la lista trae todos los cortes y no solo los últimos.
 */
export function puntoBanco(
  cortes: ReadonlyArray<{ checkedOn: string; differenceUsd: number }>,
  mes: string,
  hoy: string,
  completos: boolean,
): Veredicto {
  const fin = ultimoDia(mes)
  const corte = cortes.find((c) => c.checkedOn === fin)

  if (!corte) {
    if (hoy < fin) return { estado: 'todavia_no', detalle: 'El mes todavía no ha terminado.' }
    const masViejo = cortes.at(-1)?.checkedOn
    if (!completos && masViejo !== undefined && masViejo > fin) {
      return {
        estado: 'falta',
        detalle: 'El corte de ese día es anterior a los que se pueden leer aquí. Búscalo en Dinero.',
      }
    }
    return { estado: 'falta', detalle: `Falta apuntar el saldo del banco del ${formatear(fin)}.` }
  }

  const diferencia = corte.differenceUsd
  if (Math.abs(diferencia) < CUADRA_CON_EL_BANCO) {
    return { estado: 'hecho', detalle: `El corte del ${formatear(fin)} cuadra con el libro.` }
  }
  return {
    estado: 'falta',
    detalle: `El corte del ${formatear(fin)} no cuadra: el banco tiene ${euros(Math.abs(diferencia))} ${
      diferencia > 0 ? 'más' : 'menos'
    } que el libro.`,
  }
}

/** El balance de comprobación del mes suma cero. */
export function puntoLibro(descuadre: number, asientos: number, tolerancia: number): Veredicto {
  if (asientos === 0) return { estado: 'hecho', detalle: 'El mes no tiene asientos.' }
  if (Math.abs(descuadre) < tolerancia) {
    return { estado: 'hecho', detalle: `Los ${asientos} asientos del mes suman cero.` }
  }
  return { estado: 'falta', detalle: `El balance de comprobación no suma cero: descuadra ${euros(Math.abs(descuadre))}.` }
}

/**
 * Los locales tienen transferido lo que tocaba pagar en el mes: los días de
 * pago (los «cierres» de la base; desde el 2026-10-06, uno por día) que caen
 * dentro del mes están saldados.
 */
export function puntoLocales(
  cierres: ReadonlyArray<{ runDate: string; pendienteUsd: number; isPast: boolean }>,
  mes: string,
): Veredicto & { primerPendiente: string | null } {
  const delMes = cierres.filter((c) => mesDe(c.runDate) === mes)
  const pendientes = delMes
    .filter((c) => c.isPast && c.pendienteUsd > 0.005)
    .sort((a, b) => a.runDate.localeCompare(b.runDate))
  const porLlegar = delMes.filter((c) => !c.isPast)

  if (pendientes.length > 0) {
    const total = pendientes.reduce((s, c) => s + c.pendienteUsd, 0)
    return {
      estado: 'falta',
      detalle: `Quedan ${euros(total)} sin transferir de ${pendientes.length} ${
        pendientes.length === 1 ? 'día de pago' : 'días de pago'
      } del mes.`,
      primerPendiente: pendientes[0]?.runDate ?? null,
    }
  }
  if (porLlegar.length > 0) {
    return { estado: 'todavia_no', detalle: 'Algún día de pago del mes todavía no ha llegado.', primerPendiente: null }
  }
  return {
    estado: 'hecho',
    detalle:
      delMes.length === 0
        ? 'No hubo pagos a clínicas en el mes.'
        : delMes.length === 1
          ? 'El único día de pago del mes está saldado.'
          : `Los ${delMes.length} días de pago del mes están saldados.`,
    primerPendiente: null,
  }
}

// ── Formatos sin React ─────────────────────────────────────────────────────

function formatear(dia: string): string {
  const [y = '', m = '', d = ''] = dia.split('-')
  return `${d}/${m}/${y.slice(2)}`
}

function euros(n: number): string {
  return `$${n.toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}
