import { TIME_ZONE } from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import { sumarDias } from '@/components/kit/rango'
import { unoDe } from '@/lib/busqueda'
import { comoFila, comoLista, filaONula, numero, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// La agenda de médicos por afiliar: a quién llamar, en qué quedó cada uno y
// cuándo es la próxima reunión.
//
// Módulo puro: lo usan la pantalla, la ficha, el calendario y las pruebas.
// Los estados, los canales, los orígenes y los tipos de reunión son los de
// los `check` de `doctor_leads` (migración 20261022200000); uno mal escrito
// aquí es una gestión que la base rechaza.
// ═══════════════════════════════════════════════════════════════════════════

// ── Los catálogos ──────────────────────────────────────────────────────────

export type EstadoDelLead =
  | 'nuevo'
  | 'contactado'
  | 'respondio'
  | 'no_respondio'
  | 'reunion'
  | 'convertido'
  | 'descartado'

/** En el orden del embudo. */
export const ESTADOS_DEL_LEAD: readonly EstadoDelLead[] = [
  'nuevo',
  'contactado',
  'respondio',
  'no_respondio',
  'reunion',
  'convertido',
  'descartado',
]

export const ESTADO_DEL_LEAD: Record<EstadoDelLead, { label: string; tone: BadgeTone }> = {
  nuevo: { label: 'Sin contactar', tone: 'neutral' },
  contactado: { label: 'Contactado', tone: 'brand' },
  respondio: { label: 'Respondió', tone: 'brand' },
  no_respondio: { label: 'No respondió', tone: 'warning' },
  reunion: { label: 'Reunión agendada', tone: 'brand' },
  convertido: { label: 'Afiliado', tone: 'success' },
  descartado: { label: 'Descartado', tone: 'neutral' },
}

export type CanalDelLead = 'llamada' | 'whatsapp' | 'visita' | 'correo' | 'redes'

export const CANALES_DEL_LEAD: readonly CanalDelLead[] = ['llamada', 'whatsapp', 'visita', 'correo', 'redes']

export const ROTULO_CANAL: Record<CanalDelLead, string> = {
  llamada: 'Llamada',
  whatsapp: 'WhatsApp',
  visita: 'Visita',
  correo: 'Correo',
  redes: 'Redes sociales',
}

export type OrigenDelLead = 'referido' | 'redes' | 'visita' | 'evento' | 'base_de_datos' | 'otro'

export const ORIGENES_DEL_LEAD: readonly OrigenDelLead[] = [
  'referido',
  'redes',
  'visita',
  'evento',
  'base_de_datos',
  'otro',
]

export const ROTULO_ORIGEN: Record<OrigenDelLead, string> = {
  referido: 'Referido',
  redes: 'Redes sociales',
  visita: 'Visita en frío',
  evento: 'Evento o congreso',
  base_de_datos: 'Base de datos',
  otro: 'Otro',
}

export type ModoDeReunion = 'presencial' | 'videollamada' | 'llamada'

export const MODOS_DE_REUNION: readonly ModoDeReunion[] = ['presencial', 'videollamada', 'llamada']

export const ROTULO_MODO: Record<ModoDeReunion, string> = {
  presencial: 'Presencial',
  videollamada: 'Videollamada',
  llamada: 'Llamada',
}

export type ViaDeAfiliacion = 'formulario' | 'alta' | 'agenda' | 'manual'

const VIAS: readonly ViaDeAfiliacion[] = ['formulario', 'alta', 'agenda', 'manual']

export const ROTULO_VIA: Record<ViaDeAfiliacion, string> = {
  formulario: 'Llenó el formulario de afiliación',
  alta: 'Se dio de alta su clínica',
  agenda: 'Ya era cliente al apuntarlo',
  manual: 'Marcado a mano',
}

export type PorQueSeReconocio = 'telefono' | 'correo' | 'nombre'

const RAZONES: readonly PorQueSeReconocio[] = ['telefono', 'correo', 'nombre']

export const ROTULO_RAZON: Record<PorQueSeReconocio, string> = {
  telefono: 'por su teléfono',
  correo: 'por su correo',
  nombre: 'por su nombre',
}

export const NOTA_MAXIMA = 2000

// ── Lo que llega de la base ────────────────────────────────────────────────

export type UltimaGestion = {
  cuando: string
  tipo: 'creado' | 'gestion' | 'conversion'
  canal: CanalDelLead | null
  estado: EstadoDelLead | null
  nota: string | null
  /** `null`: la anotó el sistema (la afiliación). */
  quien: string | null
}

export type Lead = {
  id: string
  nombre: string
  consultorio: string | null
  especialidad: string | null
  /** E.164. */
  telefono: string | null
  correo: string | null
  direccion: string | null
  ciudad: string | null
  origen: OrigenDelLead | null
  notas: string | null
  estado: EstadoDelLead
  /** Instante ISO de la reunión: la próxima, o la última si ya pasó. */
  reunion: string | null
  modo: ModoDeReunion | null
  lugar: string | null
  /** 'YYYY-MM-DD'. */
  volverEl: string | null
  responsableId: string | null
  responsable: string | null
  afiliadoEl: string | null
  via: ViaDeAfiliacion | null
  razon: PorQueSeReconocio | null
  solicitudId: string | null
  solicitudEstado: 'pending' | 'approved' | 'rejected' | null
  clinicaId: string | null
  clinica: string | null
  creado: string
  gestiones: number
  ultima: UltimaGestion | null
}

const TIPOS = ['creado', 'gestion', 'conversion'] as const
const ESTADOS_SOLICITUD = ['pending', 'approved', 'rejected'] as const

function leerUltima(raw: unknown): UltimaGestion | null {
  const r = filaONula(raw)
  if (!r) return null
  return {
    cuando: texto(r.created_at),
    tipo: unoDe(TIPOS, r.kind) ?? 'gestion',
    canal: unoDe(CANALES_DEL_LEAD, r.channel) ?? null,
    estado: unoDe(ESTADOS_DEL_LEAD, r.status_to) ?? null,
    nota: textoONulo(r.note),
    quien: textoONulo(r.actor_name),
  }
}

/** `admin_doctor_leads()`. */
export function leerAgenda(raw: unknown): Lead[] {
  return comoLista(raw).map((fila) => {
    const r = comoFila(fila)
    return {
      id: texto(r.id),
      nombre: texto(r.name),
      consultorio: textoONulo(r.clinic_name),
      especialidad: textoONulo(r.specialty),
      telefono: textoONulo(r.phone),
      correo: textoONulo(r.email),
      direccion: textoONulo(r.address),
      ciudad: textoONulo(r.city),
      origen: unoDe(ORIGENES_DEL_LEAD, r.source) ?? null,
      notas: textoONulo(r.notes),
      estado: unoDe(ESTADOS_DEL_LEAD, r.status) ?? 'nuevo',
      reunion: textoONulo(r.meeting_at),
      modo: unoDe(MODOS_DE_REUNION, r.meeting_mode) ?? null,
      lugar: textoONulo(r.meeting_place),
      volverEl: textoONulo(r.next_contact_on),
      responsableId: textoONulo(r.assigned_to),
      responsable: textoONulo(r.assigned_name),
      afiliadoEl: textoONulo(r.converted_at),
      via: unoDe(VIAS, r.converted_via) ?? null,
      razon: unoDe(RAZONES, r.match_reason) ?? null,
      solicitudId: textoONulo(r.application_id),
      solicitudEstado: unoDe(ESTADOS_SOLICITUD, r.application_status) ?? null,
      clinicaId: textoONulo(r.merchant_id),
      clinica: textoONulo(r.merchant_name),
      creado: texto(r.created_at),
      gestiones: numero(r.activities_count),
      ultima: leerUltima(r.last_activity),
    }
  })
}

export type Gestion = {
  id: string
  cuando: string
  tipo: UltimaGestion['tipo']
  canal: CanalDelLead | null
  antes: EstadoDelLead | null
  despues: EstadoDelLead | null
  reunion: string | null
  nota: string | null
  quien: string | null
}

/** `admin_doctor_lead_activities(p_lead_id)`. */
export function leerHistoria(raw: unknown): Gestion[] {
  return comoLista(raw).map((fila) => {
    const r = comoFila(fila)
    return {
      id: texto(r.id),
      cuando: texto(r.created_at),
      tipo: unoDe(TIPOS, r.kind) ?? 'gestion',
      canal: unoDe(CANALES_DEL_LEAD, r.channel) ?? null,
      antes: unoDe(ESTADOS_DEL_LEAD, r.status_from) ?? null,
      despues: unoDe(ESTADOS_DEL_LEAD, r.status_to) ?? null,
      reunion: textoONulo(r.meeting_at),
      nota: textoONulo(r.note),
      quien: textoONulo(r.actor_name),
    }
  })
}

// ── Las horas de Caracas ───────────────────────────────────────────────────

/**
 * El día de Caracas de un instante: 'YYYY-MM-DD'. Una reunión a las 9 de la
 * noche es de ese día, aunque en UTC ya sea el siguiente.
 */
export function diaDeCaracas(instante: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TIME_ZONE }).format(new Date(instante))
}

