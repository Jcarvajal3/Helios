import { construirCsv, csvInstante } from '@/lib/csv'
import type { CsvColumn } from '@/lib/csv'
import { ESTADOS_LOCAL } from '@/features/admin/estados'
import type { EstadoLocal } from '@/features/admin/estados'
import { comoFila, textoONulo } from '@/lib/json'
import { formatoCuenta, telefonoLocal } from './clinicas'

// ═══════════════════════════════════════════════════════════════════════════
// Los datos de alta de las clínicas, para redactar el contrato
// (`admin_merchant_contract_data`, contrato §2.5).
//
// Una fila por clínica: la clínica, su médico titular, su cuenta de pago y la
// solicitud de la portada de la que nació. Sale de la lista de Clínicas
// (todas) y del «⋯» de la ficha (una).
//
// Módulo puro, probado en `contrato.test.ts`; la llamada, en `api.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export type DatosDeContrato = {
  merchantId: string
  name: string
  legalName: string | null
  taxId: string | null
  specialty: string | null
  mppsNumber: string | null
  phone: string | null
  email: string | null
  address: string | null
  city: string | null
  status: EstadoLocal
  isTest: boolean
  createdAt: string | null
  ownerName: string | null
  ownerDocument: string | null
  collegeNumber: string | null
  bank: string | null
  accountHolder: string | null
  holderDocument: string | null
  accountNumber: string | null
  pagoMovilBank: string | null
  pagoMovilPhone: string | null
  /** La solicitud de la portada; null si se dio de alta desde el panel. */
  appliedAt: string | null
  approvedAt: string | null
}

function comoEstado(v: unknown): EstadoLocal {
  return v === 'paused' || v === 'terminated' ? v : 'active'
}

export function leerDatosDeContrato(raw: unknown): DatosDeContrato {
  const r = comoFila(raw)
  return {
    merchantId: String(r.merchant_id),
    name: textoONulo(r.name) ?? '',
    legalName: textoONulo(r.legal_name),
    taxId: textoONulo(r.tax_id),
    specialty: textoONulo(r.specialty),
    mppsNumber: textoONulo(r.mpps_number),
    phone: textoONulo(r.phone),
    email: textoONulo(r.email),
    address: textoONulo(r.address),
    city: textoONulo(r.city),
    status: comoEstado(r.status),
    isTest: r.is_test === true,
    createdAt: textoONulo(r.created_at),
    ownerName: textoONulo(r.owner_name),
    ownerDocument: textoONulo(r.owner_document),
    collegeNumber: textoONulo(r.college_number),
    bank: textoONulo(r.bank),
    accountHolder: textoONulo(r.account_holder),
    holderDocument: textoONulo(r.holder_document),
    accountNumber: textoONulo(r.account_number),
    pagoMovilBank: textoONulo(r.pago_movil_bank),
    pagoMovilPhone: textoONulo(r.pago_movil_phone),
    appliedAt: textoONulo(r.applied_at),
    approvedAt: textoONulo(r.approved_at),
  }
}

/**
 * Las columnas, en el orden en que se leen para redactar: la clínica, su
 * titular y a dónde se le paga.
 *
 * El teléfono y la cuenta van con espacios (`0212 5551234`, `0134 0000 …`):
 * sin ellos Excel los abre como números, quita el cero de delante y escribe
 * la cuenta de 20 dígitos en notación científica.
 */
export const COLUMNAS_DE_CONTRATO: Array<CsvColumn<DatosDeContrato>> = [
  { header: 'Clínica', value: (d) => d.name },
  { header: 'Razón social', value: (d) => d.legalName },
  { header: 'RIF', value: (d) => d.taxId },
  { header: 'Especialidad', value: (d) => d.specialty },
  { header: 'Matrícula o MPPS', value: (d) => d.mppsNumber },
  { header: 'Dirección', value: (d) => d.address },
  { header: 'Ciudad', value: (d) => d.city },
  { header: 'Teléfono', value: (d) => (d.phone ? telefonoLocal(d.phone) : null) },
  { header: 'Correo', value: (d) => d.email },
  { header: 'Médico titular', value: (d) => d.ownerName },
  { header: 'Cédula o pasaporte del titular', value: (d) => d.ownerDocument },
  { header: 'N.º de Colegio o Federación', value: (d) => d.collegeNumber },
  { header: 'Banco', value: (d) => d.bank },
  { header: 'Titular de la cuenta', value: (d) => d.accountHolder },
  { header: 'Cédula o RIF de la cuenta', value: (d) => d.holderDocument },
  { header: 'N.º de cuenta', value: (d) => (d.accountNumber ? formatoCuenta(d.accountNumber) : null) },
  { header: 'Banco del Pago Móvil', value: (d) => d.pagoMovilBank },
  { header: 'Celular del Pago Móvil', value: (d) => (d.pagoMovilPhone ? telefonoLocal(d.pagoMovilPhone) : null) },
  { header: 'Estado', value: (d) => `${ESTADOS_LOCAL[d.status].label}${d.isTest ? ' (prueba)' : ''}` },
  { header: 'Solicitud', value: (d) => csvInstante(d.appliedAt) },
  { header: 'Alta', value: (d) => csvInstante(d.createdAt) },
  { header: 'Id', value: (d) => d.merchantId },
]

export function csvDeContratos(filas: ReadonlyArray<DatosDeContrato>): string {
  return construirCsv(COLUMNAS_DE_CONTRATO, [...filas])
}

/** El nombre del archivo, sin extensión: `datos-de-alta-consultorio-dental-ana-perez`. */
export function archivoDeContrato(clinica?: string): string {
  if (!clinica) return 'datos-de-alta-de-las-clinicas'
  const slug = clinica
    .normalize('NFD')
    .replace(/\p{Diacritic}/gu, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
  return slug ? `datos-de-alta-${slug}` : 'datos-de-alta-de-la-clinica'
}
