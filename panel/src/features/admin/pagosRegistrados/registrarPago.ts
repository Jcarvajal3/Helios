import { formatMoneda, formatUsd, leerMoneda } from '@/components/ui'
import type { Moneda } from '@/components/ui'
import { comoFila, numero, numeroONulo, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Registrar un pago que llegó por WhatsApp (contrato §2.1, plan §7.1).
//
// El paciente paga y manda la captura al WhatsApp de Helios; el equipo lo
// registra aquí y el pago cae en la cola de «Pagos reportados», donde se
// aprueba contra el extracto como cualquier otro.
//
// Desde el 2026-10-07 el paciente solo paga en bolívares (Pago Móvil o
// transferencia), y cada cuota a la tasa BCV de la moneda de su orden del día
// en que pagó. Lo que debería decir el comprobante lo calcula la base
// (`admin_payment_preview`): aquí solo se lee y se compara.
//
// Módulo puro: qué cuotas se pueden marcar (lo vencido primero), cómo se
// compara lo escrito con lo esperado en bolívares, la ruta de la captura y
// cómo se explica el doble control. Lo prueba `registrarPago.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Cómo paga el paciente: solo en bolívares. Es una lista propia, separada de
 * los medios con que Helios le paga a una clínica (`METODOS_DE_PAGO` de
 * `liquidaciones.ts`), que siguen siendo los de siempre.
 */
export type MetodoDelPaciente = 'pago_movil' | 'transferencia'

export const METODOS_DEL_PACIENTE: Array<{ value: MetodoDelPaciente; label: string }> = [
  { value: 'pago_movil', label: 'Pago Móvil' },
  { value: 'transferencia', label: 'Transferencia' },
]

/** Una cuota pendiente del paciente, como se elige al registrar. */
export type CuotaParaPagar = {
  id: string
  chargeId: string
  orderNumber: number | null
  sequence: number
  /** PAYABLE: la cuota con su parte de la Comisión Helios dentro, en dólares. */
  amountUsd: number
  /** La moneda en que se cobró la orden: la de la tasa con que se paga. */
  moneda: Moneda
  /** La cuota en la moneda de su orden (en una de dólares, `amountUsd`). */
  amountCur: number
  dueDate: string
  merchantName: string
  /** Los cargos por atraso pendientes de esta cuota: viajan con ella. */
  lateFeesUsd: number
  /**
   * Ya tiene un pago registrado sin aprobar. No se exige para adelantar otra
   * (la base tampoco: `helios_quote_installments`), y marcarla la rechaza el
   * servidor.
   */
  enRevision: boolean
}

/** Las pendientes, de la que vence antes a la que vence después. */
export function ordenarCuotas<T extends Pick<CuotaParaPagar, 'dueDate' | 'sequence'>>(cuotas: ReadonlyArray<T>): T[] {
  return [...cuotas].sort((a, b) => a.dueDate.localeCompare(b.dueDate) || a.sequence - b.sequence)
}

/**
 * Las que vencen hoy o antes y se pueden pagar: las que hay que llevar si se
 * adelanta cualquier otra.
 */
export function cuotasExigibles(pendientes: ReadonlyArray<CuotaParaPagar>, hoy: string): CuotaParaPagar[] {
  return pendientes.filter((c) => c.dueDate <= hoy && !c.enRevision)
}

/**
 * Marcar o desmarcar una cuota, en cadena, con la regla de la base
 * (migración `lo_vencido_va_primero`): un pago que adelanta una cuota que
 * vence después de hoy tiene que llevar todas las que vencen hoy o antes.
 *
 *   · Marcar una por vencer marca también todas las exigibles.
 *   · Desmarcar una exigible con alguna por vencer marcada desmarca las por
 *     vencer: sin ella, adelantarlas ya no vale.
 *
 * Pagar solo lo vencido, o una parte, sigue valiendo. Una en revisión no se
 * marca.
 */
export function alternarCuota(
  seleccion: ReadonlySet<string>,
  id: string,
  pendientes: ReadonlyArray<CuotaParaPagar>,
  hoy: string,
): Set<string> {
  const cuota = pendientes.find((c) => c.id === id)
  const siguiente = new Set(seleccion)
  if (!cuota || cuota.enRevision) return siguiente

  const exigibles = cuotasExigibles(pendientes, hoy)
  const porVencer = (c: CuotaParaPagar) => c.dueDate > hoy

  if (siguiente.has(id)) {
    siguiente.delete(id)
    if (!porVencer(cuota)) {
      for (const c of pendientes) if (porVencer(c)) siguiente.delete(c.id)
    }
    return siguiente
  }

  siguiente.add(id)
  if (porVencer(cuota)) for (const c of exigibles) siguiente.add(c.id)
  return siguiente
}

/**
 * Por qué no se puede registrar esa selección, o `null` si se puede. Es la
 * misma comprobación que hará el servidor, para decirlo antes de subir la
 * captura.
 */
export function motivoDeSeleccion(
  seleccion: ReadonlySet<string>,
  pendientes: ReadonlyArray<CuotaParaPagar>,
  hoy: string,
): string | null {
  if (seleccion.size === 0) return 'Marca al menos una cuota.'
  const marcadas = pendientes.filter((c) => seleccion.has(c.id))
  if (marcadas.length !== seleccion.size) return 'Alguna de las cuotas marcadas ya no está pendiente.'
  if (marcadas.some((c) => c.enRevision)) return 'Alguna de las cuotas ya tiene un pago registrado sin aprobar.'

  const adelanta = marcadas.some((c) => c.dueDate > hoy)
  if (!adelanta) return null
  const faltan = cuotasExigibles(pendientes, hoy).filter((c) => !seleccion.has(c.id))
  if (faltan.length === 0) return null
  return faltan.length === 1
    ? 'Para adelantar una cuota hay que pagar también la que ya venció.'
    : `Para adelantar una cuota hay que pagar también las ${faltan.length} que ya vencieron.`
}

/**
 * Lo que cobra la selección: las cuotas (con fee) y sus cargos por atraso,
 * más los cargos sueltos —los de una cuota ya pagada o de antes del reparto
 * por cuota—, que el servidor cobra con cualquier pago.
 */
export function totalDeLaSeleccion(
  seleccion: ReadonlySet<string>,
  pendientes: ReadonlyArray<CuotaParaPagar>,
  cargosSueltosUsd = 0,
): { cuotasUsd: number; cargosUsd: number; totalUsd: number } {
  const marcadas = pendientes.filter((c) => seleccion.has(c.id))
  if (marcadas.length === 0) return { cuotasUsd: 0, cargosUsd: 0, totalUsd: 0 }
  const cuotasUsd = redondear(marcadas.reduce((s, c) => s + c.amountUsd, 0))
  const cargosUsd = redondear(marcadas.reduce((s, c) => s + c.lateFeesUsd, 0) + cargosSueltosUsd)
  return { cuotasUsd, cargosUsd, totalUsd: redondear(cuotasUsd + cargosUsd) }
}

/**
 * Las cuotas que se pueden elegir, a partir de la ficha del paciente: las
 * pendientes que no se dieron por perdidas, con sus cargos por atraso
 * pendientes, y los cargos que no son de ninguna de ellas (sueltos).
 */
export function armarCuotas(
  cuotas: ReadonlyArray<{
    id: string
    chargeId: string
    orderNumber: number | null
    sequence: number
    amountUsd: number
    /** Sin ella, dólares (una base anterior a 20261007000200). */
    currency?: Moneda
    amountCur?: number
    dueDate: string
    merchantName: string
    status: 'pending' | 'paid'
    writtenOffAt: string | null
  }>,
  cargos: ReadonlyArray<{
    installmentId: string | null
    amountUsd: number
    status: 'pending' | 'paid' | 'written_off'
    waivedAt: string | null
  }>,
  enRevision: ReadonlySet<string>,
): { cuotas: CuotaParaPagar[]; cargosSueltosUsd: number } {
  const pendientes = ordenarCuotas(cuotas.filter((c) => c.status === 'pending' && !c.writtenOffAt))
  const ids = new Set(pendientes.map((c) => c.id))
  const vivos = cargos.filter((f) => f.status === 'pending' && f.waivedAt === null)

  return {
    cuotas: pendientes.map((c) => ({
      id: c.id,
      chargeId: c.chargeId,
      orderNumber: c.orderNumber,
      sequence: c.sequence,
      amountUsd: c.amountUsd,
      moneda: leerMoneda(c.currency),
      amountCur: c.currency === 'EUR' ? (c.amountCur ?? c.amountUsd) : c.amountUsd,
      dueDate: c.dueDate,
      merchantName: c.merchantName,
      lateFeesUsd: redondear(vivos.filter((f) => f.installmentId === c.id).reduce((s, f) => s + f.amountUsd, 0)),
      enRevision: enRevision.has(c.id),
    })),
    cargosSueltosUsd: redondear(
      vivos.filter((f) => f.installmentId === null || !ids.has(f.installmentId)).reduce((s, f) => s + f.amountUsd, 0),
    ),
  }
}

function redondear(n: number): number {
  return Math.round(n * 100) / 100
}

/**
 * El monto de una cuota para elegirla: en dólares, y si su orden se cobró en
 * euros, también lo que es en euros, que es lo que el paciente paga a la tasa
 * del euro: «$63,39 · cobrada en €56,96».
 */
export function montoDeLaCuota(c: Pick<CuotaParaPagar, 'amountUsd' | 'moneda' | 'amountCur'>): string {
  return c.moneda === 'EUR'
    ? `${formatUsd(c.amountUsd)} · cobrada en ${formatMoneda(c.amountCur, 'EUR')}`
    : formatUsd(c.amountUsd)
}

// ── Bolívares ──────────────────────────────────────────────────────────────

/**
 * Lo que debería decir el comprobante para unas cuotas y un día, según la
 * base (`admin_payment_preview`): la parte en euros a la tasa BCV del euro de
 * ese día y el resto —cuotas en dólares y cargos por atraso— a la del dólar.
 */
export type PrevisionDelPago = {
  paidOn: string
  installmentsUsd: number
  lateFeeUsd: number
  /** Todo, en dólares: lo que entra al libro. */
  amountUsd: number
  /** Lo que va en euros, en euros (0 si ninguna cuota es de una orden en euros). */
  amountEur: number
  /** Lo que va en dólares, en dólares: cuotas en dólares y cargos por atraso. */
  amountUsdPart: number
  fxRate: number | null
  fxRateEur: number | null
  /** `null` si falta la tasa de alguna de las monedas de ese día. */
  amountVes: number | null
}

export function leerPrevisionDelPago(raw: unknown): PrevisionDelPago {
  const r = comoFila(raw)
  return {
    paidOn: texto(r.paid_on),
    installmentsUsd: numero(r.installments_usd),
    lateFeeUsd: numero(r.late_fee_usd),
    amountUsd: numero(r.amount_usd),
    amountEur: numero(r.amount_eur),
    amountUsdPart: numero(r.amount_usd_part),
    fxRate: numeroONulo(r.fx_rate),
    fxRateEur: numeroONulo(r.fx_rate_eur),
    amountVes: numeroONulo(r.amount_ves),
  }
}

/**
 * Con cuánto margen cuadra un pago con lo cotizado (Javier, 2026-10-26;
 * `helios_monto_cuadra` en la base): más holgura por encima que por debajo.
 * Son los parámetros `payment_margin_under_ves` y `payment_margin_over_ves`;
 * estos son sus valores por defecto, los mismos que usa la base sin ellos.
 */
export type MargenBs = { menosBs: number; masBs: number }
export const MARGEN_POR_DEFECTO: MargenBs = { menosBs: 10, masBs: 100 }

export type DiferenciaEnBs = {
  /** Escrito − esperado. Positivo: pagó de más. */
  bs: number
  /** Lo mismo en dólares a la tasa del dólar del día: una idea del tamaño, no un monto. */
  usd: number
  /** Dentro del margen: se da por cuadrado. */
  cuadra: boolean
}

/** Cuánto se aparta lo escrito de lo esperado. `null` si falta alguno de los dos. */
export function diferenciaEnBs(
  escritoBs: number | null,
  esperadoBs: number | null,
  tasa: number | null,
  margen: MargenBs = MARGEN_POR_DEFECTO,
): DiferenciaEnBs | null {
  if (escritoBs === null || esperadoBs === null || tasa === null || tasa <= 0) return null
  const bs = redondear(escritoBs - esperadoBs)
  return { bs, usd: redondear(bs / tasa), cuadra: bs >= -margen.menosBs && bs <= margen.masBs }
}

// ── La captura ─────────────────────────────────────────────────────────────

/** El bucket privado de las capturas de los pagos de los pacientes. */
export const BUCKET_COMPROBANTES = 'payment-receipts'

/** 10 MB: una captura de pantalla pesa mucho menos; un PDF del banco, también. */
export const TAMANO_MAXIMO_COMPROBANTE = 10 * 1024 * 1024

const EXTENSIONES: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'application/pdf': 'pdf',
}

