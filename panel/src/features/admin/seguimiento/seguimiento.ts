import { diaOperativo, whatsappNumber } from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import { diasEntre } from '@/features/admin/cobranza/senales'
import { unoDe } from '@/lib/busqueda'
import { booleano, comoFila, comoLista, filaONula, numero, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// El seguimiento de las clínicas: a quién llamar, con qué número y qué se
// habló la última vez.
//
// Módulo puro: lo usan la pantalla, la ficha y las pruebas. Los canales y los
// motivos son los del `check` de `merchant_followups` (migración
// 20261021100000); uno mal escrito aquí es un contacto que la base rechaza.
// ═══════════════════════════════════════════════════════════════════════════

// ── Canal y motivo ─────────────────────────────────────────────────────────

export type CanalDeSeguimiento = 'llamada' | 'whatsapp' | 'visita' | 'correo'

/** En el orden en que se ofrecen: lo que más se usa, arriba. */
export const CANALES_DE_SEGUIMIENTO: readonly CanalDeSeguimiento[] = ['llamada', 'whatsapp', 'visita', 'correo']

export const ROTULO_CANAL_DE_SEGUIMIENTO: Record<CanalDeSeguimiento, string> = {
  llamada: 'Llamada',
  whatsapp: 'WhatsApp',
  visita: 'Visita',
  correo: 'Correo',
}

export type MotivoDeSeguimiento = 'seguimiento' | 'opinion' | 'soporte' | 'capacitacion'

export const MOTIVOS_DE_SEGUIMIENTO: readonly MotivoDeSeguimiento[] = [
  'seguimiento',
  'opinion',
  'soporte',
  'capacitacion',
]

export const ROTULO_MOTIVO: Record<MotivoDeSeguimiento, string> = {
  seguimiento: 'Cómo le va',
  opinion: 'Su opinión',
  soporte: 'Una duda o un problema',
  capacitacion: 'Capacitación',
}

// ── Lo que llega de la base ────────────────────────────────────────────────

/** El rol tal cual lo guarda la base; `inventario` es de Ronda y no se usa. */
export type RolDelPersonal = 'gerente' | 'cajero' | 'inventario'

export const ROTULO_ROL: Record<RolDelPersonal, string> = {
  gerente: 'Administrador',
  cajero: 'Secretaria',
  inventario: 'Inventario',
}

export type PersonaDeLaClinica = {
  userId: string
  nombre: string
  correo: string | null
  /** El número con el que usa el bot de WhatsApp (E.164), o `null`. */
  telefono: string | null
  rol: RolDelPersonal
  sede: string | null
  desde: string
  /** La última vez que abrió el panel o navegó en él (`staff_activity_days`). */
  ultimoPanel: string | null
  /** La última vez que le escribió al bot. */
  ultimoBot: string | null
  /** Cuántos de los últimos 30 días usó Helios, por el panel o por el bot. */
  diasDeUso30d: number
  /** Todas las que registró, la confirmara o no el paciente. */
  registradas: number
  confirmadas: number
  confirmadas30d: number
  porWhatsApp: number
  ultimaOrden: string | null
}

export type UltimoContacto = {
  cuando: string
  canal: CanalDeSeguimiento
  motivo: MotivoDeSeguimiento
  nota: string
  quien: string
  /** Con quién se habló; `null` es el consultorio, a su teléfono. */
  conQuien: string | null
}

export type ClinicaEnSeguimiento = {
  id: string
  nombre: string
  estado: 'active' | 'paused' | 'terminated'
  esPrueba: boolean
  ciudad: string | null
  especialidad: string | null
  telefono: string | null
  correo: string | null
  /** «Dra. Nadia Khabbaze Alfaro», o `null` si la clínica no tiene titular. */
  medico: string | null
  alta: string
  confirmadas: number
  confirmadas30d: number
  ultimaOrden: string | null
  personal: PersonaDeLaClinica[]
  contactos: number
  ultimoContacto: UltimoContacto | null
  /** 'YYYY-MM-DD': cuándo volver, según el último contacto. */
  volverEl: string | null
}

const ESTADOS = ['active', 'paused', 'terminated'] as const
const ROLES = ['gerente', 'cajero', 'inventario'] as const

function leerPersona(raw: unknown): PersonaDeLaClinica {
  const r = comoFila(raw)
  return {
    userId: texto(r.user_id),
    nombre: texto(r.name, 'Sin nombre'),
    correo: textoONulo(r.email),
    telefono: textoONulo(r.phone),
    rol: unoDe(ROLES, r.role) ?? 'cajero',
    sede: textoONulo(r.branch),
    desde: texto(r.joined_at),
    ultimoPanel: textoONulo(r.last_panel_at),
    ultimoBot: textoONulo(r.last_bot_at),
    diasDeUso30d: numero(r.active_days_30d),
    registradas: numero(r.orders_registered),
    confirmadas: numero(r.orders_confirmed),
    confirmadas30d: numero(r.orders_30d),
    porWhatsApp: numero(r.orders_whatsapp),
    ultimaOrden: textoONulo(r.last_order_at),
  }
}

function leerUltimoContacto(raw: unknown): UltimoContacto | null {
  const r = filaONula(raw)
  if (!r) return null
  return {
    cuando: texto(r.created_at),
    canal: unoDe(CANALES_DE_SEGUIMIENTO, r.channel) ?? 'llamada',
    motivo: unoDe(MOTIVOS_DE_SEGUIMIENTO, r.topic) ?? 'seguimiento',
    nota: texto(r.note),
    quien: texto(r.actor_name, 'Alguien del equipo'),
    conQuien: textoONulo(r.contact_name),
  }
}

/** `admin_followups_board()`. */
export function leerTablero(raw: unknown): ClinicaEnSeguimiento[] {
  return comoLista(raw).map((fila) => {
    const r = comoFila(fila)
    // Sin titular, `helios_doctor_name` devuelve el nombre de la clínica: aquí
    // eso no es un médico.
    const conTitular = textoONulo(r.owner_name) !== null
    return {
      id: texto(r.merchant_id),
      nombre: texto(r.name),
      estado: unoDe(ESTADOS, r.status) ?? 'active',
      esPrueba: booleano(r.is_test),
      ciudad: textoONulo(r.city),
      especialidad: textoONulo(r.specialty),
      telefono: textoONulo(r.phone),
      correo: textoONulo(r.email),
      medico: conTitular ? textoONulo(r.doctor_name) : null,
      alta: texto(r.created_at),
      confirmadas: numero(r.orders_confirmed),
      confirmadas30d: numero(r.orders_30d),
      ultimaOrden: textoONulo(r.last_order_at),
      personal: comoLista(r.staff).map(leerPersona),
      contactos: numero(r.followups_count),
      ultimoContacto: leerUltimoContacto(r.last_followup),
      volverEl: textoONulo(r.next_contact_on),
    }
  })
}

export type ContactoAnotado = {
  id: string
  cuando: string
  canal: CanalDeSeguimiento
  motivo: MotivoDeSeguimiento
  nota: string
  volverEl: string | null
  conQuien: string | null
  quien: string
}

/** `admin_merchant_followups(p_merchant_id)`. */
export function leerHistoria(raw: unknown): ContactoAnotado[] {
  return comoLista(raw).map((fila) => {
    const r = comoFila(fila)
    return {
      id: texto(r.id),
      cuando: texto(r.created_at),
      canal: unoDe(CANALES_DE_SEGUIMIENTO, r.channel) ?? 'llamada',
      motivo: unoDe(MOTIVOS_DE_SEGUIMIENTO, r.topic) ?? 'seguimiento',
      nota: texto(r.note),
      volverEl: textoONulo(r.next_contact_on),
      conQuien: textoONulo(r.contact_name),
      quien: texto(r.actor_name, 'Alguien del equipo'),
    }
  })
}

// ── Cómo va el seguimiento de una clínica ──────────────────────────────────

export type EstadoDelSeguimiento = 'atrasado' | 'hoy' | 'nunca' | 'programado' | 'al_dia'

export const ESTADO_DEL_SEGUIMIENTO: Record<EstadoDelSeguimiento, { label: string; tone: BadgeTone }> = {
  atrasado: { label: 'Llamar, se pasó la fecha', tone: 'error' },
  hoy: { label: 'Llamar hoy', tone: 'warning' },
  nunca: { label: 'Nunca contactada', tone: 'warning' },
  programado: { label: 'Programado', tone: 'neutral' },
  al_dia: { label: 'Sin pendientes', tone: 'success' },
}

/**
 * Lo que toca con una clínica hoy. `hoy` es el día operativo 'YYYY-MM-DD':
 * las fechas de la base son días de Caracas, y se comparan como texto.
 */
export function estadoDelSeguimiento(
  c: Pick<ClinicaEnSeguimiento, 'contactos' | 'volverEl'>,
  hoy: string,
): EstadoDelSeguimiento {
  if (c.volverEl !== null) {
    if (c.volverEl < hoy) return 'atrasado'
    if (c.volverEl === hoy) return 'hoy'
    return 'programado'
  }
  return c.contactos === 0 ? 'nunca' : 'al_dia'
}

const PUESTO: Record<EstadoDelSeguimiento, number> = {
  atrasado: 0,
  hoy: 1,
  nunca: 2,
  programado: 3,
  al_dia: 4,
}

/**
 * El orden de trabajo: lo que se pasó de fecha, lo de hoy, las que nadie ha
 * llamado nunca (primero las que más órdenes hacen: son las que más tienen
 * que contar), lo programado por fecha y, al final, las que no tienen nada
 * pendiente, la que lleva más tiempo sin contacto primero. Las terminadas y
 * las de prueba van detrás de todo.
 */
export function ordenarParaLlamar(
  clinicas: ReadonlyArray<ClinicaEnSeguimiento>,
  hoy: string,
): ClinicaEnSeguimiento[] {
  const atras = (c: ClinicaEnSeguimiento) => (c.estado === 'terminated' || c.esPrueba ? 1 : 0)
  return [...clinicas].sort((a, b) => {
    const pa = PUESTO[estadoDelSeguimiento(a, hoy)]
    const pb = PUESTO[estadoDelSeguimiento(b, hoy)]
    if (atras(a) !== atras(b)) return atras(a) - atras(b)
    if (pa !== pb) return pa - pb
    if (a.volverEl && b.volverEl && a.volverEl !== b.volverEl) return a.volverEl < b.volverEl ? -1 : 1
    const ua = a.ultimoContacto?.cuando ?? ''
    const ub = b.ultimoContacto?.cuando ?? ''
    if (ua !== ub) return ua < ub ? -1 : 1
    return b.confirmadas - a.confirmadas || a.nombre.localeCompare(b.nombre, 'es')
  })
}

// ── Qué se ve ──────────────────────────────────────────────────────────────

/**
 * `para_llamar`: lo que se pasó de fecha, lo de hoy y las que nunca se han
 * contactado. `activas`: sin las terminadas ni las de prueba. `todas`: todo.
 */
export type QueSeVe = 'para_llamar' | 'activas' | 'todas'

export const VALORES_QUE_SE_VE: readonly QueSeVe[] = ['para_llamar', 'activas', 'todas']

const PARA_LLAMAR: ReadonlySet<EstadoDelSeguimiento> = new Set(['atrasado', 'hoy', 'nunca'])

function esReal(c: ClinicaEnSeguimiento): boolean {
  return c.estado !== 'terminated' && !c.esPrueba
}

export function esParaLlamar(c: ClinicaEnSeguimiento, hoy: string): boolean {
  return esReal(c) && PARA_LLAMAR.has(estadoDelSeguimiento(c, hoy))
}

function sinTildes(t: string): string {
  return t.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase().trim()
}

/**
 * Las clínicas que se ven. La búsqueda va por la clínica, su médico, su
 * ciudad y cualquier persona de su personal (nombre o correo), y por los
 * dígitos de cualquier teléfono: «0414 999» encuentra «+584149990001».
 */
export function filtrarClinicas(
  clinicas: ReadonlyArray<ClinicaEnSeguimiento>,
  { texto: buscado = '', ver }: { texto?: string; ver: QueSeVe },
  hoy: string,
): ClinicaEnSeguimiento[] {
  return clinicas.filter((c) => {
    if (ver === 'activas' && !esReal(c)) return false
    if (ver === 'para_llamar' && !esParaLlamar(c, hoy)) return false
    return coincide(
      buscado,
      [c.nombre, c.medico, c.ciudad, c.especialidad, ...c.personal.flatMap((p) => [p.nombre, p.correo])],
      [c.telefono, ...c.personal.map((p) => p.telefono)],
    )
  })
}

/** En la vista por persona, la búsqueda va por la persona y su clínica. */
export function filtrarPersonas(
  personas: ReadonlyArray<PersonaConSuClinica>,
  buscado = '',
): PersonaConSuClinica[] {
  return personas.filter((p) => coincide(buscado, [p.nombre, p.correo, p.clinica], [p.telefono]))
}

function coincide(
  buscado: string,
  textos: ReadonlyArray<string | null>,
  telefonos: ReadonlyArray<string | null>,
): boolean {
  const aguja = sinTildes(buscado)
  if (!aguja) return true
  if (textos.some((t) => t !== null && sinTildes(t).includes(aguja))) return true
  const digitos = buscado.replace(/\D/g, '').replace(/^0/, '')
  return digitos.length >= 3 && telefonos.some((t) => t !== null && t.replace(/\D/g, '').includes(digitos))
}

// ── Prioridad de contacto ──────────────────────────────────────────────────

/**
 * El semáforo de a quién llamar para saber por qué no usa Helios. Cruza
 * cuántas órdenes confirmadas lleva en 30 días con cuántos días lleva sin usar
 * Helios (ni el panel ni el bot):
 *
 *   |                     | ≤ 7 días | 8–14 días | > 14 días o nunca |
 *   | con órdenes en 30 d | verde    | amarillo  | rojo              |
 *   | sin órdenes en 30 d | amarillo | rojo      | rojo              |
 */
export type Prioridad = 'contactar_ya' | 'contactar_pronto' | 'activo'

export const PRIORIDAD: Record<Prioridad, { label: string; tone: BadgeTone; puesto: number }> = {
  contactar_ya: { label: 'Contactar ya', tone: 'error', puesto: 0 },
  contactar_pronto: { label: 'Contactar pronto', tone: 'warning', puesto: 1 },
  activo: { label: 'Activo', tone: 'success', puesto: 2 },
}

/** Hasta aquí, usar Helios es reciente. */
export const DIAS_DE_USO_RECIENTE = 7
/** Más de esto sin usarlo es haberlo dejado, tenga las órdenes que tenga. */
export const DIAS_SIN_USO_MAXIMO = 14

export type PrioridadDeContacto = {
  prioridad: Prioridad
  /** Por qué, en una línea: «Sin usar Helios hace 18 días». */
  motivo: string
  /** Días operativos desde el último uso; `null` si nunca lo usó. */
  diasSinUso: number | null
}

/** La última vez que usó Helios, por el panel o por el bot. */
export function ultimoUso(p: Pick<PersonaDeLaClinica, 'ultimoPanel' | 'ultimoBot'>): string | null {
  if (p.ultimoPanel === null) return p.ultimoBot
  if (p.ultimoBot === null) return p.ultimoPanel
  return Date.parse(p.ultimoPanel) >= Date.parse(p.ultimoBot) ? p.ultimoPanel : p.ultimoBot
}

function dias(n: number): string {
  if (n === 0) return 'hoy'
  if (n === 1) return 'ayer'
  return `hace ${n} días`
}

export function prioridadDeContacto(
  { ultimoUso: uso, ordenes30d }: { ultimoUso: string | null; ordenes30d: number },
  ahora: Date,
): PrioridadDeContacto {
  if (uso === null) {
    return {
      prioridad: 'contactar_ya',
      motivo: ordenes30d > 0 ? 'No se le ve usar el panel ni el bot' : 'Nunca ha usado el panel ni el bot',
      diasSinUso: null,
    }
  }
  const diasSinUso = Math.max(0, diasEntre(diaOperativo(new Date(uso)), diaOperativo(ahora)))
  const sinOrdenes = ordenes30d === 0
  const cuando = `Usó Helios ${dias(diasSinUso)}`
  if (diasSinUso > DIAS_SIN_USO_MAXIMO) {
    return { prioridad: 'contactar_ya', motivo: `Sin usar Helios ${dias(diasSinUso)}`, diasSinUso }
  }
  if (diasSinUso > DIAS_DE_USO_RECIENTE) {
    return sinOrdenes
      ? { prioridad: 'contactar_ya', motivo: `${cuando} y sin órdenes en 30 días`, diasSinUso }
      : { prioridad: 'contactar_pronto', motivo: `Sin usar Helios ${dias(diasSinUso)}`, diasSinUso }
  }
  return sinOrdenes
    ? { prioridad: 'contactar_pronto', motivo: `${cuando}, pero sin órdenes en 30 días`, diasSinUso }
    : { prioridad: 'activo', motivo: `${cuando} · ${ordenes30d} ${ordenes30d === 1 ? 'orden' : 'órdenes'} en 30 días`, diasSinUso }
}

/**
 * La de la clínica entera: sus órdenes en 30 días y el uso más reciente de
 * cualquiera de su personal. `null` para las terminadas y las de prueba: ahí
 * no hay nadie a quien rescatar.
 */
export function prioridadDeLaClinica(c: ClinicaEnSeguimiento, ahora: Date): PrioridadDeContacto | null {
  if (!esReal(c)) return null
  const usos = c.personal.map(ultimoUso).filter((u): u is string => u !== null)
  const masReciente = usos.reduce<string | null>((a, u) => (a === null || Date.parse(u) > Date.parse(a) ? u : a), null)
  return prioridadDeContacto({ ultimoUso: masReciente, ordenes30d: c.confirmadas30d }, ahora)
}

/**
 * La de una persona: sus órdenes y su uso. Si su clínica sí usa Helios (otra
 * persona registra las órdenes, como la secretaria de un médico que no entra),
 * no es urgente: se queda en amarillo.
 */
export function prioridadDeLaPersona(
  p: PersonaDeLaClinica,
  clinica: ClinicaEnSeguimiento,
  ahora: Date,
): PrioridadDeContacto | null {
  const deLaClinica = prioridadDeLaClinica(clinica, ahora)
  if (deLaClinica === null) return null
  const propia = prioridadDeContacto({ ultimoUso: ultimoUso(p), ordenes30d: p.confirmadas30d }, ahora)
  if (propia.prioridad === 'contactar_ya' && deLaClinica.prioridad === 'activo') {
    return { ...propia, prioridad: 'contactar_pronto', motivo: `${propia.motivo}; su clínica sí lo usa` }
  }
  return propia
}

// ── Por persona ────────────────────────────────────────────────────────────

export type PersonaConSuClinica = PersonaDeLaClinica & {
  clinicaId: string
  clinica: string
  clinicaDePrueba: boolean
  clinicaTerminada: boolean
  /** `null` en una clínica terminada o de prueba. */
  prioridad: PrioridadDeContacto | null
}

/**
 * Todo el personal de todas las clínicas, en el orden en que hay que llamar:
 * rojo, amarillo, verde y, al final, las clínicas terminadas o de prueba.
 * Dentro de un color, quien más órdenes confirmadas tiene primero: es quien
 * más hay que recuperar si se va y a quien más vale la pena preguntarle cómo
 * funciona Helios. A igualdad, quien más registró y quien más tiempo lleva
 * sin usarlo.
 */
export function personasDelTablero(
  clinicas: ReadonlyArray<ClinicaEnSeguimiento>,
  ahora: Date,
): PersonaConSuClinica[] {
  const puesto = (p: PersonaConSuClinica) => (p.prioridad ? PRIORIDAD[p.prioridad.prioridad].puesto : 9)
  const sinUso = (p: PersonaConSuClinica) => p.prioridad?.diasSinUso ?? Number.POSITIVE_INFINITY
  return clinicas
    .flatMap((c) =>
      c.personal.map((p) => ({
        ...p,
        clinicaId: c.id,
        clinica: c.nombre,
        clinicaDePrueba: c.esPrueba,
        clinicaTerminada: c.estado === 'terminated',
        prioridad: prioridadDeLaPersona(p, c, ahora),
      })),
    )
    .sort(
      (a, b) =>
        puesto(a) - puesto(b) ||
        b.confirmadas - a.confirmadas ||
        b.registradas - a.registradas ||
        (sinUso(a) === sinUso(b) ? 0 : sinUso(b) > sinUso(a) ? 1 : -1) ||
        a.nombre.localeCompare(b.nombre, 'es'),
    )
}

// ── A quién se puede llamar ────────────────────────────────────────────────

export type Contactable = {
  /** El id del usuario, o `null` para el teléfono del consultorio. */
  userId: string | null
  nombre: string
  rol: string
  telefono: string
}

/**
 * Los teléfonos de una clínica: el del consultorio y el de cada persona del
 * personal que tiene uno. Sin teléfono no se puede llamar, así que no sale.
 * Casi siempre el médico titular es también la cuenta de administrador, con
 * el mismo número: entonces el consultorio no sale aparte.
 */
export function contactablesDe(c: ClinicaEnSeguimiento): Contactable[] {
  const deAlguien = new Set(c.personal.map((p) => whatsappNumber(p.telefono)).filter(Boolean))
  const consultorio: Contactable[] =
    c.telefono && !deAlguien.has(whatsappNumber(c.telefono))
      ? [{ userId: null, nombre: c.medico ?? c.nombre, rol: 'Consultorio', telefono: c.telefono }]
      : []
  return [
    ...consultorio,
    ...c.personal
      .filter((p) => p.telefono !== null)
      .map((p) => ({ userId: p.userId, nombre: p.nombre, rol: ROTULO_ROL[p.rol], telefono: p.telefono ?? '' })),
  ]
}

/** `tel:` con el número completo, para el teléfono o el softphone. */
export function enlaceDeLlamada(telefono: string): string | null {
  const digitos = whatsappNumber(telefono)
  return digitos ? `tel:+${digitos}` : null
}

/** El `wa_id` del chat de ese número en el inbox de Helios. */
export function chatDelInbox(telefono: string): string | null {
  return whatsappNumber(telefono) || null
}

// ── Anotar un contacto ─────────────────────────────────────────────────────

export type BorradorDeSeguimiento = {
  canal: CanalDeSeguimiento
  motivo: MotivoDeSeguimiento
  /** El id de la persona, o '' para el consultorio. */
  conQuien: string
  nota: string
  /** 'YYYY-MM-DD' o ''. */
  volverEl: string
}

export const NOTA_MAXIMA = 2000

export function borradorDeSeguimiento(inicial: Partial<BorradorDeSeguimiento> = {}): BorradorDeSeguimiento {
  return { canal: 'llamada', motivo: 'seguimiento', conQuien: '', nota: '', volverEl: '', ...inicial }
}

/** Por qué todavía no se puede anotar, con las mismas reglas que la base. */
export function motivoParaNoAnotarSeguimiento(b: BorradorDeSeguimiento, hoy: string): string | undefined {
  const nota = b.nota.trim()
  if (nota.length < 3) return 'Escribe qué se habló.'
  if (nota.length > NOTA_MAXIMA) return `La nota no puede pasar de ${NOTA_MAXIMA} caracteres.`
  if (b.volverEl && b.volverEl < hoy) return 'La fecha para volver a llamar ya pasó.'
  return undefined
}

/** Lo que se le manda a `admin_log_merchant_followup`. */
export function aParametros(merchantId: string, b: BorradorDeSeguimiento) {
  return {
    p_merchant_id: merchantId,
    p_channel: b.canal,
    p_topic: b.motivo,
    p_note: b.nota.trim(),
    p_contact_user_id: b.conQuien || null,
    p_next_contact_on: b.volverEl || null,
  }
}
