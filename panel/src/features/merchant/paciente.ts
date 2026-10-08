// ═══════════════════════════════════════════════════════════════════════════
// Los datos del paciente, tal como los teclea la secretaria.
//
// Todo lo de aquí es puro —sin red, sin React— para poder probarlo con
// `npx tsx` y para que la pantalla de Nuevo pago en cuotas no tenga una sola
// regla escrita dentro de un componente.
//
// ⚠️ La autoridad es la base. `create_patient_charge` vuelve a comprobar la
// edad, el teléfono, el correo y la referencia, y si algo no le cuadra lo
// rechaza con un texto en español que el panel enseña tal cual. Estas reglas
// existen para que la secretaria se entere ANTES, con el paciente delante,
// y no después de rellenar todo el formulario (docs/01-CONTRATO-RPC §1.3).
// ═══════════════════════════════════════════════════════════════════════════

// ── Cédula ────────────────────────────────────────────────────────────────

/** V (venezolano) o E (extranjero): las dos letras que admite el alta. */
export type Nacionalidad = 'V' | 'E'

/**
 * Lo que se tecleó en el número de cédula, sin puntos ni espacios.
 *
 * Se aceptan los puntos de millar porque así la dicta la gente —«doce
 * millones trescientos…» se apunta «12.345.678»— y así viene impresa. Lo que
 * no sea dígito se descarta, no se rechaza: el campo ya solo deja teclear
 * números, y pegar «V-12.345.678» tiene que funcionar igual.
 */
export function soloDigitos(texto: string): string {
  return texto.replace(/\D/g, '')
}

/**
 * La cédula como la pide la RPC: la letra y los dígitos, pegados
 * (`V12345678`). Sin ceros delante: «012345678» y «12345678» son la misma
 * persona y la base normaliza igual (`normalize_document`).
 */
export function cedulaParaEnviar(nacionalidad: Nacionalidad, numero: string): string {
  const digitos = soloDigitos(numero).replace(/^0+/, '')
  return `${nacionalidad}${digitos}`
}

/**
 * Por qué la cédula todavía no se puede consultar, o `null` si ya se puede.
 *
 * Entre 5 y 9 dígitos: las cédulas venezolanas van hoy por los 33 millones
 * (8 dígitos), las muy antiguas tienen 6 y las de extranjero pueden llegar a
 * 9 o 10 con el prefijo 8. Más de 10 es un error de tipeo seguro.
 */
export function problemaDeCedula(numero: string): string | null {
  const digitos = soloDigitos(numero).replace(/^0+/, '')
  if (digitos === '') return 'Escribe el número de cédula.'
  if (digitos.length < 5) return 'La cédula tiene muy pocos dígitos.'
  if (digitos.length > 10) return 'La cédula tiene demasiados dígitos.'
  return null
}

/** '12345678' → '12.345.678': como se lee en voz alta para confirmarla. */
export function cedulaLegible(numero: string): string {
  const digitos = soloDigitos(numero).replace(/^0+/, '')
  if (digitos === '') return ''
  return digitos.replace(/\B(?=(\d{3})+(?!\d))/g, '.')
}

// ── Fecha de nacimiento y edad ────────────────────────────────────────────

/**
 * La fecha de nacimiento que se tecleó, como 'YYYY-MM-DD', o `null` si no es
 * un día que exista.
 *
 * Se escribe con el día primero, como aquí: «12/04/1990», «12-4-90»,
 * «12.04.1990» o los ocho dígitos seguidos («12041990»). También la forma ISO.
 *
 * El año de dos cifras NO es «de este siglo» como en los filtros del panel:
 * aquí es una fecha de nacimiento, y «12/04/90» es 1990. Se toma el siglo
 * que deja la fecha en el pasado: si «20xx» caería después de hoy, es «19xx».
 */