/** La hora de Caracas de un instante: 'HH:MM', para un `<input type="time">`. */
export function horaDeCaracas(instante: string): string {
  return new Intl.DateTimeFormat('en-GB', {
    timeZone: TIME_ZONE,
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).format(new Date(instante))
}

/**
 * El instante de un día y una hora de Caracas, para la base. Venezuela está
 * en UTC−4 todo el año (sin horario de verano desde 2016), así que basta con
 * escribir el desfase.
 */
export function instanteDeCaracas(dia: string, hora: string): string {
  return `${dia}T${hora}:00-04:00`
}

// ── Qué toca con cada uno ──────────────────────────────────────────────────

/** Ya no se trabaja: afiliado o descartado. */
export function estaCerrado(l: Pick<Lead, 'estado'>): boolean {
  return l.estado === 'convertido' || l.estado === 'descartado'
}

/** Una reunión agendada cuya hora ya pasó y nadie anotó cómo fue. */
export function reunionSinResultado(l: Pick<Lead, 'estado' | 'reunion'>, ahora: Date): boolean {
  return l.estado === 'reunion' && l.reunion !== null && new Date(l.reunion) < ahora
}

export type Pendiente = 'reunion_pasada' | 'llamar_atrasado' | 'llamar_hoy' | 'reunion_hoy' | 'sin_contactar'

export const PENDIENTE: Record<Pendiente, { label: string; tone: BadgeTone }> = {
  reunion_pasada: { label: 'Anotar cómo fue la reunión', tone: 'error' },
  llamar_atrasado: { label: 'Llamar, se pasó la fecha', tone: 'error' },
  reunion_hoy: { label: 'Reunión hoy', tone: 'warning' },
  llamar_hoy: { label: 'Llamar hoy', tone: 'warning' },
  sin_contactar: { label: 'Sin contactar', tone: 'warning' },
}

/**
 * Lo que hay que hacer hoy con un lead, o `null` si nada. `hoy` es el día de
 * Caracas 'YYYY-MM-DD'.
 */
export function pendienteDe(l: Lead, hoy: string, ahora: Date): Pendiente | null {
  if (estaCerrado(l)) return null
  if (reunionSinResultado(l, ahora)) return 'reunion_pasada'
  if (l.volverEl !== null && l.volverEl < hoy) return 'llamar_atrasado'
  if (l.estado === 'reunion' && l.reunion !== null && diaDeCaracas(l.reunion) === hoy) return 'reunion_hoy'
  if (l.volverEl === hoy) return 'llamar_hoy'
  if (l.estado === 'nuevo') return 'sin_contactar'
  return null
}

const PUESTO: Record<Pendiente, number> = {
  reunion_pasada: 0,
  llamar_atrasado: 1,
  reunion_hoy: 2,
  llamar_hoy: 3,
  sin_contactar: 4,
}

/**
 * El orden de trabajo: lo pendiente primero (lo atrasado, lo de hoy, los que
 * nadie ha llamado), después los abiertos por su próxima cita (reunión o
 * llamada), y al final los cerrados, el más reciente primero.
 */
export function ordenarAgenda(leads: ReadonlyArray<Lead>, hoy: string, ahora: Date): Lead[] {
  const proxima = (l: Lead) => {
    const r = l.estado === 'reunion' && l.reunion ? diaDeCaracas(l.reunion) : null
    const v = l.volverEl
    if (r && v) return r < v ? r : v
    return r ?? v ?? '9999-12-31'
  }
  return [...leads].sort((a, b) => {
    const ca = estaCerrado(a) ? 1 : 0
    const cb = estaCerrado(b) ? 1 : 0
    if (ca !== cb) return ca - cb
    if (ca === 1) return b.creado.localeCompare(a.creado)
    const pa = pendienteDe(a, hoy, ahora)
    const pb = pendienteDe(b, hoy, ahora)
    const na = pa === null ? 9 : PUESTO[pa]
    const nb = pb === null ? 9 : PUESTO[pb]
    if (na !== nb) return na - nb
    const xa = proxima(a)
    const xb = proxima(b)
    if (xa !== xb) return xa < xb ? -1 : 1
    return a.nombre.localeCompare(b.nombre, 'es')
  })
}

// ── Qué se ve ──────────────────────────────────────────────────────────────

/**
 * `para_hoy`: lo que tiene algo pendiente hoy. `abiertos`: sin los afiliados
 * ni los descartados. `afiliados` y `descartados`: solo esos. `todos`: todo.
 */
export type QueSeVe = 'para_hoy' | 'abiertos' | 'afiliados' | 'descartados' | 'todos'

export const VALORES_QUE_SE_VE: readonly QueSeVe[] = ['para_hoy', 'abiertos', 'afiliados', 'descartados', 'todos']

function sinTildes(t: string): string {
  return t.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase().trim()
}

/**
 * Los leads que se ven. La búsqueda va por el nombre, el consultorio, la
 * especialidad, la ciudad, la dirección y el correo, y por los dígitos del
 * teléfono: «0414 700» encuentra «+584147000001».
 */
export function filtrarAgenda(
  leads: ReadonlyArray<Lead>,
  { texto: buscado = '', ver, estado }: { texto?: string; ver: QueSeVe; estado?: EstadoDelLead },
  hoy: string,
  ahora: Date,
): Lead[] {
  const aguja = sinTildes(buscado)
  const digitos = buscado.replace(/\D/g, '').replace(/^0/, '')
  return leads.filter((l) => {
    if (estado && l.estado !== estado) return false
    if (ver === 'para_hoy' && pendienteDe(l, hoy, ahora) === null) return false
    if (ver === 'abiertos' && estaCerrado(l)) return false
    if (ver === 'afiliados' && l.estado !== 'convertido') return false
    if (ver === 'descartados' && l.estado !== 'descartado') return false
    if (!aguja) return true
    const textos = [l.nombre, l.consultorio, l.especialidad, l.ciudad, l.direccion, l.correo]
    if (textos.some((t) => t !== null && sinTildes(t).includes(aguja))) return true
    return digitos.length >= 3 && l.telefono !== null && l.telefono.replace(/\D/g, '').includes(digitos)
  })
}

/** Cuántos hay en cada estado, para el resumen y el embudo. */
export function cuentaPorEstado(leads: ReadonlyArray<Lead>): Record<EstadoDelLead, number> {
  const cuenta = Object.fromEntries(ESTADOS_DEL_LEAD.map((e) => [e, 0])) as Record<EstadoDelLead, number>
  for (const l of leads) cuenta[l.estado] += 1
  return cuenta
}

// ── El calendario ──────────────────────────────────────────────────────────

export type Cita = {
  lead: Lead
  /** 'reunion': la reunión agendada. 'llamada': el día de volver a llamar. */
  tipo: 'reunion' | 'llamada'
  dia: string
  /** 'HH:MM' de la reunión; las llamadas no tienen hora. */
  hora: string | null
}

/**
 * Las citas de la agenda: las reuniones (también las que ya pasaron, para
 * ver lo hecho) y los días de volver a llamar de los que siguen abiertos. En
 * orden de día y hora; las llamadas, detrás de las reuniones de su día.
 */
export function citasDe(leads: ReadonlyArray<Lead>): Cita[] {
  const citas: Cita[] = []
  for (const l of leads) {
    if (l.reunion) citas.push({ lead: l, tipo: 'reunion', dia: diaDeCaracas(l.reunion), hora: horaDeCaracas(l.reunion) })
    if (l.volverEl && !estaCerrado(l)) citas.push({ lead: l, tipo: 'llamada', dia: l.volverEl, hora: null })
  }
  return citas.sort(
    (a, b) =>
      a.dia.localeCompare(b.dia) ||
      (a.tipo === b.tipo ? 0 : a.tipo === 'reunion' ? -1 : 1) ||
      (a.hora ?? '').localeCompare(b.hora ?? '') ||
      a.lead.nombre.localeCompare(b.lead.nombre, 'es'),
  )
}

/** 0 = lunes … 6 = domingo. */
function diaDeLaSemana(dia: string): number {
  const [y = 0, m = 1, d = 1] = dia.split('-').map(Number)
  return (new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7
}

/** El día 1 del mes que está `n` meses más allá. */
export function mesDeAlLado(mes: string, n: number): string {
  const [y = 0, m = 1] = mes.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1 + n, 1)).toISOString().slice(0, 10)
}

