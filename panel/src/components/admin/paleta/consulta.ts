import { normalizar } from '@/features/admin/catalogo'

// ═══════════════════════════════════════════════════════════════════════════
// Qué parece lo tecleado en la paleta.
//
// Casi toda llamada empieza con un dato suelto: un teléfono dictado a su
// manera, una cédula con o sin letra, «la orden 1043» o la referencia de una
// transferencia. Aquí se decide qué puede ser cada cosa, con qué aguja se le
// pregunta a cada fuente y en qué orden salen los grupos.
//
// Módulo puro, sin React ni Supabase: se prueba en `consulta.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Lo que parece el texto, de lo más específico a lo más general. Decide qué
 * grupos se buscan y en qué orden salen.
 *
 *   orden       «#1043», «orden 1043», «nº 1043».
 *   referencia  «ref 123456», «referencia: 123456».
 *   telefono    «0414-123 4567», «+58 414 1234567», «584141234567».
 *   cedula      «V-12.345.678», «E 81234567», «12.345.678».
 *   rif         «J-12345678-9»: el de un local.
 *   numero      solo cifras y sin más pistas: puede ser una orden, una
 *               referencia, una cédula o el trozo de un teléfono.
 *   texto       un nombre, una pantalla o una palabra del negocio.
 */
export type Forma =
  | 'vacio'
  | 'orden'
  | 'referencia'
  | 'telefono'
  | 'cedula'
  | 'rif'
  | 'numero'
  | 'texto'

export type Consulta = {
  /** Lo tecleado, sin los espacios de los extremos. */
  texto: string
  /** Sin tildes ni mayúsculas: lo que se compara en el cliente. */
  normal: string
  forma: Forma
  /** Solo las cifras de lo tecleado. */
  digitos: string
  /** La aguja para `admin_user_directory`, o `null` si no toca buscar personas. */
  personas: string | null
  /** El número de orden, si puede serlo. */
  orden: number | null
  /** Las cifras de la referencia, si puede serlo. */
  referencia: string | null
}

/** Los grupos de resultados de la paleta. */
export type IdGrupo =
  | 'recientes'
  | 'atajos'
  | 'pantallas'
  | 'acciones'
  | 'personas'
  | 'locales'
  | 'consumos'
  | 'pagos'
  | 'cifras'
  | 'terminos'
  /** «Preguntarle al asistente»: no busca, lleva lo tecleado al asistente. */
  | 'asistente'

export const TITULO_DE_GRUPO: Record<IdGrupo, string> = {
  recientes: 'Recientes',
  atajos: 'Atajos',
  pantallas: 'Ir a',
  acciones: 'Hacer',
  personas: 'Pacientes',
  locales: 'Clínicas',
  consumos: 'Financiamientos',
  pagos: 'Pagos reportados',
  cifras: 'Cifras',
  terminos: 'Qué significa',
  asistente: 'Asistente',
}

/** Cómo se nombra un grupo dentro de una frase: «en pagos reportados». */
export function enElGrupo(id: IdGrupo): string {
  return TITULO_DE_GRUPO[id].toLocaleLowerCase('es')
}

/** Los números de orden arrancan en 1000 (`charges.order_number`). */
const PRIMERA_ORDEN = 1000

/**
 * Hasta cuántas cifras se toma por orden un número suelto. La base acepta 18,
 * pero un número de diez cifras es un teléfono o una referencia, no la orden
 * diez mil millones. Con almohadilla se respeta lo que diga quien teclea.
 */
const CIFRAS_DE_UNA_ORDEN = 9

/** Menos cifras que esto no se busca en el servidor: casaría con media base. */
const CIFRAS_MINIMAS = 4

/** Lo más largo que se acepta como referencia bancaria. */
const CIFRAS_DE_UNA_REFERENCIA = 30