export function leerFechaDeNacimiento(texto: string, hoy: string): string | null {
  const escrito = texto.trim()
  if (escrito === '') return null

  let d: number
  let m: number
  let y: number

  const iso = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(escrito)
  const nuestra = /^(\d{1,2})[/.\-\s](\d{1,2})[/.\-\s](\d{2}|\d{4})$/.exec(escrito)
  const pegada = /^(\d{2})(\d{2})(\d{4})$/.exec(escrito)

  if (iso) {
    y = Number(iso[1])
    m = Number(iso[2])
    d = Number(iso[3])
  } else if (nuestra) {
    d = Number(nuestra[1])
    m = Number(nuestra[2])
    y = Number(nuestra[3])
    if (nuestra[3].length === 2) {
      const siglo = Number(hoy.slice(0, 2)) * 100
      y = siglo + y
      if (y > Number(hoy.slice(0, 4))) y -= 100
    }
  } else if (pegada) {
    d = Number(pegada[1])
    m = Number(pegada[2])
    y = Number(pegada[3])
  } else {
    return null
  }

  const fecha = new Date(Date.UTC(y, m - 1, d))
  const existe =
    fecha.getUTCFullYear() === y && fecha.getUTCMonth() === m - 1 && fecha.getUTCDate() === d
  if (!existe) return null

  return `${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`
}

/**
 * La fecha mientras se teclea, con sus barras: «12041990» → «12/04/1990».
 *
 * Las barras las pone el campo, no la secretaria: solo teclea cifras. Aun
 * así, una barra (o un punto, un guion, un espacio) que sí teclee cierra el
 * tramo en el que está, y un día o un mes de una cifra se completa con su
 * cero: «1/4/90» queda «01/04/90». Un día que empieza por 4-9 o un mes que
 * empieza por 2-9 no pueden llevar segunda cifra, así que se cierran solos.
 *
 * La barra solo aparece cuando hay algo detrás (o cuando se tecleó): así
 * borrar con la tecla de retroceso nunca se atasca en una barra que vuelve.
 * La forma ISO que trae un pegado («1990-04-12») se da la vuelta. El año
 * admite dos cifras, igual que `leerFechaDeNacimiento`.
 */
export function formatearFecha(texto: string): string {
  const iso = /^\s*(\d{4})-(\d{1,2})-(\d{1,2})\s*$/.exec(texto)
  if (iso) return `${iso[3].padStart(2, '0')}/${iso[2].padStart(2, '0')}/${iso[1]}`

  const topes = [2, 2, 4]
  // Lo que no puede llevar segunda cifra: día de 4 a 9, mes de 2 a 9.
  const cierraSolo = [(c: string) => c > '3', (c: string) => c > '1', () => false]
  const partes = ['']
  let barraAlFinal = false

  for (const c of texto) {
    const i = partes.length - 1
    if (/\d/.test(c)) {
      if (partes[i].length === topes[i]) {
        if (i === 2) continue
        partes.push('')
      }
      const j = partes.length - 1
      if (partes[j] === '' && cierraSolo[j](c)) {
        partes[j] = `0${c}`
        if (j < 2) {
          partes.push('')
          barraAlFinal = true
          continue
        }
      } else {
        partes[j] += c
      }
      barraAlFinal = false
    } else if (/[/.\-\s]/.test(c)) {
      if (partes[i] === '' || i === 2) continue
      if (partes[i].length === 1) partes[i] = `0${partes[i]}`
      partes.push('')
      barraAlFinal = true
    }
  }

  const llenas = partes.filter((p) => p !== '')
  return llenas.join('/') + (barraAlFinal ? '/' : '')
}

/**
 * Lo que ya se sabe de una fecha a medio teclear, para abrir el selector en
 * el paso que falta: «12/04» → día 12 y mes 4, sin año. Una fecha entera la
 * lee `leerFechaDeNacimiento`, así que «12/04/90» trae el año de 1990.
 */
export function partesDeFecha(
  texto: string,
  hoy: string,
): { dia: number | null; mes: number | null; anio: number | null } {
  const entera = leerFechaDeNacimiento(texto, hoy)
  if (entera) {
    const [y, m, d] = entera.split('-').map(Number)
    return { dia: d, mes: m, anio: y }
  }
  const [d = '', m = '', y = ''] = formatearFecha(texto).split('/')
  const dia = Number(d)
  const mes = Number(m)
  return {
    dia: d !== '' && dia >= 1 && dia <= 31 ? dia : null,
    mes: m !== '' && mes >= 1 && mes <= 12 ? mes : null,
    anio: y.length === 4 ? Number(y) : null,
  }
}

