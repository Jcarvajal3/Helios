// ═══════════════════════════════════════════════════════════════════════════
// Helios — Parser de Amazon, traductor médico ES→EN y filtro aduanal
//
// Módulo puro sin red ni base de datos. Extrae ASINs de enlaces o texto,
// expande vocabulario médico de Venezuela al inglés de Amazon y marca
// artículos que requieren revisión aduanal/sanitaria antes de cobrar.
// ═══════════════════════════════════════════════════════════════════════════

import { normalizar } from '../logica.ts'
import type { RestriccionMedica } from './tipos.ts'

/** Prefijo explícito «asin: B00QES9K4G» o «asin: 1264268505» (ISBN-10). */
const PATRON_ASIN_PREFIJO = /\basin\s*:\s*([A-Z0-9]{10})\b/i

/** ASIN estándar de Amazon de 10 caracteres alfanuméricos que inicia en B0. */
const PATRON_ASIN_B0 = /(?<![A-Z0-9])(B0[A-Z0-9]{8})(?![A-Z0-9])/i

/** Tiendas de Amazon: el host termina en amazon.<tld> (anclado: «evilamazon.com» no vale). */
const HOST_AMAZON = /(^|\.)amazon\.([a-z]{2,3}|co\.[a-z]{2}|com\.[a-z]{2})$/i
/** amzn.com es un acortador con el ASIN en la ruta. */
const HOST_AMZN_COM = /(^|\.)amzn\.com$/i
/** Acortadores que hay que seguir para ver el producto. */
const HOST_CORTO = /^(?:www\.)?(amzn\.to|a\.co|amzn\.eu|amzn\.asia)$/i

