import { strFromU8, strToU8, unzipSync, zipSync } from 'fflate'

import { filaONula, filas, numero, numeroONulo, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// El archivo de pago masivo del banco.
//
// A las clínicas se les paga con el «pago masivo a proveedores» del banco: se
// carga un .xlsm (`public/plantillas/pago-masivo.xlsm`, el del banco tal cual, con su
// macro «ANALIZAR REGISTROS») con una transferencia por fila en la hoja
// «Validar Datos». Aquí se decide quién entra y se llena la plantilla; los
// datos salen de `admin_bulk_payout_sheet`. Módulo puro: lo prueba
// `pagoMasivo.test.ts`.
//
// Solo transferencia: el pago masivo no acepta Pago Móvil. Una clínica sin
// cuenta de 20 dígitos queda fuera, dicha, y se le paga a mano.
// ═══════════════════════════════════════════════════════════════════════════

/** La cuenta a debitar que se sugiere: la cuenta de cobro activa de transferencia. */
export type CuentaADebitar = {
  bankName: string | null
  holderName: string | null
  accountNumber: string
}

/** Una clínica con algo en el pago de hoy, con su cuenta de pago. */
export type ClinicaDelPagoMasivo = {
  merchantId: string
  merchantName: string
  isTest: boolean
  email: string | null
  hasPayoutAccount: boolean
  bank: string | null
  accountHolder: string | null
  holderDocument: string | null
  /** La cuenta de transferencia, 20 dígitos. `null` = no tiene (quizá solo Pago Móvil). */
  accountNumber: string | null
  pagoMovilPhone: string | null
  lineas: number
  /** Lo que sale hoy, con lo atrasado: lo mismo que «Sale hoy» en la lista. */
  pendingUsd: number
  /** De eso, lo de órdenes en dólares y lo de órdenes en euros, cada uno en su moneda. */
  pendingUsdPart: number
  pendingEur: number
  /** En bolívares a la BCV de hoy de cada moneda. `null` si falta una tasa. */
  pendingVes: number | null
}

export type HojaDePagoMasivo = {
  todayDate: string
  fxRateUsd: number | null
  fxRateEur: number | null
  debitAccount: CuentaADebitar | null
  merchants: ClinicaDelPagoMasivo[]
}

/** `admin_bulk_payout_sheet`. */
export function leerHojaDePagoMasivo(raw: unknown): HojaDePagoMasivo {
  const r = filaONula(raw) ?? {}
  const d = filaONula(r.debit_account)
  const cuenta = d ? textoONulo(d.account_number) : null
  return {
    todayDate: String(r.today_date ?? ''),
    fxRateUsd: numeroONulo(r.fx_rate_usd),
    fxRateEur: numeroONulo(r.fx_rate_eur),
    debitAccount:
      d && cuenta
        ? { bankName: textoONulo(d.bank_name), holderName: textoONulo(d.holder_name), accountNumber: cuenta }
        : null,
    merchants: filas(r.merchants).map((m) => ({
      merchantId: String(m.merchant_id),
      merchantName: String(m.merchant_name ?? ''),
      isTest: Boolean(m.is_test),
      email: textoONulo(m.email),
      hasPayoutAccount: Boolean(m.has_payout_account),
      bank: textoONulo(m.bank),
      accountHolder: textoONulo(m.account_holder),
      holderDocument: textoONulo(m.holder_document),
      accountNumber: textoONulo(m.account_number),
      pagoMovilPhone: textoONulo(m.pago_movil_phone),
      lineas: numero(m.lineas),
      pendingUsd: numero(m.pending_usd),
      pendingUsdPart: numero(m.pending_usd_part),
      pendingEur: numero(m.pending_eur),
      pendingVes: numeroONulo(m.pending_ves),
    })),
  }
}

// ── Las reglas del banco ──────────────────────────────────────────────────
// Las de la hoja «Instrucciones» de la plantilla (validador versión 1.4).

/** Descripción: hasta 60 caracteres. */
export const MAX_DESCRIPCION = 60
/** Nombre del beneficiario: hasta 80. */
const MAX_NOMBRE = 80
/** Correo: hasta 100, nombre@dominio.tipo. */
const MAX_EMAIL = 100
/** Monto: hasta 15 dígitos, los dos últimos decimales. */
const MAX_MONTO = 9_999_999_999_999.99

/** Una cuenta: 20 dígitos exactos. Lo demás (espacios, guiones) se quita. */
export function cuentaDelBanco(valor: string | null | undefined): string | null {
  const v = (valor ?? '').replace(/\D/g, '')
  return v.length === 20 ? v : null
}

/**
 * El ID del beneficiario como lo pide el banco: V o E (personas), J o G
 * (empresas) y hasta 10 caracteres en total. `J-12345678-9` → `J123456789`.
 * Un pasaporte (`P…`) no lo acepta.
 */
export function idDelBeneficiario(valor: string | null | undefined): string | null {
  const v = (valor ?? '').trim().toUpperCase().replace(/[\s.-]/g, '')
  return /^[VEJG]\d{1,9}$/.test(v) ? v : null
}

function emailDelBanco(valor: string | null): string | null {
  const v = (valor ?? '').trim()
  return v.length <= MAX_EMAIL && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) ? v : null
}