/** Los días de un mes (1-12). Sin año, febrero cuenta 29: aún puede serlo. */
export function diasDelMes(mes: number, anio: number | null): number {
  if (mes === 2) {
    if (anio === null) return 29
    const bisiesto = (anio % 4 === 0 && anio % 100 !== 0) || anio % 400 === 0
    return bisiesto ? 29 : 28
  }
  return [4, 6, 9, 11].includes(mes) ? 30 : 31
}

/**
 * Años cumplidos el día `hoy` (los dos 'YYYY-MM-DD').
 *
 * Sin `Date` ni zona horaria: es aritmética de calendario sobre dos días, y
 * así el 29 de febrero y el cumpleaños de hoy salen bien. Quien nació un 29
 * de febrero cumple el 1 de marzo en los años que no son bisiestos, que es
 * lo que hace la base con `age()`.
 */
export function edadEn(nacimiento: string, hoy: string): number {
  const [ny = 0, nm = 1, nd = 1] = nacimiento.split('-').map(Number)
  const [hy = 0, hm = 1, hd = 1] = hoy.split('-').map(Number)

  let edad = hy - ny
  if (hm < nm || (hm === nm && hd < nd)) edad -= 1
  return edad
}

/** La mayoría de edad en Venezuela, y la del contrato. */
export const EDAD_MINIMA = 18

/** El texto del contrato para un titular menor, completado con qué hacer. */
export const MENSAJE_MENOR =
  'El titular debe ser mayor de edad. Si el paciente es menor, registra a su representante como titular y escribe el nombre del menor en «Paciente atendido».'

/**
 * Qué le pasa a la fecha de nacimiento, o `null` si vale.
 *
 * 110 años de tope: por encima casi siempre es un año mal tecleado (1919 por
 * 1991), y es mejor preguntarlo aquí que mandarle el comprobante a alguien
 * con una fecha imposible.
 */
export function problemaDeNacimiento(nacimiento: string | null, hoy: string): string | null {
  if (nacimiento === null) return 'Escribe la fecha como día/mes/año, por ejemplo 12/04/1990.'
  if (nacimiento > hoy) return 'La fecha de nacimiento es posterior a hoy.'
  const edad = edadEn(nacimiento, hoy)
  if (edad < EDAD_MINIMA) return MENSAJE_MENOR
  if (edad > 110) return 'Revisa el año: da más de 110 años.'
  return null
}

// ── Teléfono ──────────────────────────────────────────────────────────────

/**
 * Los prefijos móviles de Venezuela: Movilnet (0416, 0426), Movistar (0414,
 * 0424), Digitel (0412, 0422). El 0422 es de 2026 (20260926100000).
 */
export const PREFIJOS_MOVILES = ['0412', '0414', '0416', '0422', '0424', '0426'] as const

/**
 * El número en su forma nacional de 11 dígitos («04141234567»), que es la
 * que pide `create_patient_charge`, o `null` si no se puede leer como un
 * teléfono venezolano.
 *
 * Acepta lo que de verdad se escribe: con guiones, puntos, espacios o
 * paréntesis, sin el 0 de delante («4141234567»), o con el código de país
 * («+58 414 123 4567», «584141234567»).
 */
export function telefonoNacional(texto: string): string | null {
  let d = soloDigitos(texto)
  if (d.startsWith('58') && d.length === 12) d = d.slice(2)
  if (d.length === 10 && !d.startsWith('0')) d = `0${d}`
  if (d.length !== 11 || !d.startsWith('0')) return null
  return d
}

/** Si el número es un móvil venezolano (con WhatsApp, en principio). */
export function esMovil(texto: string): boolean {
  const n = telefonoNacional(texto)
  return n !== null && (PREFIJOS_MOVILES as readonly string[]).includes(n.slice(0, 4))
}

/**
 * Un fijo venezolano: 02XX y siete dígitos. Solo se admite en el teléfono del
 * contacto de referencia, que puede ser la casa de la madre.
 */
export function esFijo(texto: string): boolean {
  const n = telefonoNacional(texto)
  return n !== null && /^02\d{9}$/.test(n)
}

