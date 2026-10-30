import { whatsappNumber } from '@/components/ui'
import { REDES_SOCIALES } from '@/features/admin/clinicas/clinicas'
import type { RedSocial } from '@/features/admin/clinicas/clinicas'
import { comoFila, comoLista, texto, textoONulo } from '@/lib/json'
import { ESPECIALIDADES, leerEspecialidad, nombreDeEspecialidad } from './especialidades'
import type { ClaveDeEspecialidad } from './especialidades'

// ═══════════════════════════════════════════════════════════════════════════
// El directorio de médicos — `/directorio`.
//
// Módulo puro: lo usan la página, la vista previa de la tarjeta en el
// superadmin y las pruebas. Los datos salen de `helios_directorio()`
// (docs/01 §2.11): solo las clínicas que el equipo publicó y que se pueden
// publicar.
// ═══════════════════════════════════════════════════════════════════════════

export type MedicoDelDirectorio = {
  /** El id de la clínica: con él se apunta el clic de contacto. */
  id: string
  /** «Dra. Nadia Khabbaze Alfaro». */
  nombre: string
  /** El texto de la tarjeta («Traumatología, cirugía de cadera y rodilla»). */
  especialidad: string | null
  /** La del filtro y el icono. */
  clave: ClaveDeEspecialidad
  direccion: string | null
  ciudad: string | null
  /** E.164: '+584141234567'. */
  whatsapp: string
  /** Su red social, si la tiene: la red y el usuario o enlace, tal cual. */
  red: RedSocial | null
  usuarioDeRed: string | null
  /**
   * El código de su tarjeta («DIR-7K2P»): va en el mensaje al WhatsApp de
   * Helios para que el bot sepa de qué médico se trata. `null` en datos viejos.
   */
  codigo: string | null
  /**
   * El enlace de su ficha (`/medico/<slug>`): nace al publicarse y no cambia.
   * `null` solo en datos de antes del 2026-10-30.
   */
  slug: string | null
  /** El último cambio de su tarjeta (ISO): el `lastmod` del sitemap. */
  actualizado: string | null
}

/** `helios_directorio()` y `helios_directorio_medico()`. Una fila sin WhatsApp no tiene botón: no entra. */
export function leerDirectorio(raw: unknown): MedicoDelDirectorio[] {
  return comoLista(raw)
    .map((fila) => {
      const r = comoFila(fila)
      return {
        id: texto(r.merchant_id),
        nombre: texto(r.name),
        especialidad: textoONulo(r.specialty),
        clave: leerEspecialidad(r.specialty_key),
        direccion: textoONulo(r.address),
        ciudad: textoONulo(r.city),
        whatsapp: texto(r.whatsapp),
        red: leerRed(r.social_network),
        usuarioDeRed: textoONulo(r.social_user),
        codigo: textoONulo(r.lead_code),
        slug: textoONulo(r.slug),
        actualizado: textoONulo(r.updated_at),
      }
    })
    .filter((m) => m.id !== '' && m.nombre !== '' && m.whatsapp !== '')
}

// ── Lo que se lee en la tarjeta ────────────────────────────────────────────

/**
 * La línea de la especialidad. Sin texto propio, el nombre de su
 * especialidad; con «Otras especialidades» y sin texto, nada (no dice nada).
 */
export function especialidadDeTarjeta(m: Pick<MedicoDelDirectorio, 'especialidad' | 'clave'>): string | null {
  if (m.especialidad) return m.especialidad
  return m.clave === 'otra' ? null : nombreDeEspecialidad(m.clave)
}

/** «Av. Lara, Torre Médica, piso 3 · Barquisimeto», sin repetir la ciudad. */
export function lugarDeTarjeta(m: Pick<MedicoDelDirectorio, 'direccion' | 'ciudad'>): string | null {
  const { direccion, ciudad } = m
  if (direccion && ciudad && normalizar(direccion).includes(normalizar(ciudad))) return direccion
  return [direccion, ciudad].filter(Boolean).join(' · ') || null
}