/** «0191 •••• 0001»: la cuenta, sin enseñarla entera. */
export function cuentaCorta(cuenta: string | null): string {
  return cuenta ? `${cuenta.slice(0, 4)} •••• ${cuenta.slice(-4)}` : '—'
}

/** «Pago Helios 14/10/2026»: la descripción por defecto de un día de pago. */
export function descripcionPorDefecto(dia: string): string {
  const [a, m, d] = dia.split('-')
  return `Pago Helios ${d}/${m}/${a}`
}

/** Una fila de la hoja «Validar Datos», en el orden de sus columnas. */
export type FilaDelBanco = {
  /** A · Fecha de pago, `AAAA-MM-DD`. */
  fechaPago: string
  /** B · Cuenta a debitar, 20 dígitos. */
  cuentaDebito: string
  /** C · Cuenta del beneficiario, 20 dígitos. */
  cuentaBeneficiario: string
  /** D · Monto en bolívares. */
  monto: number
  /** E · Descripción, hasta 60. */
  descripcion: string
  /** F · Cédula o RIF, hasta 10. */
  idBeneficiario: string
  /** G · Nombre del beneficiario, hasta 80. */
  nombreBeneficiario: string
  /** H · Correo del beneficiario, o vacío. */
  email: string | null
  /** I · Referencia del cliente: un número de hasta 10 dígitos. */
  referencia: number
}

export type ClinicaFuera = { clinica: ClinicaDelPagoMasivo; motivo: string }

export type RepartoDelPagoMasivo = {
  /** Las que van en el archivo, cada una con su fila. */
  dentro: Array<{ clinica: ClinicaDelPagoMasivo; fila: FilaDelBanco }>
  /** Las que hay que pagar a mano, con por qué. */
  fuera: ClinicaFuera[]
  /** Las de prueba: no se les transfiere. */
  pruebas: ClinicaDelPagoMasivo[]
  totalVes: number
  totalUsd: number
}

/**
 * Quién va en el archivo y con qué fila. La referencia del cliente es el mes
 * y el día del pago más el número de fila (`10140001`): única dentro del día
 * y siempre por debajo de diez dígitos.
 */
export function repartirPagoMasivo(
  hoja: HojaDePagoMasivo,
  opciones: { cuentaDebito: string; fechaPago: string; descripcion: string },
): RepartoDelPagoMasivo {
  const reparto: RepartoDelPagoMasivo = { dentro: [], fuera: [], pruebas: [], totalVes: 0, totalUsd: 0 }
  const [, mes = '00', dia = '00'] = opciones.fechaPago.split('-')
  const descripcion = opciones.descripcion.trim().slice(0, MAX_DESCRIPCION)

  for (const clinica of hoja.merchants) {
    if (clinica.isTest) {
      reparto.pruebas.push(clinica)
      continue
    }
    const motivo = motivoParaDejarFuera(clinica)
    if (motivo) {
      reparto.fuera.push({ clinica, motivo })
      continue
    }

    const monto = clinica.pendingVes ?? 0
    reparto.dentro.push({
      clinica,
      fila: {
        fechaPago: opciones.fechaPago,
        cuentaDebito: opciones.cuentaDebito,
        cuentaBeneficiario: cuentaDelBanco(clinica.accountNumber) ?? '',
        monto,
        descripcion,
        idBeneficiario: idDelBeneficiario(clinica.holderDocument) ?? '',
        nombreBeneficiario: (clinica.accountHolder ?? '').trim().slice(0, MAX_NOMBRE),
        email: emailDelBanco(clinica.email),
        referencia: Number(`${mes}${dia}${String(reparto.dentro.length + 1).padStart(4, '0')}`),
      },
    })
    reparto.totalVes = Math.round((reparto.totalVes + monto) * 100) / 100
    reparto.totalUsd = Math.round((reparto.totalUsd + clinica.pendingUsd) * 10_000) / 10_000
  }
  return reparto
}