/**
 * Las casillas del mes, de lunes a domingo: las semanas que lo tocan, con los
 * días de los meses de al lado para completar la primera y la última.
 */
export function casillasDelMes(mes: string): string[] {
  const inicio = sumarDias(mes, -diaDeLaSemana(mes))
  const siguiente = mesDeAlLado(mes, 1)
  const fin = sumarDias(siguiente, -1)
  const dias: string[] = []
  for (let d = inicio; d <= fin || diaDeLaSemana(d) !== 0; d = sumarDias(d, 1)) dias.push(d)
  return dias
}

// ── Apuntar y corregir ─────────────────────────────────────────────────────

export type BorradorDeLead = {
  nombre: string
  consultorio: string
  especialidad: string
  telefono: string
  correo: string
  direccion: string
  ciudad: string
  origen: OrigenDelLead | ''
  notas: string
  responsableId: string
}

export function borradorDeLead(l?: Lead): BorradorDeLead {
  return {
    nombre: l?.nombre ?? '',
    consultorio: l?.consultorio ?? '',
    especialidad: l?.especialidad ?? '',
    telefono: l?.telefono ?? '',
    correo: l?.correo ?? '',
    direccion: l?.direccion ?? '',
    ciudad: l?.ciudad ?? '',
    origen: l?.origen ?? '',
    notas: l?.notas ?? '',
    responsableId: l?.responsableId ?? '',
  }
}

