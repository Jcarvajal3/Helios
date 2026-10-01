import { validateTaxId } from '@/features/admin/merchantProfile'
import { comoFila, filaONula, numeroONulo, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Las clínicas en Helios (contrato §2.5): el alta con sus datos médicos, la
// cuenta a la que se les paga, la comisión propia del personal y el desglose
// de lo que se les transfiere en consultas y comisiones.
//
// Módulo puro, probado en `clinicas.test.ts`; las llamadas, en `api.ts`.
// ═══════════════════════════════════════════════════════════════════════════

// ── El alta ────────────────────────────────────────────────────────────────

export type AltaDeClinica = {
  name: string
  legalName: string
  taxId: string
  category: string
  specialty: string
  mppsNumber: string
  phone: string
  email: string
  address: string
  city: string
}

const CORREO = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/

/** Un teléfono venezolano (fijo o móvil) a E.164, o `null` si no lo parece. */
export function telefonoAE164(valor: string): string | null {
  const digitos = valor.replace(/\D/g, '')
  const nacional = digitos.startsWith('58') ? digitos.slice(2) : digitos.replace(/^0/, '')
  return /^\d{10}$/.test(nacional) ? `+58${nacional}` : null
}

/** Qué falta o está mal en el alta, o `null` si se puede crear. */
export function motivoDeAlta(a: AltaDeClinica): string | null {
  if (a.name.trim().length < 2) return 'Falta el nombre de la clínica.'
  const rif = validateTaxId(a.taxId)
  if (rif) return rif
  if (!a.category) return 'Elige la categoría.'
  if (a.phone.trim() !== '' && !telefonoAE164(a.phone)) return 'El teléfono no parece venezolano: 0212 5551234 o 0414 1234567.'
  if (a.email.trim() !== '' && !CORREO.test(a.email.trim())) return 'El correo no parece un correo.'
  if (a.mppsNumber.trim() !== '' && !/^\d{3,8}$/.test(a.mppsNumber.trim())) {
    return 'El número del MPPS son solo dígitos.'
  }
  return null
}

// ── La cuenta de pago de la clínica ────────────────────────────────────────

export type CuentaDePagoDeClinica = {
  bank: string | null
  accountHolder: string | null
  holderDocument: string | null
  accountNumber: string | null
  pagoMovilPhone: string | null
  pagoMovilBank: string | null
  updatedAt: string | null
  updatedByName: string | null
}

/** `admin_merchant_payout_account`. `null` si la clínica todavía no tiene. */
export function leerCuentaDePago(raw: unknown): CuentaDePagoDeClinica | null {
  const r = filaONula(raw)
  if (!r) return null
  const cuenta = {
    bank: textoONulo(r.bank),
    accountHolder: textoONulo(r.account_holder),
    holderDocument: textoONulo(r.holder_document),
    accountNumber: textoONulo(r.account_number),
    pagoMovilPhone: textoONulo(r.pago_movil_phone),
    pagoMovilBank: textoONulo(r.pago_movil_bank),
    updatedAt: textoONulo(r.updated_at),
    updatedByName: textoONulo(r.updated_by_name),
  }
  const vacia = !cuenta.accountNumber && !cuenta.pagoMovilPhone && !cuenta.accountHolder
  return vacia ? null : cuenta
}

export type BorradorDeCuenta = {
  bank: string
  accountHolder: string
  holderDocument: string
  accountNumber: string
  pagoMovilPhone: string
  pagoMovilBank: string
}

export function borradorDeCuenta(c: CuentaDePagoDeClinica | null): BorradorDeCuenta {
  return {
    bank: c?.bank ?? '',
    accountHolder: c?.accountHolder ?? '',
    holderDocument: c?.holderDocument ?? '',
    accountNumber: c?.accountNumber ?? '',
    pagoMovilPhone: c?.pagoMovilPhone ?? '',
    pagoMovilBank: c?.pagoMovilBank ?? '',
  }
}

/** Una cédula o un RIF: `V12345678`, `J-12345678-9`… a mayúsculas y sin guiones. */
export function normalizarDocumento(valor: string): string | null {
  const v = valor.trim().toUpperCase().replace(/[\s.-]/g, '')
  return /^[VEJGP]\d{6,10}$/.test(v) ? v : null
}

export type CambioDeCuenta = { ok: true; payload: Record<string, string | null> } | { ok: false; motivo: string }

/**
 * Lo que se manda a `admin_set_merchant_payout_account`, o por qué no. Hace
 * falta el titular con su documento y al menos una forma de pagarle: la
 * cuenta de 20 dígitos (con su banco) o el Pago Móvil (con su banco).
 */
export function cambioDeCuenta(b: BorradorDeCuenta): CambioDeCuenta {
  if (b.accountHolder.trim().length < 3) return { ok: false, motivo: 'Falta el titular.' }
  const documento = normalizarDocumento(b.holderDocument)
  if (!documento) return { ok: false, motivo: 'El documento del titular es una cédula o un RIF: V12345678 o J123456789.' }

  const numeroDeCuenta = b.accountNumber.replace(/\D/g, '')
  const conCuenta = numeroDeCuenta !== ''
  const conPagoMovil = b.pagoMovilPhone.trim() !== ''
  if (!conCuenta && !conPagoMovil) return { ok: false, motivo: 'Pon la cuenta bancaria, el Pago Móvil o los dos.' }

  if (conCuenta) {
    if (numeroDeCuenta.length !== 20) return { ok: false, motivo: 'La cuenta bancaria tiene 20 dígitos.' }
    if (!b.bank.trim()) return { ok: false, motivo: 'Falta el banco de la cuenta.' }
  }
  let telefono: string | null = null
  if (conPagoMovil) {
    telefono = telefonoAE164(b.pagoMovilPhone)
    if (!telefono) return { ok: false, motivo: 'El teléfono del Pago Móvil no parece venezolano.' }
    if (!b.pagoMovilBank.trim()) return { ok: false, motivo: 'Falta el banco del Pago Móvil.' }
  }

  return {
    ok: true,
    payload: {
      bank: conCuenta ? b.bank.trim() : null,
      account_holder: b.accountHolder.trim(),
      holder_document: documento,
      account_number: conCuenta ? numeroDeCuenta : null,
      pago_movil_phone: telefono,
      pago_movil_bank: conPagoMovil ? b.pagoMovilBank.trim() : null,
    },
  }
}

/** La cuenta de 20 dígitos en bloques de 4, para leerla sin perderse. */
export function formatoCuenta(numeroDeCuenta: string): string {
  const d = numeroDeCuenta.replace(/\D/g, '')
  return d.replace(/(\d{4})(?=\d)/g, '$1 ')
}

/**
 * Las líneas que se copian para hacer la transferencia, cada una con su
 * rótulo y su valor tal cual lo pide el banco (sin espacios en la cuenta).
 */
export function lineasParaCopiar(c: CuentaDePagoDeClinica): Array<{ rotulo: string; valor: string }> {
  const lineas: Array<{ rotulo: string; valor: string | null }> = [
    { rotulo: 'Titular', valor: c.accountHolder },
    { rotulo: 'Cédula o RIF', valor: c.holderDocument },
    { rotulo: 'Banco', valor: c.bank },
    { rotulo: 'Cuenta', valor: c.accountNumber },
    { rotulo: 'Pago Móvil', valor: c.pagoMovilPhone ? c.pagoMovilPhone.replace(/^\+58/, '0') : null },
    { rotulo: 'Banco del Pago Móvil', valor: c.pagoMovilBank },
  ]
  return lineas.filter((l): l is { rotulo: string; valor: string } => l.valor !== null)
}

/** Todo en un solo texto, para pegarlo en el banco o en un chat. */
export function textoParaCopiar(c: CuentaDePagoDeClinica): string {
  return lineasParaCopiar(c)
    .map((l) => `${l.rotulo}: ${l.valor}`)
    .join('\n')
}

// ── Consultas y comisiones ─────────────────────────────────────────────────

export type ConsultasYComisiones = { consultasUsd: number; comisionesUsd: number }

/**
 * Lo que se le paga a una clínica, partido en lo de las consultas y lo de
 * las comisiones de su personal (`reason = 'staff_commission'`).
 */
export function partirPorMotivo(
  lineas: ReadonlyArray<{ reason: string; amountUsd: number }>,
): ConsultasYComisiones {
  let consultas = 0
  let comisiones = 0
  for (const l of lineas) {
    if (l.reason === 'staff_commission') comisiones += l.amountUsd
    else consultas += l.amountUsd
  }
  return { consultasUsd: Math.round(consultas * 100) / 100, comisionesUsd: Math.round(comisiones * 100) / 100 }
}

/**
 * Los totales partidos que manda la base (`consultas_usd`, `comisiones_usd`).
 * Si no los manda, se parten las líneas; si tampoco hay líneas, `null`.
 */
export function leerConsultasYComisiones(
  raw: unknown,
  lineas?: ReadonlyArray<{ reason: string; amountUsd: number }>,
): ConsultasYComisiones | null {
  const r = comoFila(raw)
  const consultas = numeroONulo(r.consultas_usd)
  const comisiones = numeroONulo(r.comisiones_usd)
  if (consultas !== null || comisiones !== null) {
    return { consultasUsd: consultas ?? 0, comisionesUsd: comisiones ?? 0 }
  }
  return lineas && lineas.length > 0 ? partirPorMotivo(lineas) : null
}

// ── La comisión del personal de una clínica ────────────────────────────────

/** `null` en la clínica = usa el parámetro global. */
export function comisionEfectiva(propia: number | null, global: number | null): number | null {
  return propia ?? global
}

export function leerComisionPropia(terms: unknown): number | null {
  return numeroONulo(comoFila(terms).staff_commission_usd)
}

