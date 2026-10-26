import { formatPhone } from '@/components/ui'
import type { RedSocial } from '@/features/admin/clinicas/clinicas'
import type { MedicoDelDirectorio } from '@/features/directorio/directorio'
import { leerRed, normalizar } from '@/features/directorio/directorio'
import { leerEspecialidad, nombreDeEspecialidad } from '@/features/directorio/especialidades'
import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'
import { unoDe } from '@/lib/busqueda'
import { booleano, comoFila, comoLista, numero, numeros, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Superadmin › Directorio de médicos: quién sale en `/directorio`, con qué
// datos y cuántos contactos recibe cada uno.
//
// Módulo puro: lo usan la pantalla, la ficha y las pruebas. Los datos salen
// de `admin_directorio()` y se guardan con `admin_directorio_guardar()`
// (docs/01 §2.11, migración 20261026190000).
// ═══════════════════════════════════════════════════════════════════════════

/** Los datos de una tarjeta: los que se enseñan o los de la ficha de la clínica. */
export type DatosDeTarjeta = {
  nombre: string
  especialidad: string | null
  clave: ClaveDeEspecialidad
  direccion: string | null
  ciudad: string | null
  /** E.164, o `null` si no hay. */
  whatsapp: string | null
  red: RedSocial | null
  usuarioDeRed: string | null
}

/** Por qué una clínica no se puede publicar. */
export type Bloqueo = 'terminada' | 'pausada' | 'prueba' | 'sin_whatsapp'

export const ROTULO_BLOQUEO: Record<Bloqueo, string> = {
  terminada: 'Clínica terminada',
  pausada: 'Clínica pausada',
  prueba: 'Clínica de prueba',
  sin_whatsapp: 'Sin WhatsApp',
}

export type ClicsDelMedico = {
  total: number
  d7: number
  d30: number
  visitantes30d: number
  ultimo: string | null
  /** Treinta valores, el más viejo primero; el último es hoy. */
  porDia: number[]
}

export type MedicoEnElDirectorio = {
  id: string
  clinica: string
  estado: 'active' | 'paused' | 'terminated'
  esPrueba: boolean
  visible: boolean
  bloqueo: Bloqueo | null
  publicadoEl: string | null
  /** Lo que enseña la tarjeta (lo propio del directorio o, si no, lo de la ficha). */
  tarjeta: DatosDeTarjeta
  /** Lo de la ficha de la clínica: lo que vuelve si se borra un dato. */
  ficha: DatosDeTarjeta
  clics: ClicsDelMedico
}

export type DiaDelDirectorio = { dia: string; clics: number; visitantes: number }

export type TotalesDelDirectorio = {
  clicsTotal: number
  clics7d: number
  clics30d: number
  clics30dAnteriores: number
  visitantes30d: number
  medicosContactados30d: number
}

export type TableroDelDirectorio = {
  hoy: string
  desde: string
  totales: TotalesDelDirectorio
  porDia: DiaDelDirectorio[]
  medicos: MedicoEnElDirectorio[]
}

const ESTADOS = ['active', 'paused', 'terminated'] as const
const BLOQUEOS = ['terminada', 'pausada', 'prueba', 'sin_whatsapp'] as const

function leerDatos(raw: unknown): DatosDeTarjeta {
  const r = comoFila(raw)
  return {
    nombre: texto(r.name),
    especialidad: textoONulo(r.specialty),
    clave: leerEspecialidad(r.specialty_key),
    direccion: textoONulo(r.address),
    ciudad: textoONulo(r.city),
    whatsapp: textoONulo(r.whatsapp),
    red: leerRed(r.social_network),
    usuarioDeRed: textoONulo(r.social_user),
  }
}

/** `admin_directorio()`. */
export function leerTablero(raw: unknown): TableroDelDirectorio {
  const r = comoFila(raw)
  const t = comoFila(r.totales)
  return {
    hoy: texto(r.hoy),
    desde: texto(r.desde),
    totales: {
      clicsTotal: numero(t.clics_total),
      clics7d: numero(t.clics_7d),
      clics30d: numero(t.clics_30d),
      clics30dAnteriores: numero(t.clics_30d_anteriores),
      visitantes30d: numero(t.visitantes_30d),
      medicosContactados30d: numero(t.medicos_contactados_30d),
    },
    porDia: comoLista(r.por_dia).map((d) => {
      const f = comoFila(d)
      return { dia: texto(f.dia), clics: numero(f.clics), visitantes: numero(f.visitantes) }
    }),
    medicos: comoLista(r.medicos).map((fila) => {
      const m = comoFila(fila)
      const c = comoFila(m.clics)
      return {
        id: texto(m.merchant_id),
        clinica: texto(m.clinic_name),
        estado: unoDe(ESTADOS, m.status) ?? 'active',
        esPrueba: booleano(m.is_test),
        visible: booleano(m.is_visible),
        bloqueo: unoDe(BLOQUEOS, m.blocked_reason) ?? null,
        publicadoEl: textoONulo(m.published_at),
        tarjeta: leerDatos(m.listing),
        ficha: leerDatos(m.base),
        clics: {
          total: numero(c.total),
          d7: numero(c.d7),
          d30: numero(c.d30),
          visitantes30d: numero(c.visitantes_30d),
          ultimo: textoONulo(c.ultimo),
          porDia: numeros(c.por_dia),
        },
      }
    }),
  }
}

/** La tarjeta tal cual la verá el paciente (sin WhatsApp no tiene botón). */
export function comoTarjetaPublica(id: string, d: DatosDeTarjeta): MedicoDelDirectorio {
  return {
    id,
    nombre: d.nombre.trim() || 'Sin nombre',
    especialidad: d.especialidad?.trim() || null,
    clave: d.clave,
    direccion: d.direccion?.trim() || null,
    ciudad: d.ciudad?.trim() || null,
    whatsapp: d.whatsapp ?? '',
    red: d.red,
    usuarioDeRed: d.usuarioDeRed?.trim() || null,
  }
}

// ── Filtrar la lista ───────────────────────────────────────────────────────

export const VALORES_QUE_SE_VE = ['todos', 'visibles', 'ocultos'] as const
export type QueSeVe = (typeof VALORES_QUE_SE_VE)[number]

/**
 * Las clínicas de prueba solo salen buscándolas o en «Todos»: en el día a
 * día son ruido.
 */
export function filtrarMedicos(
  medicos: readonly MedicoEnElDirectorio[],
  { q, ver }: { q?: string; ver: QueSeVe },
): MedicoEnElDirectorio[] {
  const palabras = normalizar(q ?? '')
    .split(' ')
    .filter(Boolean)
  return medicos.filter((m) => {
    if (ver === 'visibles' && !m.visible) return false
    if (ver === 'ocultos' && m.visible) return false
    if (palabras.length === 0) return ver === 'todos' || !m.esPrueba
    const t = normalizar(
      [
        m.tarjeta.nombre,
        m.clinica,
        m.tarjeta.especialidad,
        nombreDeEspecialidad(m.tarjeta.clave),
        m.tarjeta.direccion,
        m.tarjeta.ciudad,
        m.tarjeta.whatsapp,
        m.tarjeta.whatsapp ? formatPhone(m.tarjeta.whatsapp) : null,
        m.tarjeta.usuarioDeRed,
      ]
        .filter(Boolean)
        .join(' '),
    )
    return palabras.every((p) => t.includes(p))
  })
}

// ── Editar una tarjeta ─────────────────────────────────────────────────────

/** Lo que se teclea en la ficha: todo texto, el WhatsApp como lo marca la gente. */
export type BorradorDeTarjeta = {
  nombre: string
  especialidad: string
  clave: ClaveDeEspecialidad
  direccion: string
  ciudad: string
  whatsapp: string
  /** `''` con el usuario vacío: vuelve la red de la ficha. */
  red: RedSocial | ''
  usuarioDeRed: string
}

export function borradorDe(d: DatosDeTarjeta): BorradorDeTarjeta {
  return {
    nombre: d.nombre,
    especialidad: d.especialidad ?? '',
    clave: d.clave,
    direccion: d.direccion ?? '',
    ciudad: d.ciudad ?? '',
    whatsapp: d.whatsapp ? formatPhone(d.whatsapp) : '',
    red: d.red ?? '',
    usuarioDeRed: d.usuarioDeRed ?? '',
  }
}

/**
 * El WhatsApp tecleado en E.164, o `null` si no es un número venezolano de
 * diez cifras. Es la misma regla que `helios_normalize_ve_phone`.
 */
export function whatsappE164(tecleado: string): string | null {
  let d = tecleado.replace(/\D/g, '')
  if (/^58\d{10}$/.test(d)) d = d.slice(2)
  else if (/^0\d{10}$/.test(d)) d = d.slice(1)
  return /^\d{10}$/.test(d) ? `+58${d}` : null
}

/** Lo que verá el paciente con el borrador puesto. */
export function datosDelBorrador(b: BorradorDeTarjeta, ficha: DatosDeTarjeta): DatosDeTarjeta {
  const limpio = (t: string) => t.trim().replace(/\s+/g, ' ')
  return {
    nombre: limpio(b.nombre) || ficha.nombre,
    especialidad: limpio(b.especialidad) || ficha.especialidad,
    clave: b.clave,
    direccion: limpio(b.direccion) || ficha.direccion,
    ciudad: limpio(b.ciudad) || ficha.ciudad,
    whatsapp: b.whatsapp.trim() ? whatsappE164(b.whatsapp) : ficha.whatsapp,
    red: b.red || ficha.red,
    usuarioDeRed: limpio(b.usuarioDeRed) || ficha.usuarioDeRed,
  }
}

/** Por qué no se puede guardar el borrador, o `null`. */
export function motivoParaNoGuardar(b: BorradorDeTarjeta): string | null {
  const nombre = b.nombre.trim()
  if (nombre && (nombre.length < 3 || nombre.length > 120)) return 'El nombre debe tener entre 3 y 120 caracteres.'
  if (b.especialidad.trim().length > 120) return 'La especialidad no puede pasar de 120 caracteres.'
  if (b.direccion.trim().length > 300) return 'La dirección no puede pasar de 300 caracteres.'
  if (b.ciudad.trim().length > 80) return 'La ciudad no puede pasar de 80 caracteres.'
  if (b.whatsapp.trim() && !whatsappE164(b.whatsapp)) return 'El WhatsApp debe ser un número venezolano, como 0414-1234567.'
  if (b.usuarioDeRed.trim().length > 150) return 'El usuario de la red social no puede pasar de 150 caracteres.'
  if (b.usuarioDeRed.trim() && !b.red) return 'Elige qué red social es.'
  return null
}

/**
 * Lo que cambió respecto a lo que se enseña hoy, en la forma que espera
 * `admin_directorio_guardar`. Un campo vacío va vacío: la base lo entiende
 * como «el de la ficha». Sin cambios, `null`.
 */
export function cambiosDelBorrador(
  b: BorradorDeTarjeta,
  actual: DatosDeTarjeta,
): Record<string, string> | null {
  const cambios: Record<string, string> = {}
  const limpio = (t: string) => t.trim().replace(/\s+/g, ' ')
  if (limpio(b.nombre) !== actual.nombre) cambios.name = limpio(b.nombre)
  if (limpio(b.especialidad) !== (actual.especialidad ?? '')) cambios.specialty = limpio(b.especialidad)
  if (b.clave !== actual.clave) cambios.specialty_key = b.clave
  if (limpio(b.direccion) !== (actual.direccion ?? '')) cambios.address = limpio(b.direccion)
  if (limpio(b.ciudad) !== (actual.ciudad ?? '')) cambios.city = limpio(b.ciudad)
  const wa = b.whatsapp.trim() ? (whatsappE164(b.whatsapp) ?? b.whatsapp.trim()) : ''
  if (wa !== (actual.whatsapp ?? '')) cambios.whatsapp = wa
  if (b.red !== (actual.red ?? '')) cambios.social_network = b.red
  if (limpio(b.usuarioDeRed) !== (actual.usuarioDeRed ?? '')) cambios.social_user = limpio(b.usuarioDeRed)
  return Object.keys(cambios).length > 0 ? cambios : null
}

/** Qué datos de la tarjeta no son los de la ficha: se marcan en la ficha. */
export function datosPropios(m: Pick<MedicoEnElDirectorio, 'tarjeta' | 'ficha'>): Array<keyof DatosDeTarjeta> {
  return (Object.keys(m.tarjeta) as Array<keyof DatosDeTarjeta>).filter((k) => m.tarjeta[k] !== m.ficha[k])
}

// ── Las cifras ─────────────────────────────────────────────────────────────

/** «12 % más», «3 menos»… frente a los 30 días anteriores, o `null` sin base. */
export function cambioFrenteAlAnterior(actual: number, anterior: number): { label: string; direction: 'up' | 'down' | 'flat' } | null {
  if (anterior === 0) return null
  const pct = Math.round(((actual - anterior) / anterior) * 100)
  if (pct === 0) return { label: 'igual', direction: 'flat' }
  return { label: `${Math.abs(pct)} % ${pct > 0 ? 'más' : 'menos'}`, direction: pct > 0 ? 'up' : 'down' }
}
