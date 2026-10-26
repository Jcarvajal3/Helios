import { whatsappNumber } from '@/components/ui'
import { REDES_SOCIALES } from '@/features/admin/clinicas/clinicas'
import type { RedSocial } from '@/features/admin/clinicas/clinicas'
import { comoFila, comoLista, texto, textoONulo } from '@/lib/json'
import { leerEspecialidad, nombreDeEspecialidad } from './especialidades'
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
}

/** `helios_directorio()`. Una fila sin WhatsApp no tiene botón: no entra. */
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

/** `https://wa.me/584141234567?text=…`. */
export function enlaceDeWhatsApp(m: Pick<MedicoDelDirectorio, 'whatsapp' | 'nombre'>): string {
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

export type EspecialidadPresente = { clave: ClaveDeEspecialidad; nombre: string; cuantos: number }

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