/** '04141234567' → '0414-123.45.67', como se dicta. Lo que no se lee, tal cual. */
export function telefonoLegible(texto: string): string {
  const n = telefonoNacional(texto)
  if (n === null) return texto.trim()
  return `${n.slice(0, 4)}-${n.slice(4, 7)}.${n.slice(7, 9)}.${n.slice(9)}`
}

/**
 * El teléfono mientras se teclea, con la forma en que se dicta:
 * «04141234567» → «0414-123.45.67». Solo cuentan las cifras.
 *
 * Se pone el 0 que se olvida («414…» → «0414…») y se quita el código de país
 * de un número pegado («+58 414 123 4567»). Más de 11 cifras no caben. Como
 * en la fecha, un separador solo aparece con algo detrás, para que borrar no
 * se atasque en él.
 */
export function formatearTelefono(texto: string): string {
  let d = soloDigitos(texto)
  if (d.startsWith('58') && d.length > 2) d = `0${d.slice(2)}`
  else if (d.startsWith('4') || d.startsWith('2')) d = `0${d}`
  d = d.slice(0, 11)

  let salida = d.slice(0, 4)
  if (d.length > 4) salida += `-${d.slice(4, 7)}`
  if (d.length > 7) salida += `.${d.slice(7, 9)}`
  if (d.length > 9) salida += `.${d.slice(9, 11)}`
  return salida
}

/** Qué le pasa al móvil del titular, o `null` si vale. */
export function problemaDeMovil(texto: string): string | null {
  if (soloDigitos(texto) === '') return 'Escribe el teléfono móvil.'
  if (telefonoNacional(texto) === null) return 'El número tiene que tener 11 dígitos, como 0414-123.45.67.'
  if (!esMovil(texto)) {
    return `Tiene que ser un móvil: ${PREFIJOS_MOVILES.join(', ')}.`
  }
  return null
}

// ── Correo ────────────────────────────────────────────────────────────────

/** El correo como se guarda: sin espacios y en minúsculas. */
export function correoLimpio(texto: string): string {
  return texto.trim().toLowerCase()
}

/**
 * Un correo con forma de correo. No se intenta más: la única prueba de verdad
 * es que el comprobante llegue, y si rebota Helios recibe una alerta.
 */
export function esCorreo(texto: string): boolean {
  return /^[^\s@]+@[^\s@.]+(\.[^\s@.]+)*\.[a-z]{2,}$/i.test(correoLimpio(texto))
}

/** Si el correo y su repetición son el mismo, sin contar mayúsculas ni espacios. */
export function correosCoinciden(a: string, b: string): boolean {
  return correoLimpio(a) === correoLimpio(b)
}

/**
 * Los dominios que de verdad usa la gente aquí. Contra ellos se buscan las
 * erratas: «gmial.com», «hotmial.com», «yahooo.es».
 */
const DOMINIOS_COMUNES = [
  'gmail.com',
  'hotmail.com',
  'hotmail.es',
  'outlook.com',
  'outlook.es',
  'yahoo.com',
  'yahoo.es',
  'icloud.com',
  'live.com',
]

/**
 * «¿Quisiste decir …@gmail.com?», o `null` si el dominio está bien o no se
 * parece a ninguno conocido.
 *
 * Un comprobante que no llega es un paciente que no sabe cuánto ni cuándo
 * pagar, y la errata de dominio es el fallo más común con diferencia. Solo se
 * sugiere, nunca se corrige solo: hay dominios propios que se parecen a
 * «gmail.com» y son buenos.
 */
export function sugerenciaDeCorreo(texto: string): string | null {
  const correo = correoLimpio(texto)
  const arroba = correo.lastIndexOf('@')
  if (arroba <= 0) return null

  const usuario = correo.slice(0, arroba)
  const dominio = correo.slice(arroba + 1)
  if (dominio === '' || DOMINIOS_COMUNES.includes(dominio)) return null

  let mejor: { dominio: string; distancia: number } | null = null
  for (const candidato of DOMINIOS_COMUNES) {
    const distancia = distanciaDeEdicion(dominio, candidato)
    if (distancia <= 2 && (mejor === null || distancia < mejor.distancia)) {
      mejor = { dominio: candidato, distancia }
    }
  }

  return mejor ? `${usuario}@${mejor.dominio}` : null
}

