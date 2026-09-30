import { aBolivares } from '@/features/admin/liquidaciones'
import type { PayoutMethod } from '@/features/admin/liquidaciones'
import { comoFila, numero, numeroONulo, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Registrar un pago que llegó por WhatsApp (contrato §2.1, plan §7.1).
//
// El paciente paga y manda la captura al WhatsApp de Helios; el equipo lo
// registra aquí y el pago cae en la cola de «Pagos reportados», donde se
// aprueba contra el extracto como cualquier otro.
//
// Módulo puro: qué cuotas se pueden marcar (lo vencido primero), cuánto
// debería decir el comprobante en bolívares, la ruta de la captura y cómo se
// explica el doble control. Lo prueba `registrarPago.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Una cuota pendiente del paciente, como se elige al registrar. */
export type CuotaParaPagar = {
  id: string
  chargeId: string
  orderNumber: number | null
  sequence: number
  /** PAYABLE: la cuota con su parte del service fee dentro. */
  amountUsd: number
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

// ── Bolívares ──────────────────────────────────────────────────────────────

/**
 * Lo que debería decir el comprobante en bolívares, a la tasa BCV de hoy.
 * `null` sin tasa: no se inventa.
 */
export function bolivaresEsperados(totalUsd: number, tasa: number | null): number | null {
  return tasa === null || tasa <= 0 ? null : aBolivares(totalUsd, tasa)
}

/** La tolerancia del cruce con el extracto (plan §7.1): ±1 Bs. */
export const TOLERANCIA_BS = 1

export type DiferenciaEnBs = {
  /** Escrito − esperado. Positivo: pagó de más. */
  bs: number
  /** Lo mismo en dólares a la tasa del día. */
  usd: number
  /** Dentro de la tolerancia: se da por cuadrado. */
  cuadra: boolean
}

/** Cuánto se aparta lo escrito de lo esperado. `null` si falta alguno de los dos. */
export function diferenciaEnBs(
  escritoBs: number | null,
  esperadoBs: number | null,
  tasa: number | null,
): DiferenciaEnBs | null {
  if (escritoBs === null || esperadoBs === null || tasa === null || tasa <= 0) return null
  const bs = redondear(escritoBs - esperadoBs)
  return { bs, usd: redondear(bs / tasa), cuadra: Math.abs(bs) <= TOLERANCIA_BS }
}

/** Si el medio se paga en bolívares: el monto del comprobante es en Bs. */
export function medioEnBolivares(metodo: PayoutMethod): boolean {
  return metodo === 'pago_movil' || metodo === 'transferencia'
}

/** Si el medio lleva banco. */
export function medioConBanco(metodo: PayoutMethod): boolean {
  return metodo === 'pago_movil' || metodo === 'transferencia'
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