function motivoParaDejarFuera(c: ClinicaDelPagoMasivo): string | null {
  if (!c.hasPayoutAccount) return 'No tiene cuenta de pago.'
  if (!cuentaDelBanco(c.accountNumber)) {
    return c.pagoMovilPhone
      ? 'Solo tiene Pago Móvil, y el pago masivo es solo por transferencia.'
      : 'No tiene cuenta de transferencia de 20 dígitos.'
  }
  if (!idDelBeneficiario(c.holderDocument)) {
    return `El banco no acepta el documento del titular (${c.holderDocument ?? 'vacío'}): tiene que ser V, E, J o G con hasta 9 dígitos.`
  }
  if (!c.accountHolder?.trim()) return 'Falta el titular de la cuenta.'
  if (c.pendingVes === null) return 'Falta la tasa BCV de hoy para pasarlo a bolívares.'
  if (c.pendingVes <= 0) return 'No hay nada que transferir en bolívares.'
  if (c.pendingVes > MAX_MONTO) return 'El monto pasa del máximo del banco.'
  return null
}

/** Qué falta para poder bajar el archivo, o `null` si nada. */
export function bloqueoDelPagoMasivo(
  opciones: { cuentaDebito: string; fechaPago: string; descripcion: string },
  hoy: string,
  filasDentro: number,
): string | null {
  if (!cuentaDelBanco(opciones.cuentaDebito)) return 'La cuenta a debitar tiene 20 dígitos.'
  if (!/^\d{4}-\d{2}-\d{2}$/.test(opciones.fechaPago)) return 'Falta la fecha de pago.'
  if (opciones.fechaPago < hoy) return 'El banco no acepta una fecha de pago anterior a hoy.'
  if (!opciones.descripcion.trim()) return 'Falta la descripción.'
  if (opciones.descripcion.trim().length > MAX_DESCRIPCION) {
    return `La descripción tiene como mucho ${MAX_DESCRIPCION} caracteres.`
  }
  if (filasDentro === 0) return 'No hay ninguna clínica que pagar por transferencia.'
  return null
}

// ── La plantilla, llena ───────────────────────────────────────────────────

/** La hoja «Validar Datos» (`sheet2.xml`): la segunda del libro. */
const HOJA_DE_DATOS = 'xl/worksheets/sheet2.xml'
/** Los datos empiezan en la fila 3: la 1 es el botón y la 2 los títulos. */
const PRIMERA_FILA = 3

/**
 * El estilo de cada columna, el mismo que la plantilla le da a la columna
 * entera: fecha (14), texto (49) en las cuentas, la descripción y el nombre,
 * y `#,##0.00` (4) en el monto. Así la macro lee lo que leería si se hubiera
 * escrito a mano.
 */
const ESTILO = { A: 7, B: 11, C: 11, D: 16, E: 37, F: 13, G: 37, H: 13, I: 41 } as const

function xml(texto: string): string {
  return texto
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    // Lo que XML 1.0 no admite (controles) no puede llegar a la hoja.
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '')
}

/** Un día `AAAA-MM-DD` como número de serie de Excel (días desde 1899-12-30). */
export function serieDeExcel(dia: string): number {
  const [a = 1900, m = 1, d = 1] = dia.split('-').map(Number)
  return Math.round((Date.UTC(a, m - 1, d) - Date.UTC(1899, 11, 30)) / 86_400_000)
}