/** Levenshtein con transposición de vecinos (Damerau restringido). */
function distanciaDeEdicion(a: string, b: string): number {
  const filas = a.length + 1
  const columnas = b.length + 1
  const d: number[][] = Array.from({ length: filas }, () => new Array<number>(columnas).fill(0))

  for (let i = 0; i < filas; i++) d[i][0] = i
  for (let j = 0; j < columnas; j++) d[0][j] = j

  for (let i = 1; i < filas; i++) {
    for (let j = 1; j < columnas; j++) {
      const coste = a[i - 1] === b[j - 1] ? 0 : 1
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + coste)
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1)
      }
    }
  }

  return d[a.length][b.length]
}

// ── Dirección ─────────────────────────────────────────────────────────────

/**
 * Las 24 entidades federales, como las escribe la gente. Se guarda el nombre
 * tal cual (el contrato pone "Miranda"), no un código: lo lee una persona en
 * la ficha del paciente y en la cobranza.
 */
export const ESTADOS_DE_VENEZUELA = [
  'Amazonas',
  'Anzoátegui',
  'Apure',
  'Aragua',
  'Barinas',
  'Bolívar',
  'Carabobo',
  'Cojedes',
  'Delta Amacuro',
  'Distrito Capital',
  'Falcón',
  'Guárico',
  'La Guaira',
  'Lara',
  'Mérida',
  'Miranda',
  'Monagas',
  'Nueva Esparta',
  'Portuguesa',
  'Sucre',
  'Táchira',
  'Trujillo',
  'Yaracuy',
  'Zulia',
] as const

export type EstadoDeVenezuela = (typeof ESTADOS_DE_VENEZUELA)[number]

/** Los parentescos que se ofrecen en la referencia. Se puede escribir otro. */
export const PARENTESCOS = [
  'Madre',
  'Padre',
  'Hermano/a',
  'Hijo/a',
  'Esposo/a',
  'Pareja',
  'Abuelo/a',
  'Tío/a',
  'Primo/a',
  'Amigo/a',
  'Compañero/a de trabajo',
] as const

// ── El formulario entero ──────────────────────────────────────────────────

/** Lo que se teclea de un paciente nuevo, todo como texto de campo. */
export type BorradorPaciente = {
  firstName: string
  lastName: string
  /** Tal como se tecleó: «12/04/1990». */
  birthDate: string
  sex: 'F' | 'M' | ''
  phone: string
  email: string
  emailConfirm: string
  state: string
  city: string
  address: string
  occupation: string
  referenceName: string
  referencePhone: string
  referenceRelationship: string
}

export const PACIENTE_VACIO: BorradorPaciente = {
  firstName: '',
  lastName: '',
  birthDate: '',
  sex: '',
  phone: '',
  email: '',
  emailConfirm: '',
  state: '',
  city: '',
  address: '',
  occupation: '',
  referenceName: '',
  referencePhone: '',
  referenceRelationship: '',
}

export type CampoDePaciente = keyof BorradorPaciente

/** El orden en que se rellenan: el primer campo con problema recibe el foco. */
export const ORDEN_DE_CAMPOS: CampoDePaciente[] = [
  'firstName',
  'lastName',
  'birthDate',
  'sex',
  'phone',
  'email',
  'emailConfirm',
  'state',
  'city',
  'address',
  'occupation',
  'referenceName',
  'referencePhone',
  'referenceRelationship',
]

/** Un texto con los espacios de sobra quitados. */
export function limpio(texto: string): string {
  return texto.trim().replace(/\s+/g, ' ')
}

const TOPE_DIRECCION = 160
const TOPE_TEXTO = 80

/**
 * Los problemas de cada campo, por nombre. Vacío = se puede seguir.
 *
 * Las mismas reglas que la base, más dos que solo tienen sentido con alguien
 * tecleando: el correo escrito dos veces y el teléfono de referencia distinto
 * del propio (una referencia que es el mismo número no sirve para cobrar).
 */
