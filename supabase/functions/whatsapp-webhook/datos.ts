// ═══════════════════════════════════════════════════════════════════════════
// Helios — Los datos del paciente en el chat del bot (docs/00 §2.2 y §15.4)
//
// El médico manda los datos de un paciente nuevo en un solo mensaje. Si usa
// el formulario (una línea «Etiqueta: valor» por dato), se lee aquí sin IA y
// sin margen de error. Si escribe libre, los extrae Claude (claude.ts) a la
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

/** Lo que trae un mensaje: datos del paciente y, si vienen, monto, concepto y paciente atendido. */
export type Lectura = {
  paciente: DatosDelPaciente
  monto: number | null
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
  'Monto ($):',
  'Concepto:',
].join('\n')

type Clave = keyof DatosDelPaciente | 'monto' | 'concepto' | 'atendido'

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

/**
 * «80 consulta», «$80,50 consulta + eco», «consulta 80» → monto y concepto.
 * Null si no hay un monto.
 */
export function leerMontoYConcepto(t: string): { monto: number; concepto: string | null } | null {
  const m = /\$?\s*(\d{1,6}(?:[.,]\d{1,2})?)\s*(?:\$|usd|dolares|dólares)?/i.exec(t)
  if (!m) return null
  const monto = Number(m[1].replace(',', '.'))
  if (!Number.isFinite(monto) || monto <= 0) return null
  const concepto = (t.slice(0, m.index) + ' ' + t.slice(m.index + m[0].length))
    .replace(/\s+/g, ' ')
    .replace(/^[\s,.;:-]+|[\s,.;:-]+$/g, '')
  return { monto, concepto: concepto === '' ? null : concepto.slice(0, 80) }
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
 * falta Claude). Las líneas sin valor se ignoran.
 */
export function leerFormulario(t: string): Lectura & { etiquetado: boolean } {
  const paciente: DatosDelPaciente = {}
  let monto: number | null = null
  let concepto: string | null = null
  let atendido: string | null = null
  let reconocidas = 0

  for (const linea of t.split(/\r?\n/)) {
    const i = linea.indexOf(':')
    if (i <= 0) continue
    const etiqueta = normalizar(linea.slice(0, i).replace(/\(.*?\)/g, ''))
    const valor = linea.slice(i + 1).trim()
    const clave = ETIQUETAS[etiqueta]
    if (!clave) continue
    reconocidas++
    if (valor === '') continue

    if (clave === 'monto') monto = leerMonto(valor)
    else if (clave === 'concepto') concepto = valor.slice(0, 80)
    else if (clave === 'atendido') atendido = valor.slice(0, 120)
    else if (clave === 'birth_date') paciente.birth_date = normalizarFecha(valor)
    else if (clave === 'sex') paciente.sex = normalizarSexo(valor)
    else if (clave === 'email') paciente.email = valor.toLowerCase()
    else paciente[clave] = valor
  }

  return { paciente, monto, concepto, atendido, etiquetado: reconocidas >= 3 }
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

/** «$61.60». */
export function dinero(n: number): string {
  return `$${n.toFixed(2)}`
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
