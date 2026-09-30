import { BANKS } from '@/features/admin/banks'

/**
 * Quién pagó, sacado de la descripción del movimiento.
 *
 * El banco escribe en texto plano quién hizo el pago móvil:
 *
 *   TELF.:584241875770 BANCO:0102 CED.:V30496254 PMPC pago
 *
 * Ahí está el teléfono, el banco de origen y la cédula del pagador. Hasta
 * ahora eso se quedaba en una columna oculta de la tabla, y para ponerle
 * dueño a un abono había que abrirla, leer la cédula y teclearla en el
 * buscador. Es un dato que ya estaba, copiado a mano.
 *
 * No hace falta guardar nada nuevo: la descripción entera ya se importa, así
 * que esto también funciona con los abonos que entraron hace semanas.
 *
 * Los dos valores salen en el formato en el que la base los guarda, que no es
 * el que se enseña: `document_number` son los dígitos pelados sin la letra, y
 * `phone_e164` lleva el 58 delante y NO lleva el '+'. Así el texto sale
 * directo al buscador del padrón, que compara con `ilike`.
 */

export type PayerHint = {
  /** Dígitos de la cédula, como los guarda `profiles.document_number`. */
  document: string | null
  /** La letra, para poder enseñarla: 'V', 'E', 'J'… */
  documentLetter: string | null
  /** 58 y diez dígitos, como los guarda `profiles.phone_e164`. */
  phone: string | null
  /** El código de cuatro dígitos del banco desde el que se pagó. */
  bankCode: string | null
  bankName: string | null
}

/**
 * `CED.:V30496254`, `C.I. 30.496.254`, `RIF J-123456789`.
 *
 * Se exige la palabra delante a propósito. Sin ella, `BANCO:0102` y el
 * importe también son números, y confundir uno con una cédula manda al
 * operador a buscar a una persona que no existe.
 */
const DOCUMENT_WITH_LABEL =
  /\b(?:c\.?\s?i\.?|ced(?:ula|\.)?|rif|doc(?:umento)?)\.?\s*:?\s*([vejpg])?\s*-?\s*(\d[\d.]{5,10})/i

/** Sin palabra delante, pero con la letra pegada: `V-30496254`. */
const DOCUMENT_WITH_LETTER = /\b([vejpg])-?\s?(\d{6,9})\b/i

const PHONE =
  /\b(?:telf?|tlf|tel[eé]fono|m[oó]vil|movil|celular)\.?\s*:?\s*\+?\s*(\d[\d\s().-]{6,14})/i

const BANK_CODE = /\bbanco\.?\s*:?\s*(\d{4})\b/i

/**
 * El teléfono al formato de la base.
 *
 * Un móvil venezolano se escribe de tres maneras y las tres significan lo
 * mismo: `584241875770`, `04241875770` y `4241875770`. Lo que no encaje en
 * ninguna se descarta — un teléfono a medias no encuentra a nadie y además
 * hace creer que se buscó.
 */
function normalizePhone(raw: string): string | null {
  const digits = raw.replace(/\D/g, '')

  if (digits.length === 12 && digits.startsWith('58')) return digits
  if (digits.length === 11 && digits.startsWith('0')) return `58${digits.slice(1)}`
  if (digits.length === 10 && !digits.startsWith('0')) return `58${digits}`

  return null
}

export function readPayerHint(description: string | null | undefined): PayerHint | null {
  if (!description) return null

  let document: string | null = null
  let documentLetter: string | null = null

  const labelled = DOCUMENT_WITH_LABEL.exec(description)
  const lettered = labelled ? null : DOCUMENT_WITH_LETTER.exec(description)
  const found = labelled ?? lettered

  if (found) {
    const digits = found[2].replace(/\D/g, '')
    // Una cédula venezolana tiene de seis a nueve dígitos; un RIF, nueve o
    // diez. Fuera de ahí es otra cosa que casó por accidente.
    if (digits.length >= 6 && digits.length <= 10) {
      document = digits
      // `.at()` y no `[1]`: el grupo de la letra es opcional y en tiempo de
      // ejecución viene undefined, cosa que el tipo de un RegExpExecArray no
      // dice. Es el mismo motivo por el que `formatDocument` lo hace así.
      documentLetter = found.at(1)?.toUpperCase() ?? null
    }
  }

  const phoneMatch = PHONE.exec(description)
  const phone = phoneMatch ? normalizePhone(phoneMatch[1]) : null

  const bankMatch = BANK_CODE.exec(description)
  const bankCode = bankMatch ? bankMatch[1] : null
  const bankName = bankCode
    ? (BANKS.find((b) => b.code === bankCode)?.name ?? null)
    : null

  if (document === null && phone === null) return null

  return { document, documentLetter, phone, bankCode, bankName }
}

/** Con la letra delante, para enseñarlo: 'V30496254'. `formatDocument` lo
 *  termina de vestir con los puntos de millar. */
export function payerDocument(hint: PayerHint): string | null {
  if (hint.document === null) return null
  return `${hint.documentLetter ?? 'V'}${hint.document}`
}

/**
 * ¿Esta persona es la que dice el banco?
 *
 * Se compara por dígitos porque los dos lados vienen escritos de maneras
 * distintas: la app guarda la cédula sin letra y el banco la manda con ella.
 */
export function matchesPayer(
  hint: PayerHint | null,
  person: { document: string | null; phone: string | null },
): boolean {
  if (!hint) return false

  const digits = (value: string | null) => (value ?? '').replace(/\D/g, '')

  if (hint.document !== null && digits(person.document) === hint.document) return true
  if (hint.phone !== null && digits(person.phone) === hint.phone) return true

  return false
}
