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

/**
 * Los datos del alta de una clínica: los del médico titular, los del
 * consultorio y el Pago Móvil al que se le paga. Son los mismos en el alta
 * del equipo y en la solicitud de la portada (`/afiliacion`), y la base los
 * valida igual en los dos sitios (`helios_datos_de_alta`).
 */
export type AltaDeClinica = {
  ownerName: string
  ownerDocument: string
  taxId: string
  specialty: string
  collegeNumber: string
  mppsNumber: string
  clinicName: string
  address: string
  phone: string
  email: string
  pagoMovilBank: string
  pagoMovilDocument: string
  pagoMovilPhone: string
}

export const ALTA_VACIA: AltaDeClinica = {
  ownerName: '',
  ownerDocument: '',
  taxId: '',
  specialty: '',
  collegeNumber: '',
  mppsNumber: '',
  clinicName: '',
  address: '',
  phone: '',
  email: '',
  pagoMovilBank: '',
  pagoMovilDocument: '',
  pagoMovilPhone: '',
}

const CORREO = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/

/** Si un texto parece un correo. */
export function pareceCorreo(valor: string): boolean {
  return CORREO.test(valor.trim())
}

/** Un teléfono venezolano (fijo o móvil) a E.164, o `null` si no lo parece. */
export function telefonoAE164(valor: string): string | null {
  const digitos = valor.replace(/\D/g, '')
  const nacional = digitos.startsWith('58') ? digitos.slice(2) : digitos.replace(/^0/, '')
  return /^\d{10}$/.test(nacional) ? `+58${nacional}` : null
}

/** Un celular venezolano (el Pago Móvil solo va a celulares) a E.164, o `null`. */
export function celularAE164(valor: string): string | null {
  const e164 = telefonoAE164(valor)
  return e164 && /^\+58(412|414|416|422|424|426)\d{7}$/.test(e164) ? e164 : null
}

/** Un teléfono guardado en E.164, como se escribe en Venezuela: `0414 1234567`. */
export function telefonoLocal(e164: string | null): string {
  if (!e164) return ''
  const d = e164.replace(/^\+58/, '')
  return /^\d{10}$/.test(d) ? `0${d.slice(0, 3)} ${d.slice(3)}` : e164
}

/** Cédula (con o sin V/E) o pasaporte: de 5 a 20 letras y números. */
export function pareceCedulaOPasaporte(valor: string): boolean {
  return /^[A-Z0-9]{5,20}$/.test(valor.toUpperCase().replace(/[^A-Z0-9]/g, ''))
}

/** Qué falta o está mal en el alta, o `null` si se puede mandar. */
export function motivoDeAlta(a: AltaDeClinica): string | null {
  if (a.ownerName.trim().length < 3) return 'Falta el nombre completo.'
  if (!pareceCedulaOPasaporte(a.ownerDocument)) return 'Falta la cédula o el pasaporte.'
  if (a.taxId.trim() !== '') {
    const rif = validateTaxId(a.taxId)
    if (rif) return `RIF: ${rif}`
  }
  if (!a.specialty.trim()) return 'Falta la especialidad.'
  if (a.clinicName.trim().length < 2) return 'Falta el nombre del consultorio o centro médico.'
  if (a.address.trim().length < 5) return 'Falta la dirección del consultorio.'
  if (!telefonoAE164(a.phone)) return 'El teléfono no parece venezolano: 0212 5551234 o 0414 1234567.'
  if (!pareceCorreo(a.email)) return 'El correo no parece un correo.'
  if (!a.pagoMovilBank) return 'Elige el banco del Pago Móvil.'
  const docPagoMovil = a.pagoMovilDocument.trim().toUpperCase().replace(/[\s.-]/g, '')
  if (!/^([VE]?\d{6,9}|[JGP]\d{8,9})$/.test(docPagoMovil)) {
    return 'La cédula o el RIF del Pago Móvil: V12345678 o J123456789.'
  }
  if (!celularAE164(a.pagoMovilPhone)) return 'El teléfono del Pago Móvil tiene que ser un celular: 0414 1234567.'
  return null
}

/** Lo que se manda a la base: el `p` de `admin_create_clinic` y de la solicitud. */
export function datosDeAlta(a: AltaDeClinica): Record<string, string> {
  return {
    owner_name: a.ownerName.trim(),
    owner_document: a.ownerDocument.trim(),
    tax_id: a.taxId.trim(),
    specialty: a.specialty.trim(),
    college_number: a.collegeNumber.trim(),
    mpps_number: a.mppsNumber.trim(),
    clinic_name: a.clinicName.trim(),
    address: a.address.trim(),
    phone: a.phone.trim(),
    email: a.email.trim().toLowerCase(),
    pago_movil_bank: a.pagoMovilBank,
    pago_movil_document: a.pagoMovilDocument.trim(),
    pago_movil_phone: a.pagoMovilPhone.trim(),
  }
}

// ── Las solicitudes de afiliación ──────────────────────────────────────────

export type EstadoSolicitud = 'pending' | 'approved' | 'rejected'

export type SolicitudDeAfiliacion = {
  id: string
  status: EstadoSolicitud
  /** Los datos tal cual los mandó el médico (ya normalizados por la base). */
  alta: AltaDeClinica
  createdAt: string
  merchantId: string | null
  reviewedAt: string | null
  reviewedByName: string | null
  rejectReason: string | null
}

/** Una fila de `admin_merchant_applications`. */
export function leerSolicitud(raw: unknown): SolicitudDeAfiliacion {
  const r = comoFila(raw)
  const t = (v: unknown) => textoONulo(v) ?? ''
  const estado = textoONulo(r.status)
  return {
    id: t(r.id),
    status: estado === 'approved' || estado === 'rejected' ? estado : 'pending',
    alta: {
      ownerName: t(r.owner_name),
      ownerDocument: t(r.owner_document),
      taxId: t(r.tax_id),
      specialty: t(r.specialty),
      collegeNumber: t(r.college_number),
      mppsNumber: t(r.mpps_number),
      clinicName: t(r.clinic_name),
      address: t(r.address),
      // La base los guarda en E.164; el formulario los enseña como se escriben.
      phone: telefonoLocal(textoONulo(r.phone)),
      email: t(r.email),
      pagoMovilBank: t(r.pago_movil_bank),
      pagoMovilDocument: t(r.pago_movil_document),
      pagoMovilPhone: telefonoLocal(textoONulo(r.pago_movil_phone)),
    },
    createdAt: t(r.created_at),
    merchantId: textoONulo(r.merchant_id),
    reviewedAt: textoONulo(r.reviewed_at),
    reviewedByName: textoONulo(r.reviewed_by_name),
    rejectReason: textoONulo(r.reject_reason),
  }
}

/**
 * Lo que el equipo cambió de una solicitud antes de aprobarla: solo esas
 * claves van a `admin_approve_merchant_application`. Sin cambios, `null`.
 */
export function correccionesDeSolicitud(antes: AltaDeClinica, despues: AltaDeClinica): Record<string, string> | null {
  const a = datosDeAlta(antes)
  const d = datosDeAlta(despues)
  const cambios = Object.fromEntries(Object.entries(d).filter(([k, v]) => a[k] !== v))
  return Object.keys(cambios).length > 0 ? cambios : null
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

