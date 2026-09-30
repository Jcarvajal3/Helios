import { comoFila, filaONula, numeroONulo, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Los datos de un paciente (contrato §2.4): los que tecleó la secretaria al
// registrarlo, cómo los corrige Helios y los cambios que propone la clínica.
//
// Helios no tiene KYC: nadie verifica esos datos, así que se enseñan tal
// cual, con quién los escribió y dónde. Corregirlos pide motivo y queda en la
// bitácora. Módulo puro, probado en `datos.test.ts`; las llamadas, en `api.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export type DatosDelPaciente = {
  document: string | null
  birthDate: string | null
  age: number | null
  /** 'F' | 'M' */
  sex: string | null
  phone: string | null
  email: string | null
  /** Cuándo rebotó el comprobante. Mientras no sea `null`, el correo no sirve. */
  emailInvalidAt: string | null
  state: string | null
  city: string | null
  address: string | null
  occupation: string | null
  referenceName: string | null
  referencePhone: string | null
  referenceRelationship: string | null
  registeredByName: string | null
  registeredMerchantName: string | null
  createdAt: string | null
}

/**
 * La pestaña `datos` de `admin_user_detail`. Se lee de `datos` si viene como
 * objeto aparte, y si no, de la raíz de la respuesta.
 */
export function leerDatosDelPaciente(detalle: unknown): DatosDelPaciente {
  const raiz = comoFila(detalle)
  const d = filaONula(raiz.datos) ?? raiz
  return {
    document: textoONulo(d.document) ?? textoONulo(d.document_number),
    birthDate: textoONulo(d.birth_date),
    age: numeroONulo(d.age),
    sex: textoONulo(d.sex),
    phone: textoONulo(d.phone_e164),
    email: textoONulo(d.email),
    emailInvalidAt: textoONulo(d.email_invalid_at),
    state: textoONulo(d.state),
    city: textoONulo(d.city),
    address: textoONulo(d.address),
    occupation: textoONulo(d.occupation),
    referenceName: textoONulo(d.reference_name),
    referencePhone: textoONulo(d.reference_phone),
    referenceRelationship: textoONulo(d.reference_relationship),
    registeredByName: textoONulo(d.registered_by_name),
    registeredMerchantName: textoONulo(d.registered_merchant_name),
    createdAt: textoONulo(d.created_at) ?? textoONulo(raiz.created_at),
  }
}

export const SEXO: Record<string, string> = { F: 'Femenino', M: 'Masculino' }

/** La edad a partir de la fecha de nacimiento, si la base no la manda. */
export function edadEn(nacimiento: string | null, hoy: string): number | null {
  if (!nacimiento || !/^\d{4}-\d{2}-\d{2}/.test(nacimiento)) return null
  const [a, m, d] = nacimiento.slice(0, 10).split('-').map(Number) as [number, number, number]
  const [ha, hm, hd] = hoy.slice(0, 10).split('-').map(Number) as [number, number, number]
  let edad = ha - a
  if (hm < m || (hm === m && hd < d)) edad--
  return edad >= 0 ? edad : null
}

// ── Editar el contacto ─────────────────────────────────────────────────────

/** Los campos que Helios puede corregir (contrato §2.4). */
export const CAMPOS_EDITABLES = [
  'phone',
  'email',
  'state',
  'city',
  'address',
  'occupation',
  'reference_name',
  'reference_phone',
  'reference_relationship',
] as const
export type CampoEditable = (typeof CAMPOS_EDITABLES)[number]

export const NOMBRE_DEL_CAMPO: Record<CampoEditable, string> = {
  phone: 'Teléfono',
  email: 'Correo',
  state: 'Estado',
  city: 'Ciudad',
  address: 'Dirección',
  occupation: 'Ocupación',
  reference_name: 'Nombre de la referencia',
  reference_phone: 'Teléfono de la referencia',
  reference_relationship: 'Parentesco de la referencia',
}

export type BorradorDeDatos = Record<CampoEditable, string>

export function borradorDeDatos(d: DatosDelPaciente): BorradorDeDatos {
  return {
    phone: d.phone ?? '',
    email: d.email ?? '',
    state: d.state ?? '',
    city: d.city ?? '',
    address: d.address ?? '',
    occupation: d.occupation ?? '',
    reference_name: d.referenceName ?? '',
    reference_phone: d.referencePhone ?? '',
    reference_relationship: d.referenceRelationship ?? '',
  }
}

/** Los prefijos móviles de Venezuela (contrato §1.3). */
const PREFIJOS_MOVILES = ['412', '414', '416', '422', '424', '426']

/**
 * Un móvil venezolano a E.164: `0414 123 45 67` → `+584141234567`. `null` si
 * no es un móvil (los avisos van por WhatsApp: un fijo no sirve).
 */
export function movilAE164(valor: string): string | null {
  const digitos = valor.replace(/\D/g, '')
  const nacional = digitos.startsWith('58') ? digitos.slice(2) : digitos.replace(/^0/, '')
  if (!/^\d{10}$/.test(nacional)) return null
  return PREFIJOS_MOVILES.includes(nacional.slice(0, 3)) ? `+58${nacional}` : null
}