/** Por qué no se puede guardar todavía, o `undefined` si se puede. */
export function motivoParaNoGuardar(b: BorradorDeLead): string | undefined {
  if (b.nombre.trim().length < 3) return 'Escribe el nombre del médico.'
  const digitos = b.telefono.replace(/\D/g, '')
  if (digitos && !/^(58)?0?\d{10}$/.test(digitos)) return 'El teléfono no parece venezolano.'
  if (b.correo.trim() && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(b.correo.trim())) return 'El correo no parece un correo.'
  return undefined
}

/** El `p` de `admin_save_doctor_lead`. */
export function aDatos(b: BorradorDeLead): Record<string, string | null> {
  const o = (t: string) => t.trim() || null
  return {
    name: b.nombre.trim(),
    clinic_name: o(b.consultorio),
    specialty: o(b.especialidad),
    phone: o(b.telefono),
    email: o(b.correo),
    address: o(b.direccion),
    city: o(b.ciudad),
    source: b.origen || null,
    notes: o(b.notas),
    assigned_to: b.responsableId || null,
  }
}

// ── Anotar una gestión ─────────────────────────────────────────────────────

export type BorradorDeGestion = {
  estado: EstadoDelLead
  canal: CanalDelLead | ''
  nota: string
  /** 'YYYY-MM-DD' y 'HH:MM' de la reunión, en Caracas. */
  reunionDia: string
  reunionHora: string
  modo: ModoDeReunion
  lugar: string
  volverEl: string
}