/** La extensión del archivo: por su tipo, y si no, por su nombre. `null` si no es una imagen ni un PDF. */
export function extensionDelComprobante(archivo: { name: string; type: string }): string | null {
  const porTipo = EXTENSIONES[archivo.type]
  if (porTipo) return porTipo
  const ext = archivo.name.split('.').pop()?.toLowerCase() ?? ''
  if (ext === 'jpeg') return 'jpg'
  return Object.values(EXTENSIONES).includes(ext) ? ext : null
}

/** Por qué no vale el archivo, o `null`. */
export function motivoDeArchivo(archivo: { name: string; type: string; size: number }): string | null {
  if (!extensionDelComprobante(archivo)) return 'La captura tiene que ser una imagen (JPG, PNG, WEBP) o un PDF.'
  if (archivo.size > TAMANO_MAXIMO_COMPROBANTE) return 'La captura pesa más de 10 MB.'
  if (archivo.size === 0) return 'El archivo está vacío.'
  return null
}

/**
 * La ruta dentro del bucket: `<user_id>/<uuid>.<ext>`. Una carpeta por
 * paciente, como las transferencias a clínicas en `merchant-receipts`, y un
 * uuid para que dos capturas del mismo segundo no se pisen.
 */
export function rutaDelComprobante(userId: string, uuid: string, extension: string): string {
  return `${userId}/${uuid}.${extension}`
}

