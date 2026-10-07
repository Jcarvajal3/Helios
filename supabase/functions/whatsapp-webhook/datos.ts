// ═══════════════════════════════════════════════════════════════════════════
// Helios — Los datos del paciente en el chat del bot (docs/00 §2.2 y §15.4)
//
// El médico manda los datos de un paciente nuevo en un solo mensaje. Si usa
// el formulario (una línea «Etiqueta: valor» por dato), se lee aquí sin IA y
// sin margen de error. Si escribe libre, los extrae Gemini (gemini.ts) a la
// misma forma. En los dos casos, QUÉ FALTA lo decide este código, no el
// modelo, y la base revalida todo al registrar.
//
// Módulo puro: lo prueba `datos.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

import { normalizar } from './logica.ts'

/** Los datos de un paciente nuevo, con las claves de `p_patient` (docs/01 §1.3). */
export type DatosDelPaciente = {
  first_name?: string
  last_name?: string
  birth_date?: string
  sex?: string
  phone?: string
  email?: string
  state?: string
  city?: string
  address?: string
  occupation?: string
  reference_name?: string
  reference_phone?: string
  reference_relationship?: string
}

/**
 * La moneda en la que el médico cobra la consulta (decisión del 2026-10-07).
 * El paciente paga siempre en bolívares, a la tasa BCV de esa moneda del día
 * en que paga.
 */
export type Moneda = 'USD' | 'EUR'

/**
 * Lo que trae un mensaje: datos del paciente y, si vienen, monto, moneda,
 * concepto y paciente atendido. La moneda queda en null si no se dijo: el
 * bot la pregunta.
 */
export type Lectura = {
  paciente: DatosDelPaciente
  monto: number | null
  moneda: Moneda | null
  concepto: string | null
  atendido: string | null
}

/** El formulario que el bot ofrece para copiar, llenar y enviar. */
export const FORMULARIO = [
  'Nombres:',
  'Apellidos:',
  'Nacimiento (dd/mm/aaaa):',
  'Sexo (F/M):',
  'Teléfono:',
  'Correo:',
  'Estado:',
  'Ciudad:',
  'Dirección:',
  'Referencia (nombre):',
  'Teléfono de la referencia:',
  'Parentesco:',
  'Monto:',
  'Moneda (dólares o euros):',
  'Concepto:',
].join('\n')

type Clave = keyof DatosDelPaciente | 'monto' | 'moneda' | 'concepto' | 'atendido'

/** Cada etiqueta (normalizada, sin lo que va entre paréntesis) → su campo. */
const ETIQUETAS: Record<string, Clave> = {
  nombre: 'first_name',
  nombres: 'first_name',
  apellido: 'last_name',
  apellidos: 'last_name',
  nacimiento: 'birth_date',
  'fecha de nacimiento': 'birth_date',
  sexo: 'sex',
  telefono: 'phone',
  celular: 'phone',
  'telefono del paciente': 'phone',
  correo: 'email',
  email: 'email',
  'correo electronico': 'email',
  estado: 'state',
  ciudad: 'city',
  direccion: 'address',
  ocupacion: 'occupation',
  referencia: 'reference_name',
  'nombre de la referencia': 'reference_name',
  'contacto de referencia': 'reference_name',
  'telefono de la referencia': 'reference_phone',
  'telefono de referencia': 'reference_phone',
  parentesco: 'reference_relationship',
  monto: 'monto',
  moneda: 'moneda',
  concepto: 'concepto',
  'paciente atendido': 'atendido',
  atendido: 'atendido',
}

/** «12/04/1990», «12-04-1990» o «1990-04-12» → «1990-04-12». Lo demás, tal cual. */
export function normalizarFecha(v: string): string {
  const t = v.trim()
  const dmy = /^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{4})$/.exec(t)
  if (dmy) {
    const [, d, m, y] = dmy
    return `${y}-${m.padStart(2, '0')}-${d.padStart(2, '0')}`
  }
  return t
}

/** F/femenino/mujer → F; M/masculino/hombre → M; lo demás, tal cual (la base lo rechaza). */
export function normalizarSexo(v: string): string {
  const n = normalizar(v)
  if (['f', 'femenino', 'mujer'].includes(n)) return 'F'
  if (['m', 'masculino', 'hombre'].includes(n)) return 'M'
  return v.trim()
}

/** «80», «$80,50», «80.5 dólares» → 80.5. Null si no hay un número. */
export function leerMonto(v: string): number | null {
  const m = /(\d{1,6}(?:[.,]\d{1,2})?)/.exec(v.replace(/\s/g, ''))
  if (!m) return null
  const n = Number(m[1].replace(',', '.'))
  return Number.isFinite(n) && n > 0 ? n : null
}