/** El estado al que se suele pasar desde cada uno: lo que se propone. */
const SIGUIENTE: Record<EstadoDelLead, EstadoDelLead> = {
  nuevo: 'contactado',
  contactado: 'respondio',
  respondio: 'reunion',
  no_respondio: 'no_respondio',
  reunion: 'reunion',
  convertido: 'convertido',
  descartado: 'descartado',
}

export function borradorDeGestion(l: Lead): BorradorDeGestion {
  const conReunion = l.estado === 'reunion' && l.reunion !== null
  return {
    estado: SIGUIENTE[l.estado],
    canal: 'llamada',
    nota: '',
    reunionDia: conReunion && l.reunion ? diaDeCaracas(l.reunion) : '',
    reunionHora: conReunion && l.reunion ? horaDeCaracas(l.reunion) : '10:00',
    modo: l.modo ?? 'presencial',
    lugar: l.lugar ?? l.direccion ?? '',
    volverEl: '',
  }
}

/**
 * La reunión cambia si se pide «Reunión agendada» con un día o una hora
 * distintos de los que tenía. Sin cambio, no se manda: la base la conserva.
 */
function reunionNueva(b: BorradorDeGestion, l: Lead): string | null {
  if (b.estado !== 'reunion' || !b.reunionDia || !b.reunionHora) return null
  const instante = instanteDeCaracas(b.reunionDia, b.reunionHora)
  if (l.reunion && new Date(l.reunion).getTime() === new Date(instante).getTime()) return null
  return instante
}