const PATRONES_RUTA: ReadonlyArray<RegExp> = [
  /(?:^|\/)dp\/([A-Z0-9]{10})(?=[/?#]|$)/i,
  /\/gp\/(?:product|aw\/d|offer-listing)\/([A-Z0-9]{10})(?=[/?#]|$)/i,
  /\/exec\/obidos\/ASIN\/([A-Z0-9]{10})(?=[/?#]|$)/i,
  /\/(?:product|product-reviews)\/([A-Z0-9]{10})(?=[/?#]|$)/i,
]

/** Un enlace de Amazon (o de un acortador de Amazon) dentro de un texto. */
export type EnlaceAmazon = {
  /** El ASIN si el enlace lo trae; null en un acortador sin resolver. */
  asin: string | null
  /** El host en minúsculas («www.amazon.es»). */
  host: string
  /** true si es un acortador (amzn.to, a.co, amzn.eu, amzn.com sin ASIN). */
  corto: boolean
  /** true si la tienda es amazon.com (o un acortador). */
  esAmazonCom: boolean
  /** El enlace completo, con https. */
  url: string
}

function aUrl(token: string): URL | null {
  const limpio = token.replace(/^[<(\[«"']+|[>)\]»"'.,;!?]+$/g, '')
  if (limpio === '') return null
  const conEsquema = /^https?:\/\//i.test(limpio)
    ? limpio
    : /^(?:www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[/?#]|$)/i.test(limpio)
      ? `https://${limpio}`
      : null
  if (!conEsquema) return null
  try {
    return new URL(conEsquema)
  } catch {
    return null
  }
}

/** Todas las URL de un texto (con o sin «https://»). */
function urlsDe(texto: string): URL[] {
  const salida: URL[] = []
  for (const token of texto.split(/\s+/)) {
    const u = aUrl(token)
    if (u) salida.push(u)
  }
  return salida
}

/** ¿El texto trae algún enlace (de cualquier sitio)? */
export function contieneEnlace(texto: string | null | undefined): boolean {
  return !!texto && urlsDe(texto).length > 0
}

/** El primer enlace de Amazon del texto, o null (solo hosts anclados a Amazon). */
export function analizarEnlaceAmazon(texto: string | null | undefined): EnlaceAmazon | null {
  if (!texto) return null
  for (const u of urlsDe(texto)) {
    const host = u.hostname.toLowerCase()
    let ruta = u.pathname
    try {
      ruta = decodeURIComponent(u.pathname)
    } catch {
      // se queda la ruta tal cual
    }
    if (HOST_CORTO.test(host)) {
      return { asin: null, host, corto: true, esAmazonCom: true, url: u.toString() }
    }
    if (HOST_AMZN_COM.test(host)) {
      const m = /^\/(?:dp\/)?([A-Z0-9]{10})\/?$/i.exec(ruta)
      if (m) return { asin: m[1].toUpperCase(), host, corto: false, esAmazonCom: true, url: u.toString() }
      return { asin: null, host, corto: true, esAmazonCom: true, url: u.toString() }
    }
    if (HOST_AMAZON.test(host)) {
      let asin: string | null = null
      for (const p of PATRONES_RUTA) {
        const m = p.exec(ruta)
        if (m?.[1]) {
          asin = m[1].toUpperCase()
          break
        }
      }
      return { asin, host, corto: false, esAmazonCom: /(^|\.)amazon\.com$/i.test(host), url: u.toString() }
    }
  }
  return null
}

/**
 * Extrae un ASIN de una URL de Amazon (cualquier tienda, hosts anclados), de
 * un prefijo «asin:» (admite ISBN-10) o de un ASIN puro que empiece por «B0».
 * Un enlace de otro sitio no se mira. Devuelve el código en mayúsculas o null.
 */
export function extraerAsinDeTexto(texto: string | null | undefined): string | null {
  if (!texto) return null
  const crudo = texto.trim()
  if (crudo === '') return null

  const enlace = analizarEnlaceAmazon(crudo)
  if (enlace) return enlace.asin

  const prefijo = PATRON_ASIN_PREFIJO.exec(crudo)
  if (prefijo?.[1]) {
    const candidato = prefijo[1].toUpperCase()
    if (/^B0[A-Z0-9]{8}$/.test(candidato) || /^\d{9}[\dX]$/.test(candidato)) {
      return candidato
    }
  }

  // Sin enlaces de otros sitios por en medio.
  const sinEnlaces = crudo
    .split(/\s+/)
    .filter((t) => aUrl(t) === null)
    .join(' ')
  const suelto = PATRON_ASIN_B0.exec(sinEnlaces)
  if (suelto?.[1]) return suelto[1].toUpperCase()

  return null
}

/** Frases médicas compuestas (se sustituyen antes que las palabras sueltas). */
const FRASES_MEDICAS_ES_EN: ReadonlyArray<[string, string]> = [
  ['tensiometro digital', 'digital blood pressure monitor'],
  ['tensiometro de brazo', 'upper arm blood pressure monitor'],
  ['camilla portatil', 'portable medical exam table'],
  ['camilla de examen', 'medical examination table'],
  ['lampara frontal', 'led surgical headlamp'],
  ['lampara quirurgica', 'surgical examination lamp'],
  ['lampara de examen', 'medical examination lamp'],
  ['lampara rodante', 'rolling medical examination lamp'],
  ['linterna pupilar', 'medical penlight'],
  ['lupa binocular', 'dental surgical binocular loupes'],
  ['lupas odontologicas', 'dental surgical loupes'],
  ['lupa odontologica', 'dental surgical loupes'],
  ['bata medica', 'medical lab coat'],
  ['bata blanca', 'medical lab coat'],
  ['uniforme medico', 'medical scrubs'],
  ['uniformes medicos', 'medical scrubs'],
  ['zuecos medicos', 'medical nursing clogs'],
  ['maletin medico', 'doctor medical bag'],
  ['bolso medico', 'doctor medical bag'],
  ['prueba rapida', 'rapid diagnostic test kit'],
  ['pruebas rapidas', 'rapid diagnostic test kit'],
  ['kit reactivos', 'diagnostic reagent kit'],
  ['kit de reactivos', 'diagnostic reagent kit'],
  ['acido hialuronico', 'hyaluronic acid dermal filler'],
  ['toxina botulinica', 'botulinum toxin'],
  ['anestesia dental', 'dental local anesthetic cartridges'],
  ['sutura absorbible', 'absorbable surgical suture'],
  ['suturas absorbibles', 'absorbable surgical suture'],
  ['guantes de nitrilo', 'nitrile exam gloves'],
  ['guantes quirurgicos', 'surgical gloves'],
  ['atlas de anatomia', 'atlas of human anatomy'],
  ['medicina interna', 'internal medicine'],
  ['termometro infrarrojo', 'infrared digital thermometer'],
  ['oximetro de pulso', 'fingertip pulse oximeter'],
  ['autoclave de mesa', 'tabletop steam autoclave sterilizer'],
]

/** Diccionario de términos médicos individuales ES → EN. */
const TERMINOS_MEDICOS_ES_EN: Record<string, string> = {
  estetoscopio: 'stethoscope',
  estetoscopios: 'stethoscope',
  fonendoscopio: 'stethoscope',
  fonendoscopios: 'stethoscope',
  tensiometro: 'blood pressure monitor',
  tensiometros: 'blood pressure monitor',
  esfigmomanometro: 'blood pressure monitor',
  oximetro: 'pulse oximeter',
  oximetros: 'pulse oximeter',
  pulsioximetro: 'pulse oximeter',
  otoscopio: 'otoscope',
  otoscopios: 'otoscope',
  oftalmoscopio: 'ophthalmoscope',
  lampara: 'headlamp penlight',
  lamparas: 'headlamp penlight',
  linterna: 'penlight',
  linternas: 'penlight',
  bata: 'scrubs',
  batas: 'scrubs',
  uniforme: 'scrubs',
  uniformes: 'scrubs',
  pijama: 'scrubs',
  guante: 'gloves',
  guantes: 'gloves',
  nitrilo: 'nitrile',
  autoclave: 'autoclave',
  autoclaves: 'autoclave',
  esterilizador: 'autoclave sterilizer',
  ultrasonido: 'ultrasound',
  ecografo: 'ultrasound',
  glucometro: 'glucometer',
  glucometros: 'glucometer',
  glucosa: 'glucose',
  termometro: 'thermometer',
  termometros: 'thermometer',
  microscopio: 'microscope',
  microscopios: 'microscope',
  sutura: 'suture',
  suturas: 'suture',
  jeringa: 'syringe',
  jeringas: 'syringe',
  inyectadora: 'syringe',
  inyectadoras: 'syringe',
  aguja: 'needle',
  agujas: 'needle',
  camilla: 'exam table',
  camillas: 'exam table',
  centrifuga: 'clinical centrifuge',
  centrifugas: 'clinical centrifuge',
  lupa: 'surgical loupes',
  lupas: 'surgical loupes',
  zueco: 'medical clogs',
  zuecos: 'medical clogs',
  maletin: 'medical bag',
  bolso: 'medical bag',
  libro: 'medical textbook',
  libros: 'medical textbook',
  anatomia: 'anatomy',
  reactivo: 'reagent',
  reactivos: 'reagent',
  anestesia: 'anesthetic',
  cartucho: 'cartridges',
  cartuchos: 'cartridges',
  dental: 'dental',
  odontologia: 'dental',
  odontologico: 'dental',
  odontologica: 'dental',
  quirurgico: 'surgical',
  quirurgica: 'surgical',
  cirugia: 'surgical',
  cardiologia: 'cardiology',
  pediatrico: 'pediatric',
  pediatrica: 'pediatric',
  portatil: 'portable',
  infrarrojo: 'infrared',
  oido: 'ear',
  brazo: 'arm',
  bisturi: 'scalpel',
  nebulizador: 'nebulizer',
  laboratorio: 'lab',
  clinica: 'clinic',
  clinico: 'clinical',
  medico: 'medical',
  medica: 'medical',
  esteril: 'sterile',
  esteriles: 'sterile',
  absorbible: 'absorbable',
  absorbibles: 'absorbable',
}

const PALABRAS_VACIAS = new Set([
  'de',
  'del',
  'la',
  'el',
  'los',
  'las',
  'un',
  'una',
  'unos',
  'unas',
  'para',
  'con',
  'en',
  'por',
  'y',
  'o',
  'a',
  'al',
  'que',
  'quiero',
  'busco',
  'buscar',
  'comprar',
  'necesito',
  'cotizar',
  'the',
  'of',
  'for',
  'with',
  'and',
  'in',
  'to',
])

/**
 * Normaliza una búsqueda médica en español y genera una consulta optimizada
 * en inglés para Amazon junto con sus tokens de relevancia (ES + EN).
 */
export function normalizarBusquedaMedica(query: string): {
  original: string
  consultaEn: string
  tokens: string[]
} {
  const original = query.trim()
  const norm = normalizar(original)
  if (norm === '') {
    return { original: '', consultaEn: '', tokens: [] }
  }

  let trabajo = ` ${norm} `
  for (const [es, en] of FRASES_MEDICAS_ES_EN) {
    const patron = new RegExp(` ${es.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} `, 'g')
    trabajo = trabajo.replace(patron, ` ${en} `)
  }

  const palabrasTraducidas: string[] = []
  for (const palabra of trabajo.trim().split(/\s+/)) {
    if (!palabra || PALABRAS_VACIAS.has(palabra)) continue
    const trad = TERMINOS_MEDICOS_ES_EN[palabra]
    if (trad) {
      for (const p of trad.split(/\s+/)) {
        if (p && !palabrasTraducidas.includes(p)) palabrasTraducidas.push(p)
      }
    } else if (!palabrasTraducidas.includes(palabra)) {
      palabrasTraducidas.push(palabra)
    }
  }

  const consultaEn = palabrasTraducidas.join(' ').trim() || norm

  const tokensSet = new Set<string>()
  for (const t of norm.split(/\s+/)) {
    if (t.length >= 2 && !PALABRAS_VACIAS.has(t)) tokensSet.add(t)
  }
  for (const t of consultaEn.split(/\s+/)) {
    if (t.length >= 2 && !PALABRAS_VACIAS.has(t)) tokensSet.add(t)
  }

  return {
    original,
    consultaEn,
    tokens: Array.from(tokensSet),
  }
}

const REGLAS_RESTRICCION: ReadonlyArray<{ patron: RegExp; motivo: string }> = [
  {
    patron:
      /\b(toxina botulinica|botulinum|botox|acido hialuronico|hyaluronic acid.*(filler|inject|dermal|syringe)|dermal filler|relleno dermico|relleno facial|biopolimero|mesoterapia|inyectable|injectable)\b/i,
    motivo: 'Inyectable o relleno estético: requiere revisión aduanal y sanitaria antes de pagar.',
  },
  {
    patron:
      /\b(anestesia|anestesico|anesthetic|lidocaina|lidocaine|articaina|articaine|mepivacaina|medicamento|medicamentos|medication|pharmaceutical|farmaco|antibiotico|antibiotic|vacuna|vaccine|ampolla|ampoule|prescription drug)\b/i,
    motivo: 'Medicamento o anestésico: requiere validación aduanal y sanitaria antes de pagar.',
  },
  {
    patron:
      /\b(jeringa|jeringas|syringe|syringes|aguja|agujas|needle|needles|sutura|suturas|suture|sutures|vicryl|cateter|catheter|canula|cannula|bisturi|scalpel|implante|implant|trocar)\b/i,
    motivo: 'Insumo médico invasivo o estéril: requiere revisión aduanal y sanitaria antes de pagar.',
  },
  {
    patron:
      /\b(reactivo|reactivos|reagent|reagents|prueba rapida|pruebas rapidas|rapid diagnostic test|rapid test kit|in vitro|ivd|quimico industrial|chemical reagent|solucion reactiva)\b/i,
    motivo: 'Reactivo químico o kit diagnóstico: requiere validación aduanal y sanitaria antes de pagar.',
  },
  {
    patron:
      /\b(bateria de litio industrial|lithium.*(industrial|high capacity|battery pack|100wh|200wh)|li-ion.*industrial|desfibrilador|defibrillator|equipo invasivo|endoscopio quirurgico)\b/i,
    motivo: 'Equipo con batería de litio de alta capacidad o uso invasivo: requiere revisión aduanal antes de pagar.',
  },
]

/**
 * Evalúa si un producto de Amazon requiere validación aduanal o sanitaria
 * antes de habilitar el pago (medicamentos, reactivos, inyectables/jeringas,
 * toxina/rellenos, suturas/invasivos o baterías de litio industriales).
 */
export function evaluarRestriccionMedica(titulo: string, categoria?: string | null): RestriccionMedica {
  const texto = normalizar(`${titulo} ${categoria ?? ''}`)
  for (const regla of REGLAS_RESTRICCION) {
    if (regla.patron.test(texto)) {
      return { restringido: true, motivo: regla.motivo }
    }
  }
  return { restringido: false, motivo: null }
}