function celdaTexto(ref: string, estilo: number, valor: string): string {
  return `<c r="${ref}" s="${estilo}" t="inlineStr"><is><t>${xml(valor)}</t></is></c>`
}

function celdaNumero(ref: string, estilo: number, valor: number | string): string {
  return `<c r="${ref}" s="${estilo}"><v>${valor}</v></c>`
}

function filaXml(f: FilaDelBanco, n: number): string {
  const celdas = [
    celdaNumero(`A${n}`, ESTILO.A, serieDeExcel(f.fechaPago)),
    celdaTexto(`B${n}`, ESTILO.B, f.cuentaDebito),
    celdaTexto(`C${n}`, ESTILO.C, f.cuentaBeneficiario),
    celdaNumero(`D${n}`, ESTILO.D, f.monto.toFixed(2)),
    celdaTexto(`E${n}`, ESTILO.E, f.descripcion),
    celdaTexto(`F${n}`, ESTILO.F, f.idBeneficiario),
    celdaTexto(`G${n}`, ESTILO.G, f.nombreBeneficiario),
    f.email ? celdaTexto(`H${n}`, ESTILO.H, f.email) : '',
    celdaNumero(`I${n}`, ESTILO.I, f.referencia),
  ]
  return `<row r="${n}" spans="1:9">${celdas.join('')}</row>`
}

/**
 * La plantilla del banco con las filas escritas en «Validar Datos». Todo lo
 * demás del libro (la macro, el botón, las instrucciones) va tal cual.
 */
export function llenarPlantilla(plantilla: Uint8Array, filasDelBanco: ReadonlyArray<FilaDelBanco>): Uint8Array {
  const partes = unzipSync(plantilla)
  if (!(HOJA_DE_DATOS in partes)) throw new Error('La plantilla del banco no trae la hoja «Validar Datos».')

  const original = strFromU8(partes[HOJA_DE_DATOS])
  if (!original.includes('</sheetData>') || /<row r="3"/.test(original)) {
    throw new Error('La plantilla del banco no es la esperada: la hoja «Validar Datos» ya trae filas.')
  }

  const ultima = PRIMERA_FILA + filasDelBanco.length - 1
  const nuevas = filasDelBanco.map((f, i) => filaXml(f, PRIMERA_FILA + i)).join('')
  const llena = original
    .replace('</sheetData>', `${nuevas}</sheetData>`)
    .replace(/<dimension ref="A1:([A-Z]+)\d+"\/>/, `<dimension ref="A1:$1${Math.max(ultima, 2)}"/>`)

  partes[HOJA_DE_DATOS] = strToU8(llena)
  return zipSync(partes)
}

/** `pago-masivo-2026-10-14.xlsm`. */
export function nombreDelArchivo(fechaPago: string): string {
  return `pago-masivo-${fechaPago}.xlsm`
}

// ── El lote: lo que se bajó y lo que se registra ──────────────────────────
// Bajar el archivo guarda el lote (`admin_create_bulk_payout`) con las
// liquidaciones exactas de cada fila. Cuando el banco lo procesa, se registra
// de una vez (`admin_register_bulk_payout`): una transferencia por línea, con
// los bolívares, la fecha y la referencia del archivo.

/** Las filas del archivo como las guarda `admin_create_bulk_payout`, en orden. */
/** Una fila del archivo para `admin_create_bulk_payout`. */
export type LineaParaGuardar = {
  merchant_id: string
  reference: string
  amount_ves: number
  beneficiary_account: string
  beneficiary_id: string
  beneficiary_name: string
}

/** Una línea para `admin_register_bulk_payout`. */
export type LineaParaRegistrar = { line_id: string; reference?: string }

export function lineasDelLote(dentro: RepartoDelPagoMasivo['dentro']): LineaParaGuardar[] {
  return dentro.map(({ clinica, fila }) => ({
    merchant_id: clinica.merchantId,
    reference: String(fila.referencia),
    amount_ves: fila.monto,
    beneficiary_account: fila.cuentaBeneficiario,
    beneficiary_id: fila.idBeneficiario,
    beneficiary_name: fila.nombreBeneficiario,
  }))
}