// ── La red social ──────────────────────────────────────────────────────────

/** La red tal cual llega de la base; una que el panel no conoce, ninguna. */
export function leerRed(v: unknown): RedSocial | null {
  return REDES_SOCIALES.find((r) => r.value === v)?.value ?? null
}

/** Cómo se llega al perfil a partir del usuario, en cada red. */
const PERFIL: Record<Exclude<RedSocial, 'otra'>, (usuario: string) => string> = {
  instagram: (u) => `https://www.instagram.com/${u}`,
  tiktok: (u) => `https://www.tiktok.com/@${u}`,
  facebook: (u) => `https://www.facebook.com/${u}`,
  x: (u) => `https://x.com/${u}`,
  linkedin: (u) => `https://www.linkedin.com/in/${u}`,
  youtube: (u) => `https://www.youtube.com/@${u}`,
}

export type EnlaceDeRed = {
  /** Siempre https: un `javascript:` escrito en el alta nunca llega a un href. */
  url: string
  /** Lo que se lee: «@draperez». */
  texto: string
  /** «Instagram». */
  red: string
}

/**
 * El enlace a la red social del médico, o `null` si no tiene o no se puede
 * armar. El médico escribe lo que quiere: «@draperez», «draperez» o el enlace
 * entero («instagram.com/draperez»). Con «Otra», solo vale un enlace.
 */