const ORDEN = /^(?:#|orden\s*#?|n[°º]\.?)\s*(\d{1,18})$/i
const REFERENCIA = /^ref(?:erencia)?\.?:?\s*([\d\s-]+)$/i
const CEDULA_CON_LETRA = /^[ve]\s*[-.]?\s*(\d{1,3}(?:\.\d{3}){1,2}|\d{5,9})$/i
/** Con puntos de millar y al menos seis cifras: «1.250» es más bien una orden. */
const CEDULA_CON_PUNTOS = /^(?:\d{1,3}\.\d{3}\.\d{3}|\d{3}\.\d{3})$/
const RIF = /^[jg]\s*-?\s*(\d{5,9})\s*-?\s*(\d)?$/i
/** Cifras con los separadores con que se dicta un teléfono. */
const SOLO_CIFRAS = /^\+?[\d\s().-]+$/

export function soloDigitos(texto: string): string {
  return texto.replace(/\D/g, '')
}

/**
 * El teléfono sin el país ni el cero: '04141234567', '584141234567' y
 * '4141234567' dan '4141234567'.
 *
 * La base guarda '584141234567', y la gente dicta '0414…': el cero de delante
 * no está dentro de lo guardado, así que buscarlo tal cual no encontraría a
 * nadie. Sin el cero, sí está.
 */
export function parteNacional(digitos: string): string {
  if (/^584\d{9}$/.test(digitos)) return digitos.slice(2)
  if (digitos.startsWith('0')) return digitos.slice(1)
  return digitos
}

function pareceTelefono(digitos: string, conMas: boolean): boolean {
  if (conMas) return digitos.length >= 5
  return /^04\d{3,9}$/.test(digitos) || /^584\d{9}$/.test(digitos) || /^4\d{9}$/.test(digitos)
}

/** Lo que devuelve `interpretar` para cualquier forma, antes de rellenarla. */
function base(texto: string, forma: Forma, digitos = soloDigitos(texto)): Consulta {
  return {
    texto,
    normal: normalizar(texto),
    forma,
    digitos,
    personas: null,
    orden: null,
    referencia: null,
  }
}

/** Qué puede ser lo tecleado, y con qué se le pregunta a cada fuente. */
export function interpretar(crudo: string): Consulta {
  const texto = crudo.trim()
  if (!texto) return base('', 'vacio', '')

  const orden = texto.match(ORDEN)
  if (orden) {
    const c = base(texto, 'orden', orden[1])
    return { ...c, orden: Number(orden[1]) }
  }

  const referencia = texto.match(REFERENCIA)
  if (referencia) {
    const digitos = soloDigitos(referencia[1])
    const c = base(texto, 'referencia', digitos)
    const vale = digitos.length >= CIFRAS_MINIMAS && digitos.length <= CIFRAS_DE_UNA_REFERENCIA
    return { ...c, referencia: vale ? digitos : null }
  }

  const cedula = texto.match(CEDULA_CON_LETRA) ?? texto.match(CEDULA_CON_PUNTOS)
  if (cedula) {
    // Sin la letra ni los puntos: la base la guarda como 'V26484675',
    // '26484675' o 'V-26484675', y las cifras están dentro de las tres.
    const digitos = soloDigitos(texto)
    return { ...base(texto, 'cedula', digitos), personas: digitos }
  }

  const rif = texto.match(RIF)
  // El cuerpo y el dígito verificador, sin la letra ni los guiones.
  if (rif) return base(texto, 'rif', rif.slice(1, 3).join(''))

  if (SOLO_CIFRAS.test(texto)) {
    const digitos = soloDigitos(texto)
    const conMas = texto.startsWith('+')

    if (pareceTelefono(digitos, conMas)) {
      const nacional = conMas && digitos.startsWith('58') ? digitos.slice(2) : parteNacional(digitos)
      return {
        ...base(texto, 'telefono', digitos),
        personas: nacional.length >= CIFRAS_MINIMAS ? nacional : null,
      }
    }

    const c = base(texto, 'numero', digitos)
    const largo = digitos.length
    const puedeSerOrden =
      !digitos.startsWith('0') &&
      largo <= CIFRAS_DE_UNA_ORDEN &&
      largo > 0 &&
      Number(digitos) >= PRIMERA_ORDEN
    return {
      ...c,
      personas: largo >= CIFRAS_MINIMAS ? digitos : null,
      orden: puedeSerOrden ? Number(digitos) : null,
      referencia:
        largo >= CIFRAS_MINIMAS && largo <= CIFRAS_DE_UNA_REFERENCIA ? digitos : null,
    }
  }

  // Un nombre, una pantalla o una palabra. A personas se le manda tal cual
  // se escribió: la base compara el nombre sin tildes ni mayúsculas.
  const c = base(texto, 'texto')
  return { ...c, personas: c.normal.length >= 2 ? texto : null }
}

/**
 * Qué grupos se buscan para cada forma, y en qué orden salen.
 *
 * El orden va de lo exacto a lo aproximado. Con un número suelto, primero el
 * consumo (la orden se compara por igualdad: si sale, es esa), después los
 * pagos por referencia y al final las personas, que casan por trozos y traen
 * ruido.
 */
const GRUPOS_POR_FORMA: Record<Forma, ReadonlyArray<IdGrupo>> = {
  vacio: ['recientes', 'atajos'],
  texto: ['pantallas', 'acciones', 'personas', 'locales', 'cifras', 'terminos'],
  orden: ['consumos'],
  referencia: ['pagos'],
  telefono: ['personas'],
  cedula: ['personas'],
  rif: ['locales'],
  numero: ['consumos', 'pagos', 'personas', 'locales'],
}

/** Los grupos que tocan para esta consulta, en el orden en que se pintan. */
export function gruposDe(c: Consulta): ReadonlyArray<IdGrupo> {
  return GRUPOS_POR_FORMA[c.forma].filter((grupo) => {
    if (grupo === 'personas') return c.personas !== null
    if (grupo === 'consumos') return c.orden !== null
    if (grupo === 'pagos') return c.referencia !== null
    return true
  })
}

/**
 * Lo que se le pide al servidor para una referencia: sus seis últimas cifras.
 *
 * Quien llama dicta la referencia entera que le da su banco, y lo guardado
 * puede ser solo el final (o al revés). Las seis últimas están en las dos;
 * después `buscarPagos` se queda con las que de verdad encajan.
 */
export function agujaDeReferencia(referencia: string): string {
  return referencia.slice(-6)
}