/**
 * `pendiente`: se puede registrar. `registrada`: ya tiene su transferencia.
 * `cambio`: algo de lo que pagaba se pagó por otro lado; se revisa a mano.
 */
export type EstadoDeLinea = 'pendiente' | 'registrada' | 'cambio'

export type LineaDelLote = {
  id: string
  fila: number
  merchantId: string
  merchantName: string
  liquidaciones: number
  amountUsd: number
  amountVes: number
  /** La referencia del cliente del archivo (MMDD + fila). */
  reference: string
  beneficiaryAccount: string
  beneficiaryName: string
  state: EstadoDeLinea
  /** La referencia con la que se registró, si ya se registró. */
  payoutReference: string | null
}

export type LoteDePagoMasivo = {
  id: string
  /** La fecha de pago del archivo: el día en que el banco paga. */
  payDate: string
  description: string
  debitAccount: string
  fxRateUsd: number | null
  fxRateEur: number | null
  totalUsd: number
  totalVes: number
  createdAt: string
  createdByName: string | null
  lines: LineaDelLote[]
}

function estadoDeLinea(v: unknown): EstadoDeLinea {
  return v === 'registrada' || v === 'pendiente' ? v : 'cambio'
}

/** `admin_bulk_payouts`. */
export function leerLotesDePagoMasivo(raw: unknown): LoteDePagoMasivo[] {
  return filas(raw).map((b) => ({
    id: String(b.id),
    payDate: String(b.pay_date ?? ''),
    description: String(b.description ?? ''),
    debitAccount: String(b.debit_account ?? ''),
    fxRateUsd: numeroONulo(b.fx_rate_usd),
    fxRateEur: numeroONulo(b.fx_rate_eur),
    totalUsd: numero(b.total_usd),
    totalVes: numero(b.total_ves),
    createdAt: String(b.created_at ?? ''),
    createdByName: textoONulo(b.created_by_name),
    lines: filas(b.lines).map((l) => ({
      id: String(l.id),
      fila: numero(l.row_number),
      merchantId: String(l.merchant_id),
      merchantName: String(l.merchant_name ?? ''),
      liquidaciones: numero(l.settlements),
      amountUsd: numero(l.amount_usd),
      amountVes: numero(l.amount_ves),
      reference: String(l.reference ?? ''),
      beneficiaryAccount: String(l.beneficiary_account ?? ''),
      beneficiaryName: String(l.beneficiary_name ?? ''),
      state: estadoDeLinea(l.state),
      payoutReference: textoONulo(l.payout_reference),
    })),
  }))
}

/** Lo que queda por registrar de un lote. */
export function porRegistrar(lote: LoteDePagoMasivo): LineaDelLote[] {
  return lote.lines.filter((l) => l.state === 'pendiente')
}

/** La referencia del banco: hasta 64 caracteres, como acepta la base. */
export const MAX_REFERENCIA = 64

/** Qué falta para poder registrar el lote, o `null` si nada. */
export function bloqueoDelRegistro(
  lote: LoteDePagoMasivo,
  marcadas: ReadonlyArray<LineaDelLote>,
  referencias: Readonly<Record<string, string>>,
  hoy: string,
): string | null {
  if (lote.payDate > hoy) return 'El banco todavía no paga este archivo: regístralo el día de su fecha de pago.'
  if (marcadas.length === 0) return 'Marca al menos una transferencia que el banco haya pagado.'
  if (marcadas.some((l) => (referencias[l.id] ?? '').trim().length > MAX_REFERENCIA)) {
    return `Una referencia tiene como mucho ${MAX_REFERENCIA} caracteres.`
  }
  return null
}

/**
 * Las líneas para `admin_register_bulk_payout`: sin referencia escrita va la
 * del cliente del archivo.
 */
export function lineasARegistrar(
  marcadas: ReadonlyArray<LineaDelLote>,
  referencias: Readonly<Record<string, string>>,
): LineaParaRegistrar[] {
  return marcadas.map((l) => {
    const escrita = (referencias[l.id] ?? '').trim()
    return escrita ? { line_id: l.id, reference: escrita } : { line_id: l.id }
  })
}