const CORREO = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/

/** El valor tal como se guardaría, para comparar con lo de antes. */
function normalizar(campo: CampoEditable, valor: string): string | null {
  const v = valor.trim()
  if (v === '') return null
  if (campo === 'phone' || campo === 'reference_phone') return movilAE164(v) ?? v
  if (campo === 'email') return v.toLowerCase()
  return v
}

export type CambioDeDatos =
  | { ok: true; payload: Partial<Record<CampoEditable, string | null>>; campos: CampoEditable[] }
  | { ok: false; motivo: string }

/**
 * Lo que se manda a `admin_update_patient_contact`: solo los campos que
 * cambiaron, o por qué no se puede. El motivo va aparte (`p_reason`) y lo
 * pide el diálogo.
 */
export function cambioDeDatos(antes: DatosDelPaciente, b: BorradorDeDatos): CambioDeDatos {
  const previo = borradorDeDatos(antes)

  if (b.phone.trim() === '') return { ok: false, motivo: 'El teléfono es obligatorio: los avisos van por WhatsApp.' }
  if (!movilAE164(b.phone)) {
    return { ok: false, motivo: 'El teléfono tiene que ser un móvil venezolano (0412, 0414, 0416, 0422, 0424 o 0426).' }
  }
  if (b.email.trim() === '') return { ok: false, motivo: 'El correo es obligatorio: ahí le llega el comprobante.' }
  if (!CORREO.test(b.email.trim())) return { ok: false, motivo: 'El correo no parece un correo.' }
  if (b.reference_phone.trim() !== '' && !movilAE164(b.reference_phone)) {
    return { ok: false, motivo: 'El teléfono de la referencia tiene que ser un móvil venezolano.' }
  }

  const payload: Partial<Record<CampoEditable, string | null>> = {}
  const campos: CampoEditable[] = []
  for (const campo of CAMPOS_EDITABLES) {
    const nuevo = normalizar(campo, b[campo])
    if (nuevo !== normalizar(campo, previo[campo])) {
      payload[campo] = nuevo
      campos.push(campo)
    }
  }
  if (campos.length === 0) return { ok: false, motivo: 'No has cambiado nada.' }
  return { ok: true, payload, campos }
}

// ── Cambios propuestos por la clínica ──────────────────────────────────────

export type EstadoDeCambio = 'pendiente' | 'aprobado' | 'rechazado'

export type CambioPropuesto = {
  id: string
  profileId: string
  patientName: string | null
  merchantName: string | null
  requestedByName: string | null
  status: string
  createdAt: string
  resolvedAt: string | null
  resolvedByName: string | null
  note: string | null
  /** Campo por campo: lo que hay y lo que tecleó la clínica. */
  diferencias: Array<{ campo: string; rotulo: string; actual: string | null; propuesto: string | null }>
}

/** El nombre de un campo propuesto: los editables con su nombre; el resto, la clave. */
function rotuloDeCampo(campo: string): string {
  const conocido = (CAMPOS_EDITABLES as readonly string[]).includes(campo)
    ? NOMBRE_DEL_CAMPO[campo as CampoEditable]
    : null
  const alias: Partial<Record<string, string>> = { phone_e164: 'Teléfono', first_name: 'Nombres', last_name: 'Apellidos', birth_date: 'Fecha de nacimiento', sex: 'Sexo' }
  return conocido ?? alias[campo] ?? campo
}

/**
 * Una fila de `admin_profile_change_requests`. Lo propuesto llega como un
 * objeto campo → valor (`proposed`, o `changes`), y lo de ahora en `current`.
 * Solo se listan los campos que de verdad difieren.
 */
export function leerCambioPropuesto(raw: unknown): CambioPropuesto {
  const r = comoFila(raw)
  const propuesto = filaONula(r.proposed) ?? filaONula(r.changes) ?? {}
  const actual = filaONula(r.current) ?? {}
  const diferencias = Object.keys(propuesto)
    .map((campo) => ({
      campo,
      rotulo: rotuloDeCampo(campo),
      actual: textoONulo(actual[campo]),
      propuesto: textoONulo(propuesto[campo]),
    }))
    .filter((d) => d.actual !== d.propuesto)

  return {
    id: texto(r.id),
    profileId: texto(r.profile_id) || texto(r.user_id),
    patientName: textoONulo(r.patient_name),
    merchantName: textoONulo(r.merchant_name),
    requestedByName: textoONulo(r.requested_by_name),
    status: texto(r.status, 'pendiente'),
    createdAt: texto(r.created_at),
    resolvedAt: textoONulo(r.resolved_at),
    resolvedByName: textoONulo(r.resolved_by_name),
    note: textoONulo(r.note) ?? textoONulo(r.resolution_note),
    diferencias,
  }
}

/** Los de un paciente, del más nuevo al más viejo. */
export function cambiosDelPaciente(cambios: ReadonlyArray<CambioPropuesto>, profileId: string): CambioPropuesto[] {
  return cambios.filter((c) => c.profileId === profileId).sort((a, b) => b.createdAt.localeCompare(a.createdAt))
}