/** Por qué no se puede anotar todavía, o `undefined` si se puede. */
export function motivoParaNoAnotar(b: BorradorDeGestion, l: Lead, hoy: string, ahora: Date): string | undefined {
  if (b.estado === 'reunion') {
    if (!b.reunionDia || !b.reunionHora) return 'Pon el día y la hora de la reunión.'
    if (b.reunionDia < hoy) return 'La fecha de la reunión ya pasó.'
    const sigueLaMisma = reunionNueva(b, l) === null
    if (sigueLaMisma && reunionSinResultado(l, ahora)) {
      return 'Esa reunión ya pasó: cuenta cómo fue (cambia el estado) o pon otra fecha.'
    }
  }
  if (b.volverEl && b.volverEl < hoy) return 'La fecha para volver a llamar ya pasó.'
  if (b.nota.length > NOTA_MAXIMA) return `La nota no puede pasar de ${NOTA_MAXIMA} caracteres.`
  const cambia = b.estado !== l.estado || reunionNueva(b, l) !== null || (b.volverEl || null) !== l.volverEl
  if (!cambia && !b.nota.trim() && !b.canal) return 'Cuenta qué pasó o cambia el estado.'
  return undefined
}

/** Si al anotar se anula una reunión que todavía no ha sido. */
export function anulaLaReunion(b: BorradorDeGestion, l: Lead, ahora: Date): boolean {
  return l.estado === 'reunion' && b.estado !== 'reunion' && l.reunion !== null && new Date(l.reunion) > ahora
}

/** Los parámetros de `admin_log_doctor_lead_contact`. */
export function aParametros(leadId: string, b: BorradorDeGestion, l: Lead) {
  const nueva = reunionNueva(b, l)
  const enReunion = b.estado === 'reunion'
  return {
    p_lead_id: leadId,
    p_status: b.estado,
    p_channel: b.canal || undefined,
    p_note: b.nota.trim() || undefined,
    p_meeting_at: nueva ?? undefined,
    p_meeting_mode: enReunion ? b.modo : undefined,
    p_meeting_place: enReunion ? b.lugar.trim() || undefined : undefined,
    p_next_contact_on: b.volverEl || undefined,
  }
}