export function problemasDelPaciente(
  p: BorradorPaciente,
  hoy: string,
): Partial<Record<CampoDePaciente, string>> {
  const e: Partial<Record<CampoDePaciente, string>> = {}

  if (limpio(p.firstName).length < 2) e.firstName = 'Escribe el nombre.'
  else if (limpio(p.firstName).length > TOPE_TEXTO) e.firstName = 'El nombre es demasiado largo.'

  if (limpio(p.lastName).length < 2) e.lastName = 'Escribe el apellido.'
  else if (limpio(p.lastName).length > TOPE_TEXTO) e.lastName = 'El apellido es demasiado largo.'

  const nacimiento = p.birthDate.trim() === '' ? null : leerFechaDeNacimiento(p.birthDate, hoy)
  const problemaNacimiento =
    p.birthDate.trim() === ''
      ? 'Escribe la fecha de nacimiento.'
      : problemaDeNacimiento(nacimiento, hoy)
  if (problemaNacimiento) e.birthDate = problemaNacimiento

  if (p.sex === '') e.sex = 'Elige el sexo.'

  const movil = problemaDeMovil(p.phone)
  if (movil) e.phone = movil

  if (correoLimpio(p.email) === '') e.email = 'Escribe el correo: ahí le llega el comprobante.'
  else if (!esCorreo(p.email)) e.email = 'El correo no tiene forma de correo (nombre@dominio.com).'

  if (correoLimpio(p.emailConfirm) === '') e.emailConfirm = 'Escribe el correo otra vez.'
  else if (!correosCoinciden(p.email, p.emailConfirm)) e.emailConfirm = 'Los dos correos no coinciden.'

  if (p.state === '') e.state = 'Elige el estado.'
  if (limpio(p.city).length < 2) e.city = 'Escribe la ciudad.'

  if (limpio(p.address).length < 5) e.address = 'Escribe la dirección.'
  else if (limpio(p.address).length > TOPE_DIRECCION) {
    e.address = `La dirección no puede pasar de ${TOPE_DIRECCION} caracteres.`
  }

  if (limpio(p.occupation).length > TOPE_TEXTO) e.occupation = 'La ocupación es demasiado larga.'

  if (limpio(p.referenceName).length < 2) e.referenceName = 'Falta el contacto de referencia.'

  if (soloDigitos(p.referencePhone) === '') {
    e.referencePhone = 'Escribe el teléfono de la referencia.'
  } else if (!esMovil(p.referencePhone) && !esFijo(p.referencePhone)) {
    e.referencePhone = 'El número tiene que tener 11 dígitos, como 0424-123.45.67.'
  } else if (telefonoNacional(p.referencePhone) === telefonoNacional(p.phone)) {
    e.referencePhone = 'Es el mismo teléfono del paciente: la referencia tiene que ser otra persona.'
  }

  if (limpio(p.referenceRelationship).length < 2) {
    e.referenceRelationship = 'Escribe el parentesco.'
  }

  return e
}

/**
 * El `p_patient` de `create_patient_charge`, con cada campo ya normalizado.
 * Solo se llama con un borrador sin problemas.
 */
export function pacienteParaEnviar(
  documento: string,
  p: BorradorPaciente,
  hoy: string,
): Record<string, string | null> {
  const ocupacion = limpio(p.occupation)
  return {
    document: documento,
    first_name: limpio(p.firstName),
    last_name: limpio(p.lastName),
    birth_date: leerFechaDeNacimiento(p.birthDate, hoy),
    sex: p.sex === '' ? null : p.sex,
    phone: telefonoNacional(p.phone),
    email: correoLimpio(p.email),
    state: p.state,
    city: limpio(p.city),
    address: limpio(p.address),
    occupation: ocupacion === '' ? null : ocupacion,
    reference_name: limpio(p.referenceName),
    reference_phone: telefonoNacional(p.referencePhone),
    reference_relationship: limpio(p.referenceRelationship),
  }
}

/** Si se ha tecleado algo en el formulario: para avisar antes de perderlo. */
export function hayDatosDePaciente(p: BorradorPaciente): boolean {
  return (Object.keys(p) as CampoDePaciente[]).some((k) => p[k] !== '')
}