/** «$», «usd», «dólares» → USD; «€», «eur», «euros» → EUR. */
function monedaDeLaPalabra(p: string): Moneda {
  return /^(€|eur)/i.test(p) ? 'EUR' : 'USD'
}

const PALABRAS_DEL_DOLAR = new Set(['dolar', 'dolares', 'usd', 'us', 'americanos'])
const PALABRAS_DEL_EURO = new Set(['euro', 'euros', 'eur'])

/**
 * Una moneda escrita sola: «dólares», «en euros», «USD», «€», o el título
 * del botón («Dólares (USD)»). Null si el texto dice otra cosa.
 */
export function leerMoneda(t: string): Moneda | null {
  const crudo = t.trim()
  if (crudo === '$' || crudo.toUpperCase() === 'US$') return 'USD'
  if (crudo === '€') return 'EUR'
  const palabras = normalizar(crudo).split(' ').filter((p) => p !== '' && p !== 'en')
  if (palabras.length === 0) return null
  if (palabras.every((p) => PALABRAS_DEL_DOLAR.has(p))) return 'USD'
  if (palabras.every((p) => PALABRAS_DEL_EURO.has(p))) return 'EUR'
  return null
}

/**
 * El monto con su moneda pegada, si la tiene: delante («$80», «€80», «USD
 * 80») o detrás («80$», «80€», «80 euros», «80 eur», «80 dólares»). La
 * palabra no puede seguir: «80 eurocolor» no es en euros.
 */
const MONTO_CON_MONEDA =
  /(?:(?<![a-záéíóúñ])(\$|€|us\$|usd|eur|euros?|d[oó]lares)\s*)?(\d{1,6}(?:[.,]\d{1,2})?)(?:\s*(\$|€|usd|eur|euros?|d[oó]lar(?:es)?)(?![a-záéíóúñ]))?/iu

/** «… en euros», «… dólares» al final del concepto: la moneda dicha aparte. */
const MONEDA_AL_FINAL = /(?:^|\s)(?:en\s+)?(euros?|eur|d[oó]lares|usd)$/iu

/**
 * «80 consulta», «$80,50 consulta + eco», «consulta 80», «€80 consulta»,
 * «80€», «80 euros», «consulta 80 en euros» → monto, moneda y concepto. La
 * moneda va en null si no se escribió (el bot la pregunta). Null si no hay
 * un monto.
 */
export function leerMontoYConcepto(t: string): { monto: number; moneda: Moneda | null; concepto: string | null } | null {
  const m = MONTO_CON_MONEDA.exec(t)
  if (!m) return null
  const monto = Number(m[2].replace(',', '.'))
  if (!Number.isFinite(monto) || monto <= 0) return null
  const escrita = m[1] ?? m[3]
  let moneda: Moneda | null = escrita ? monedaDeLaPalabra(escrita) : null
  let resto = (t.slice(0, m.index) + ' ' + t.slice(m.index + m[0].length)).replace(/\s+/g, ' ').trim()
  if (!moneda) {
    const aparte = MONEDA_AL_FINAL.exec(resto)
    if (aparte) {
      moneda = monedaDeLaPalabra(aparte[1])
      resto = resto.slice(0, aparte.index)
    }
  }
  const concepto = resto.replace(/^[\s,.;:-]+|[\s,.;:-]+$/g, '')
  return { monto, moneda, concepto: concepto === '' ? null : concepto.slice(0, 80) }
}

/** «V-12.345.678», «e12345678», «12345678» (→ V) → «V12345678». Null si no es una cédula. */
export function leerCedula(t: string): string | null {
  const s = t.toUpperCase().replace(/[\s.\-]/g, '')
  const m = /^([VE])?(\d{6,9})$/.exec(s)
  if (!m) return null
  return `${m[1] ?? 'V'}${m[2]}`
}

/**
 * Lee un mensaje con el formulario: una línea «Etiqueta: valor» por dato.
 * `etiquetado` es true si reconoció al menos tres etiquetas (entonces no hace
 * falta la IA). Las líneas sin valor se ignoran.
 */