export function enlaceDeRed(m: Pick<MedicoDelDirectorio, 'red' | 'usuarioDeRed'>): EnlaceDeRed | null {
  const { red } = m
  const escrito = m.usuarioDeRed?.trim() ?? ''
  if (!red || !escrito) return null
  const nombreDeRed = red === 'otra' ? 'Red social' : (REDES_SOCIALES.find((r) => r.value === red)?.label ?? red)
  const corto = nombreDeRed.replace(/\s*\(.*\)$/, '')

  // Un enlace: se usa tal cual, con https delante si no lo trae.
  const comoEnlace = escrito.replace(/^https?:\/\//i, '')
  if (/^[\w-]+(\.[\w-]+)+\/\S*$/.test(comoEnlace) && !/\s/.test(comoEnlace)) {
    let url: URL
    try {
      url = new URL(`https://${comoEnlace}`)
    } catch {
      return null
    }
    const ruta = url.pathname.replace(/\/+$/, '').split('/').filter(Boolean).at(-1)
    const leido = ruta ? `@${ruta.replace(/^@/, '')}` : url.hostname.replace(/^www\./, '')
    return { url: url.toString(), texto: leido, red: corto }
  }

  // Un usuario: letras, números, puntos, guiones y guiones bajos.
  const usuario = escrito.replace(/^@/, '')
  if (red === 'otra' || !/^[\w.-]{1,100}$/.test(usuario)) return null
  return { url: PERFIL[red](usuario), texto: `@${usuario}`, red: corto }
}

// ── El botón de WhatsApp ───────────────────────────────────────────────────

/**
 * Lo que el paciente encuentra escrito al abrir el chat. Le dice al médico
 * de dónde viene el paciente, que es lo que el médico quiere saber.
 */
export function mensajeInicial(nombre: string): string {
  return `Hola, ${nombre.trim()}. Vi su perfil en el directorio de Helios y quisiera agendar una consulta.`
}

/**
 * Si el botón de la tarjeta pasa por el WhatsApp de Helios (para apuntar a
 * cada interesado, docs/04) o va directo al del médico.
 *
 * Apagado desde el 2026-10-28 por decisión de los founders: el botón vuelve a
 * ir directo al médico y no se apuntan interesados. Todo lo demás se queda
 * como está (los códigos de las tarjetas, la ruta del bot, el embudo del
 * superadmin) para poder volver a encenderlo con solo poner esto en `true`.
 */
export const INTERESADOS_POR_HELIOS = false as boolean

/**
 * Lo que el paciente encuentra escrito al abrir el chat con Helios: el
 * código es lo que el bot busca para saber de qué médico se trata.
 */
export function mensajeAHelios(nombre: string, codigo: string): string {
  return `Hola, quiero agendar una consulta con ${nombre.trim()}. (Código ${codigo.trim()})`
}

/**
 * El botón de la tarjeta. Con el número de Helios y el código de la tarjeta,
 * el chat de Helios (`https://wa.me/58422…?text=…(Código DIR-7K2P)`): el bot
 * apunta al interesado y le pasa el WhatsApp del médico. Si falta cualquiera
 * de los dos, el chat directo con el médico, con `mensajeInicial`: el botón
 * nunca se queda sin funcionar.
 */
export function enlaceDeWhatsApp(
  m: Pick<MedicoDelDirectorio, 'whatsapp' | 'nombre' | 'codigo'>,
  whatsappHelios?: string | null,
): string {
  const helios = whatsappNumber(whatsappHelios ?? null)
  const codigo = m.codigo?.trim()
  if (helios && codigo) {
    return `https://wa.me/${helios}?text=${encodeURIComponent(mensajeAHelios(m.nombre, codigo))}`
  }
  return `https://wa.me/${whatsappNumber(m.whatsapp)}?text=${encodeURIComponent(mensajeInicial(m.nombre))}`
}

// ── Buscar y filtrar ───────────────────────────────────────────────────────

/** Sin tildes, sin mayúsculas y con los espacios colapsados. */
export function normalizar(t: string): string {
  return t
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim()
}

function textoDeBusqueda(m: MedicoDelDirectorio): string {
  return normalizar(
    [m.nombre, m.especialidad, nombreDeEspecialidad(m.clave), m.direccion, m.ciudad, m.usuarioDeRed].filter(Boolean).join(' '),
  )
}

/**
 * Cada palabra de la búsqueda tiene que estar en algún sitio de la tarjeta
 * (nombre, especialidad, dirección o ciudad), en cualquier orden: «odonto
 * barquisimeto» encuentra a la odontóloga de Barquisimeto.
 */
export function filtrarDirectorio(
  medicos: readonly MedicoDelDirectorio[],
  { q, especialidad }: { q?: string; especialidad?: ClaveDeEspecialidad },
): MedicoDelDirectorio[] {
  const palabras = normalizar(q ?? '')
    .split(' ')
    .filter(Boolean)
  return medicos.filter((m) => {
    if (especialidad && m.clave !== especialidad) return false
    if (palabras.length === 0) return true
    const t = textoDeBusqueda(m)
    return palabras.every((p) => t.includes(p))
  })
}

export type Especialidad = (typeof ESPECIALIDADES)[number]

/**
 * Las especialidades del desplegable de `/afiliacion` que casan con lo
 * escrito: cada palabra tiene que estar en su nombre o en una de sus otras
 * formas (`busca`: «dentista», «ojos»), sin tildes ni mayúsculas. Primero
 * las que empiezan por lo escrito, luego las que tienen una palabra que
 * empieza así y luego el resto. «Otras especialidades» sale siempre, al
 * final: es la salida cuando la suya no está.
 */
export function buscarEspecialidades(q: string): Especialidad[] {
  const escrito = normalizar(q)
  const palabras = escrito.split(' ').filter(Boolean)
  const otra = ESPECIALIDADES.filter((e) => e.clave === 'otra')
  const resto = ESPECIALIDADES.filter((e) => e.clave !== 'otra')
  if (palabras.length === 0) return [...resto, ...otra]
  const puesto = (e: Especialidad): number => {
    const nombre = normalizar(e.nombre)
    if (nombre.startsWith(escrito)) return 0
    if (nombre.split(' ').some((p) => p.startsWith(palabras[0]))) return 1
    return 2
  }
  const casan = resto
    .filter((e) => {
      const t = normalizar([e.nombre, ...e.busca].join(' '))
      return palabras.every((p) => t.includes(p))
    })
    .map((e, i) => ({ e, i, p: puesto(e) }))
    .sort((a, b) => a.p - b.p || a.i - b.i)
    .map((x) => x.e)
  return [...casan, ...otra]
}

export type EspecialidadPresente ={ clave: ClaveDeEspecialidad; nombre: string; cuantos: number }

/**
 * Las especialidades que tienen algún médico, la de más médicos primero y
 * «Otras» siempre al final: un filtro que no devuelve a nadie no se ofrece.
 */
export function especialidadesPresentes(medicos: readonly MedicoDelDirectorio[]): EspecialidadPresente[] {
  const cuenta = new Map<ClaveDeEspecialidad, number>()
  for (const m of medicos) cuenta.set(m.clave, (cuenta.get(m.clave) ?? 0) + 1)
  return [...cuenta.entries()]
    .map(([clave, cuantos]) => ({ clave, nombre: nombreDeEspecialidad(clave), cuantos }))
    .sort((a, b) => {
      if (a.clave === 'otra') return 1
      if (b.clave === 'otra') return -1
      return b.cuantos - a.cuantos || a.nombre.localeCompare(b.nombre, 'es')
    })
}

/** Cuántas filas ocupan unas fichas de estos anchos, envueltas como `flex-wrap`. */
function filasQueOcupan(anchos: readonly number[], ancho: number, hueco: number): number {
  let filas = 1
  let x = 0
  for (const w of anchos) {
    if (x > 0 && x + hueco + w > ancho + 0.5) {
      filas++
      x = w
    } else {
      x += (x > 0 ? hueco : 0) + w
    }
  }
  return filas
}

/**
 * Cuántas fichas de especialidad se enseñan con la lista cerrada: todas si
 * caben en `filas`; si no, las que quepan dejando sitio en la última fila al
 * botón «Ver más» (de ancho `verMas`). Siempre al menos la primera («Todas»).
 */
export function fichasQueCaben(
  anchos: readonly number[],
  { ancho, hueco, filas, verMas }: { ancho: number; hueco: number; filas: number; verMas: number },
): number {
  if (filasQueOcupan(anchos, ancho, hueco) <= filas) return anchos.length
  for (let n = anchos.length - 1; n > 1; n--) {
    if (filasQueOcupan([...anchos.slice(0, n), verMas], ancho, hueco) <= filas) return n
  }
  return 1
}

// ── Lo que leen los buscadores ─────────────────────────────────────────────

/**
 * Las especialidades del directorio en el vocabulario de schema.org
 * (`MedicalSpecialty`). Las que no tienen equivalente claro no llevan
 * ninguna: basta su nombre en la descripción.
 */
const ESPECIALIDAD_EN_SCHEMA: Partial<Record<ClaveDeEspecialidad, string>> = {
  anatomia_patologica: 'Pathology',
  angiologia: 'Cardiovascular',
  cardiologia: 'Cardiovascular',
  cirugia_cardiaca: 'Surgical',
  cirugia_craneofacial: 'Surgical',
  cirugia_general: 'Surgical',
  cirugia_oncologica: 'Surgical',
  cirugia_maxilofacial: 'Surgical',
  cirugia_pediatrica: 'Surgical',
  cirugia_plastica: 'PlasticSurgery',
  cirugia_toracica: 'Surgical',
  dermatologia: 'Dermatology',
  endocrinologia: 'Endocrine',
  enfermeria: 'Nursing',
  fisioterapia: 'Physiotherapy',
  gastroenterologia: 'Gastroenterologic',
  ginecologia: 'Gynecologic',
  hematologia: 'Hematologic',
  hepatologia: 'Gastroenterologic',
  medicina_general: 'PrimaryCare',
  nefrologia: 'Renal',
  neumologia: 'Pulmonary',
  neurocirugia: 'Surgical',
  neurologia: 'Neurologic',
  nutricion: 'DietNutrition',
  odontologia: 'Dentistry',
  oncologia: 'Oncologic',
  ortodoncia: 'Dentistry',
  otorrinolaringologia: 'Otolaryngologic',
  pediatria: 'Pediatric',
  // La psicología no tiene equivalente: `Psychiatric` es la psiquiatría.
  psiquiatria: 'Psychiatric',
  radiologia: 'Radiography',
  reumatologia: 'Rheumatologic',
  traumatologia: 'Musculoskeletal',
  urologia: 'Urologic',
}

/**
 * Los médicos del directorio como `ItemList` de `Physician`, para el
 * JSON-LD de `/directorio`: lo mismo que se lee en las tarjetas (nombre,
 * especialidad, dirección y red social), nunca su WhatsApp, que pasa por el
 * botón de la tarjeta. `url` es la de la página; `urlDeFicha`, la de la
 * ficha de cada médico (`/medico/<slug>`), si la tiene.
 */
export function directorioEnSchema(
  medicos: readonly MedicoDelDirectorio[],
  url: string,
  urlDeFicha?: (slug: string) => string,
) {
  return {
    '@type': 'ItemList',
    '@id': `${url}#medicos`,
    name: 'Médicos que aceptan pago en cuotas con Helios',
    numberOfItems: medicos.length,
    itemListElement: medicos.map((m, i) => ({
      '@type': 'ListItem',
      position: i + 1,
      item: medicoEnSchema(m, m.slug && urlDeFicha ? urlDeFicha(m.slug) : undefined),
    })),
  }
}

/**
 * Un médico como `Physician`: el del directorio y el de su ficha. Con
 * `urlDeFicha`, lleva su `@id` y su `url`, así que el de la lista y el de
 * la ficha son el mismo para Google.
 */
export function medicoEnSchema(m: MedicoDelDirectorio, urlDeFicha?: string) {
  const especialidad = especialidadDeTarjeta(m)
  const schema = ESPECIALIDAD_EN_SCHEMA[m.clave]
  const red = enlaceDeRed(m)
  return {
    '@type': 'Physician',
    ...(urlDeFicha ? { '@id': `${urlDeFicha}#medico`, url: urlDeFicha } : {}),
    name: m.nombre,
    ...(especialidad ? { description: especialidad } : {}),
    ...(schema ? { medicalSpecialty: `https://schema.org/${schema}` } : {}),
    ...(m.direccion || m.ciudad
      ? {
          address: {
            '@type': 'PostalAddress',
            ...(m.direccion ? { streetAddress: m.direccion } : {}),
            ...(m.ciudad ? { addressLocality: m.ciudad } : {}),
            addressCountry: 'VE',
          },
        }
      : {}),
    paymentAccepted: 'Pago en cuotas con Helios, en bolívares por Pago Móvil o transferencia',
    ...(red ? { sameAs: [red.url] } : {}),
  }
}

// ── El visitante ───────────────────────────────────────────────────────────

const CLAVE_VISITANTE = 'helios.directorio.visitante'

/**
 * Un identificador aleatorio de este navegador, para contar visitantes
 * distintos. No dice quién es nadie. Sin almacenamiento (modo privado, datos
 * bloqueados), `undefined`: el clic cuenta igual.
 */
export function visitante(): string | undefined {
  try {
    const guardado = window.localStorage.getItem(CLAVE_VISITANTE)
    if (guardado && /^[A-Za-z0-9-]{8,64}$/.test(guardado)) return guardado
    const nuevo = crypto.randomUUID()
    window.localStorage.setItem(CLAVE_VISITANTE, nuevo)
    return nuevo
  } catch {
    return undefined
  }
}