// ── La respuesta ───────────────────────────────────────────────────────────

export type PagoRegistrado = {
  reportId: string
  quoteId: string | null
  amountUsd: number
  lateFeeUsd: number
  fxRate: number | null
  /** La tasa del euro con que se cotizó la parte en euros; `null` si no la hubo. */
  fxRateEur: number | null
  /** La parte en euros, en euros; `null` o 0 si todo iba en dólares. */
  amountEur: number | null
  amountVes: number | null
  status: string
  /** Cuántas líneas del extracto casan (referencia + monto + fecha). */
  candidatosExtracto: number
}

export function leerPagoRegistrado(raw: unknown): PagoRegistrado {
  const r = comoFila(raw)
  return {
    reportId: texto(r.report_id),
    quoteId: textoONulo(r.quote_id),
    amountUsd: numero(r.amount_usd),
    lateFeeUsd: numero(r.late_fee_usd),
    fxRate: numeroONulo(r.fx_rate),
    fxRateEur: numeroONulo(r.fx_rate_eur),
    amountEur: numeroONulo(r.amount_eur),
    amountVes: numeroONulo(r.amount_ves),
    status: texto(r.status, 'reported'),
    candidatosExtracto: numero(r.candidatos_extracto),
  }
}

/** Lo que se dice del extracto justo después de registrar. */
export function fraseDelExtracto(candidatos: number): { texto: string; tono: 'success' | 'info' | 'warning' } {
  if (candidatos === 1) {
    return { texto: 'Hay un movimiento en el extracto que casa con este pago: se puede aprobar.', tono: 'success' }
  }
  if (candidatos > 1) {
    return {
      texto: `Hay ${candidatos} movimientos en el extracto que casan: al aprobar hay que elegir cuál lo respalda.`,
      tono: 'warning',
    }
  }
  return {
    texto: 'Todavía no aparece en el extracto. Puede que el banco no lo haya reflejado o que falte importar el extracto de ese día.',
    tono: 'info',
  }
}

// ── El doble control ───────────────────────────────────────────────────────

/**
 * El error de aprobar un pago, para enseñarlo. Con `payment_four_eyes = 1`,
 * quien registró un pago no puede aprobarlo (`42501`): se dice qué hacer, y
 * el texto del servidor va detrás tal cual.
 *
 * `42501` es también «sin permiso» o «falta el segundo factor»: solo se
 * explica como doble control si quien aprueba es quien lo registró, o si el
 * propio texto del servidor habla de ello.
 */
export function explicarErrorDeAprobacion(
  error: unknown,
  detalle: string | undefined,
  esQuienLoRegistro = false,
): string | undefined {
  const e = typeof error === 'object' && error !== null ? (error as { code?: unknown; message?: unknown }) : {}
  if (e.code !== '42501') return detalle
  const mensaje = typeof e.message === 'string' ? e.message : ''
  if (!esQuienLoRegistro && !/registr|doble control/i.test(mensaje)) return detalle
  const prefijo =
    'Doble control: quien registró este pago no puede aprobarlo. Pide a otra persona del equipo (o a un super admin) que lo apruebe.'
  return detalle ? `${prefijo} · ${detalle}` : prefijo
}