export function leerFormulario(t: string): Lectura & { etiquetado: boolean } {
  const paciente: DatosDelPaciente = {}
  let monto: number | null = null
  let monedaDelMonto: Moneda | null = null
  let moneda: Moneda | null = null
  let concepto: string | null = null
  let atendido: string | null = null
  let reconocidas = 0

  for (const linea of t.split(/\r?\n/)) {
    const i = linea.indexOf(':')
    if (i <= 0) continue
    const crudo = linea.slice(0, i)
    const etiqueta = normalizar(crudo.replace(/\(.*?\)/g, ''))
    const valor = linea.slice(i + 1).trim()
    const clave = ETIQUETAS[etiqueta]
    if (!clave) continue
    reconocidas++
    if (valor === '') continue

    if (clave === 'monto') {
      // La moneda puede venir en el valor («€80», «80 euros») o en la
      // etiqueta de un formulario viejo («Monto ($): 80»).
      monto = leerMonto(valor)
      monedaDelMonto = leerMontoYConcepto(valor)?.moneda ?? leerMoneda(/\((.*?)\)/.exec(crudo)?.[1] ?? '')
    } else if (clave === 'moneda') moneda = leerMoneda(valor)
    else if (clave === 'concepto') concepto = valor.slice(0, 80)
    else if (clave === 'atendido') atendido = valor.slice(0, 120)
    else if (clave === 'birth_date') paciente.birth_date = normalizarFecha(valor)
    else if (clave === 'sex') paciente.sex = normalizarSexo(valor)
    else if (clave === 'email') paciente.email = valor.toLowerCase()
    else paciente[clave] = valor
  }

  // La línea «Moneda:» manda sobre lo que acompañe al monto.
  return { paciente, monto, moneda: moneda ?? monedaDelMonto, concepto, atendido, etiquetado: reconocidas >= 3 }
}

/** Los obligatorios de un paciente nuevo (docs/00 §2.1), con su nombre para el médico. */
const OBLIGATORIOS: Array<[keyof DatosDelPaciente, string]> = [
  ['first_name', 'Nombres'],
  ['last_name', 'Apellidos'],
  ['birth_date', 'Nacimiento (dd/mm/aaaa)'],
  ['sex', 'Sexo (F/M)'],
  ['phone', 'Teléfono'],
  ['email', 'Correo'],
  ['state', 'Estado'],
  ['city', 'Ciudad'],
  ['address', 'Dirección'],
  ['reference_name', 'Referencia (nombre)'],
  ['reference_phone', 'Teléfono de la referencia'],
  ['reference_relationship', 'Parentesco'],
]

/** Lo que falta, como etiquetas del formulario para que el médico las copie. */
export function faltantes(p: DatosDelPaciente): string[] {
  return OBLIGATORIOS.filter(([k]) => !p[k] || p[k]!.trim() === '').map(([, e]) => e)
}

/** Junta lo nuevo sobre lo que ya había: lo nuevo gana, lo vacío no borra. */
export function juntar(antes: DatosDelPaciente, nuevo: DatosDelPaciente): DatosDelPaciente {
  const out: DatosDelPaciente = { ...antes }
  for (const [k, v] of Object.entries(nuevo) as Array<[keyof DatosDelPaciente, string | undefined]>) {
    if (typeof v === 'string' && v.trim() !== '') out[k] = v.trim()
  }
  return out
}

/** Los miles con punto y los céntimos con coma; con `siempre`, también el «,00». */
function conCentimos(n: number, siempre: boolean): string {
  const centimos = Math.round(n * 100)
  const entero = Math.trunc(centimos / 100)
  const dec = Math.abs(centimos % 100)
  const miles = String(entero).replace(/\B(?=(\d{3})+(?!\d))/g, '.')
  return dec === 0 && !siempre ? miles : `${miles},${String(dec).padStart(2, '0')}`
}

/**
 * Un monto al estilo venezolano (como `helios_money_text` en la base):
 * «100», «1,92», «1.250,50». Sin «,00» si es entero.
 */
export function montoEs(n: number): string {
  return conCentimos(n, false)
}

/** «$61,60», «$100». */
export function dinero(n: number): string {
  return dineroEn(n, 'USD')
}

/** «$100», «€56,96», «€1.250,50» (como `helios_money_cur_text` en la base). */
export function dineroEn(n: number, moneda: Moneda): string {
  return `${moneda === 'EUR' ? '€' : '$'}${montoEs(n)}`
}

/** «Bs 55.432,10»: los bolívares siempre con sus dos decimales (como `helios_ves_text`). */
export function bolivares(n: number): string {
  return `Bs ${conCentimos(n, true)}`
}

/** 'USD' → «dólar», 'EUR' → «euro»: «la tasa BCV del euro». */
export function nombreDeLaMoneda(m: Moneda): string {
  return m === 'EUR' ? 'euro' : 'dólar'
}

/** 'USD' → «dólares», 'EUR' → «euros». */
export function enPlural(m: Moneda): string {
  return m === 'EUR' ? 'euros' : 'dólares'
}

/** Lo que manda la base ('USD' | 'EUR', o nada en una fila vieja) → una moneda. */
export function monedaDe(v: unknown): Moneda {
  return v === 'EUR' ? 'EUR' : 'USD'
}

/**
 * Unos dólares en euros con `usd_per_eur` (dólares por euro), truncado al
 * céntimo: lo disponible nunca se promete un céntimo por encima. Antes de
 * truncar se redondea a 6 decimales, para que la coma flotante no reste un
 * céntimo a una división exacta.
 */
export function enEuros(usd: number, usdPorEur: number): number {
  return Math.trunc(Math.round((usd / usdPorEur) * 1e6) / 1e4) / 100
}

const DIAS = ['dom', 'lun', 'mar', 'mié', 'jue', 'vie', 'sáb']

/** «lun 12/10» para «2026-10-12» (una fecha, sin hora: en UTC a propósito). */
export function diaCorto(fecha: string): string {
  const [y, m, d] = fecha.slice(0, 10).split('-').map(Number)
  const f = new Date(Date.UTC(y, m - 1, d))
  return `${DIAS[f.getUTCDay()]} ${String(d).padStart(2, '0')}/${String(m).padStart(2, '0')}`
}

/** «16:40» en Caracas para un instante ISO. */
export function horaCaracas(iso: string | null): string {
  if (!iso) return ''
  return new Intl.DateTimeFormat('es-VE', {
    timeZone: 'America/Caracas',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(new Date(iso))
}

// ── Lo que devuelve la IA ──────────────────────────────────────────────────

/**
 * El texto generado de una respuesta de la API de Interactions de Gemini, o
 * null si la interacción no terminó o no trae texto. Tolerante a la forma:
 * `output_text` si viene; si no, el último texto dentro de `steps`.
 */
export function textoDeLaInteraccion(cuerpo: unknown): string | null {
  if (typeof cuerpo !== 'object' || cuerpo === null) return null
  const r = cuerpo as Record<string, unknown>
  if (typeof r.status === 'string' && r.status !== 'completed') return null
  if (typeof r.output_text === 'string' && r.output_text.trim() !== '') return r.output_text

  let ultimo: string | null = null
  const recorrer = (v: unknown): void => {
    if (Array.isArray(v)) {
      v.forEach(recorrer)
    } else if (typeof v === 'object' && v !== null) {
      for (const [k, x] of Object.entries(v)) {
        if (k === 'text' && typeof x === 'string' && x.trim() !== '') ultimo = x
        else recorrer(x)
      }
    }
  }
  recorrer(r.steps ?? r.outputs ?? null)
  return ultimo
}

function textoONulo(v: unknown, max = 200): string | undefined {
  return typeof v === 'string' && v.trim() !== '' ? v.trim().slice(0, max) : undefined
}

const CLAVES: Array<keyof DatosDelPaciente> = [
  'first_name', 'last_name', 'birth_date', 'sex', 'phone', 'email', 'state', 'city', 'address',
  'occupation', 'reference_name', 'reference_phone', 'reference_relationship',
]

/**
 * El JSON de la IA → una `Lectura`. Se queda solo con las claves conocidas y
 * con texto; normaliza la fecha, el sexo y el correo como el formulario.
 * Null si no es un objeto.
 */
export function lecturaDeLaIA(v: unknown): Lectura | null {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return null
  const d = v as Record<string, unknown>
  const paciente: DatosDelPaciente = {}
  for (const k of CLAVES) {
    const x = textoONulo(d[k])
    if (x !== undefined) paciente[k] = x
  }
  if (paciente.birth_date) paciente.birth_date = normalizarFecha(paciente.birth_date)
  if (paciente.sex) paciente.sex = normalizarSexo(paciente.sex)
  if (paciente.email) paciente.email = paciente.email.toLowerCase()
  const monto = typeof d.monto === 'number' && Number.isFinite(d.monto) && d.monto > 0 ? d.monto : null
  const mon = typeof d.moneda === 'string' ? d.moneda.trim().toUpperCase() : ''
  const moneda = mon === 'USD' || mon === 'EUR' ? mon : null
  return {
    paciente,
    monto,
    moneda,
    concepto: textoONulo(d.concepto, 80) ?? null,
    atendido: textoONulo(d.atendido, 120) ?? null,
  }
}
