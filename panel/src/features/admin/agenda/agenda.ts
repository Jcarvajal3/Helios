import { TIME_ZONE } from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import { MESES_CORTOS, sumarDias } from '@/components/kit/rango'
import { unoDe } from '@/lib/busqueda'
import { comoFila, comoLista, filaONula, numero, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// La agenda de médicos por afiliar: a quién llamar, en qué quedó cada uno y
// cuándo es la próxima visita.
//
// Módulo puro: lo usan la pantalla, la ficha, el calendario y las pruebas.
// Los estados, los canales, los resultados y los tipos de visita son los de
// los `check` de `doctor_leads` y `doctor_lead_activities` (migraciones
// 20261022200000 y 20261022210000); uno mal escrito aquí es una gestión que
// la base rechaza. En la base la visita se llama `meeting` (`reunion`).
// ═══════════════════════════════════════════════════════════════════════════

// ── Los catálogos ──────────────────────────────────────────────────────────

export type EstadoDelLead =
  | 'nuevo'
  | 'contactado'
  | 'no_respondio'
  | 'respondio'
  | 'reunion'
  | 'visitado'
  | 'convertido'
  | 'descartado'

/** En el orden del embudo. */
export const ESTADOS_DEL_LEAD: readonly EstadoDelLead[] = [
  'nuevo',
  'contactado',
  'no_respondio',
  'respondio',
  'reunion',
  'visitado',
  'convertido',
  'descartado',
]

export const ESTADO_DEL_LEAD: Record<EstadoDelLead, { label: string; tone: BadgeTone }> = {
  nuevo: { label: 'Sin contactar', tone: 'neutral' },
  contactado: { label: 'Mensaje enviado', tone: 'brand' },
  no_respondio: { label: 'No contestó', tone: 'warning' },
  respondio: { label: 'Interesado', tone: 'brand' },
  reunion: { label: 'Visita agendada', tone: 'brand' },
  visitado: { label: 'Visita realizada', tone: 'brand' },
  convertido: { label: 'Afiliado', tone: 'success' },
  descartado: { label: 'No interesado', tone: 'neutral' },
}

export type CanalDelLead = 'mensaje' | 'llamada' | 'whatsapp' | 'visita' | 'correo' | 'redes'

const CANALES_DEL_LEAD: readonly CanalDelLead[] = ['mensaje', 'llamada', 'whatsapp', 'visita', 'correo', 'redes']

export const ROTULO_CANAL: Record<CanalDelLead, string> = {
  mensaje: 'Mensaje',
  llamada: 'Llamada',
  whatsapp: 'WhatsApp',
  visita: 'Visita',
  correo: 'Correo',
  redes: 'Redes sociales',
}

export type ModoDeVisita = 'presencial' | 'videollamada' | 'llamada'

export const MODOS_DE_VISITA: readonly ModoDeVisita[] = ['presencial', 'videollamada', 'llamada']

export const ROTULO_MODO: Record<ModoDeVisita, string> = {
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

// ── El árbol de la gestión ─────────────────────────────────────────────────

/**
 * Qué pasó en una gestión. Es el árbol del equipo:
 *
 *   Mensaje → mensaje enviado · contestó (interesado / no interesado) · no contestó
 *   Llamada → contestó (interesado / no interesado) · no contestó · teléfono ocupado
 *   Visita  → agendada con su fecha; después realizada · pospuesta · cancelada
 *
 * Y dos sueltos: «se afilió» y «solo una nota».
 */
export type Resultado =
  | 'mensaje_enviado'
  | 'interesado'
  | 'no_interesado'
  | 'no_contesto'
  | 'ocupado'
  | 'visita_agendada'
  | 'visita_realizada'
  | 'visita_pospuesta'
  | 'visita_cancelada'
  | 'afiliado'
  | 'nota'

const RESULTADOS: readonly Resultado[] = [
  'mensaje_enviado',
  'interesado',
  'no_interesado',
  'no_contesto',
  'ocupado',
  'visita_agendada',
  'visita_realizada',
  'visita_pospuesta',
  'visita_cancelada',
  'afiliado',
  'nota',
]

export const ROTULO_RESULTADO: Record<Resultado, string> = {
  mensaje_enviado: 'Mensaje enviado',
  interesado: 'Contestó: interesado',
  no_interesado: 'Contestó: no interesado',
  no_contesto: 'No contestó',
  ocupado: 'Teléfono ocupado',
  visita_agendada: 'Visita agendada',
  visita_realizada: 'Visita realizada',
  visita_pospuesta: 'Visita pospuesta',
  visita_cancelada: 'Visita cancelada',
  afiliado: 'Se afilió',
  nota: 'Nota',
}

/** El estado en que queda el lead con cada resultado: el mismo cálculo que la base. */
export function estadoDelResultado(r: Resultado, l: Pick<Lead, 'estado'>): EstadoDelLead {
  const estado: Record<Exclude<Resultado, 'nota'>, EstadoDelLead> = {
    mensaje_enviado: 'contactado',
    interesado: 'respondio',
    no_interesado: 'descartado',
    no_contesto: 'no_respondio',
    ocupado: 'no_respondio',
    visita_agendada: 'reunion',
    visita_pospuesta: 'reunion',
    visita_realizada: 'visitado',
    visita_cancelada: 'respondio',
    afiliado: 'convertido',
  }
  return r === 'nota' ? l.estado : estado[r]
}

/** La primera rama: por dónde fue la gestión. */
export type TipoDeGestion = 'mensaje' | 'llamada' | 'visita'

export const TIPOS_DE_GESTION: readonly TipoDeGestion[] = ['mensaje', 'llamada', 'visita']

/** La segunda rama de cada tipo. «Contestó» abre la tercera: interesado o no. */
export type Respuesta = 'enviado' | 'contesto' | 'no_contesto' | 'ocupado' | 'realizada' | 'pospuesta' | 'cancelada'

export const RESPUESTAS: Record<TipoDeGestion, readonly Respuesta[]> = {
  mensaje: ['enviado', 'contesto', 'no_contesto'],
  llamada: ['contesto', 'no_contesto', 'ocupado'],
  visita: ['realizada', 'pospuesta', 'cancelada'],
}

export const ROTULO_RESPUESTA: Record<Respuesta, string> = {
  enviado: 'Mensaje enviado',
  contesto: 'Contestó',
  no_contesto: 'No contestó',
  ocupado: 'Teléfono ocupado',
  realizada: 'Realizada',
  pospuesta: 'Pospuesta',
  cancelada: 'Cancelada',
}

/** Lo elegido en el árbol, rama por rama. */
export type Eleccion = {
  tipo: TipoDeGestion | 'afiliado' | 'nota' | null
  respuesta: Respuesta | null
  interesado: boolean | null
}

export const SIN_ELEGIR: Eleccion = { tipo: null, respuesta: null, interesado: null }

/**
 * El resultado de lo elegido, o `null` si falta una rama. Una visita sin una
 * agendada es agendarla; con una agendada, se dice qué pasó con ella.
 */
export function resultadoDe(e: Eleccion, conVisita: boolean): Resultado | null {
  if (e.tipo === 'afiliado' || e.tipo === 'nota') return e.tipo
  if (e.tipo === 'visita') {
    if (!conVisita) return 'visita_agendada'
    if (e.respuesta === 'realizada') return 'visita_realizada'
    if (e.respuesta === 'pospuesta') return 'visita_pospuesta'
    if (e.respuesta === 'cancelada') return 'visita_cancelada'
    return null
  }
  if (e.tipo === null) return null
  if (e.respuesta === 'enviado') return 'mensaje_enviado'
  if (e.respuesta === 'no_contesto') return 'no_contesto'
  if (e.respuesta === 'ocupado') return 'ocupado'
  if (e.respuesta === 'contesto' && e.interesado !== null) return e.interesado ? 'interesado' : 'no_interesado'
  return null
}

/** El canal que se guarda con cada tipo. */
export function canalDe(e: Eleccion): CanalDelLead | null {
  if (e.tipo === 'mensaje' || e.tipo === 'llamada' || e.tipo === 'visita') return e.tipo
  return null
}

/** Si el resultado pone fecha a la visita. */
export function pideFechaDeVisita(r: Resultado | null): boolean {
  return r === 'visita_agendada' || r === 'visita_pospuesta'
}

/**
 * Cuándo volver a llamar, propuesto según lo que pasó: al día siguiente si
 * no contestó o estaba ocupado, a los dos días si solo se le mandó el
 * mensaje. En días desde hoy; `null` es sin fecha.
 */
export function volverPropuesto(r: Resultado): number | null {
  if (r === 'no_contesto' || r === 'ocupado') return 1
  if (r === 'mensaje_enviado') return 2
  return null
}

/** Si con ese resultado tiene sentido poner cuándo volver a llamar. */
export function pideVolver(r: Resultado): boolean {
  return !pideFechaDeVisita(r) && r !== 'no_interesado' && r !== 'afiliado'
}

/** El paso del embudo en que va un lead: 0 sin contactar … 4 afiliado. */
export function pasoDelEmbudo(e: EstadoDelLead): number {
  const paso: Record<EstadoDelLead, number> = {
    nuevo: 0,
    contactado: 1,
    no_respondio: 1,
    respondio: 2,
    reunion: 3,
    visitado: 3,
    convertido: 4,
    descartado: 0,
  }
  return paso[e]
}

// ── Lo que llega de la base ────────────────────────────────────────────────

export type UltimaGestion = {
  cuando: string
  tipo: 'creado' | 'gestion' | 'conversion'
  resultado: Resultado | null
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
  direccion: string | null
  notas: string | null
  estado: EstadoDelLead
  /** Instante ISO de la visita: la próxima, o la última si ya pasó. */
  reunion: string | null
  modo: ModoDeVisita | null
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
  /** La capacitación presencial que pidió en el formulario (instante ISO). */
  capacitacion: string | null
  clinicaId: string | null
  clinica: string | null
  /** Su clínica ya tiene sus accesos: es lo que lo deja afiliado. */
  conAccesos: boolean
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
    resultado: unoDe(RESULTADOS, r.result) ?? null,
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
      direccion: textoONulo(r.address),
      notas: textoONulo(r.notes),
      estado: unoDe(ESTADOS_DEL_LEAD, r.status) ?? 'nuevo',
      reunion: textoONulo(r.meeting_at),
      modo: unoDe(MODOS_DE_VISITA, r.meeting_mode) ?? null,
      lugar: textoONulo(r.meeting_place),
      volverEl: textoONulo(r.next_contact_on),
      responsableId: textoONulo(r.assigned_to),
      responsable: textoONulo(r.assigned_name),
      afiliadoEl: textoONulo(r.converted_at),
      via: unoDe(VIAS, r.converted_via) ?? null,
      razon: unoDe(RAZONES, r.match_reason) ?? null,
      solicitudId: textoONulo(r.application_id),
      solicitudEstado: unoDe(ESTADOS_SOLICITUD, r.application_status) ?? null,
      capacitacion: textoONulo(r.application_training_at),
      clinicaId: textoONulo(r.merchant_id),
      clinica: textoONulo(r.merchant_name),
      conAccesos: r.merchant_has_access === true,
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
  resultado: Resultado | null
  canal: CanalDelLead | null
  antes: EstadoDelLead | null
  despues: EstadoDelLead | null
  /** La fecha de la visita de la que habla la línea. */
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
      resultado: unoDe(RESULTADOS, r.result) ?? null,
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
 * El día de Caracas de un instante: 'YYYY-MM-DD'. Una visita a las 9 de la
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

/** Ya no se trabaja: afiliado o no interesado. */
export function estaCerrado(l: Pick<Lead, 'estado'>): boolean {
  return l.estado === 'convertido' || l.estado === 'descartado'
}

/** Tiene una visita agendada (haya pasado su hora o no). */
export function tieneVisita(l: Pick<Lead, 'estado' | 'reunion'>): boolean {
  return l.estado === 'reunion' && l.reunion !== null
}

/**
 * Si su visita es la capacitación presencial que pidió en el formulario:
 * la misma hora. Si el equipo la cambia, vuelve a ser una visita.
 */
export function esCapacitacion(l: Pick<Lead, 'reunion' | 'capacitacion'>): boolean {
  return (
    l.reunion !== null &&
    l.capacitacion !== null &&
    new Date(l.reunion).getTime() === new Date(l.capacitacion).getTime()
  )
}

/**
 * En qué va su afiliación mientras le falta algo: la solicitud por revisar,
 * o la clínica aprobada sin sus accesos. Afiliarse (20261023140000) es que
 * su clínica tenga sus accesos.
 */
export function afiliacionEnCurso(
  l: Pick<Lead, 'solicitudEstado' | 'clinicaId' | 'conAccesos'>,
): 'solicitud_por_revisar' | 'falta_dar_accesos' | null {
  if (l.clinicaId !== null) return l.conAccesos ? null : 'falta_dar_accesos'
  return l.solicitudEstado === 'pending' ? 'solicitud_por_revisar' : null
}

export const ROTULO_AFILIACION_EN_CURSO: Record<NonNullable<ReturnType<typeof afiliacionEnCurso>>, string> = {
  solicitud_por_revisar: 'Solicitud por revisar',
  falta_dar_accesos: 'Aprobada: falta darle sus accesos',
}

/** Una visita agendada cuya hora ya pasó y nadie anotó cómo fue. */
export function visitaSinResultado(l: Pick<Lead, 'estado' | 'reunion'>, ahora: Date): boolean {
  return tieneVisita(l) && l.reunion !== null && new Date(l.reunion) < ahora
}

export type Pendiente = 'visita_pasada' | 'llamar_atrasado' | 'llamar_hoy' | 'visita_hoy' | 'sin_contactar'

export const PENDIENTE: Record<Pendiente, { label: string; tone: BadgeTone }> = {
  visita_pasada: { label: 'Anotar cómo fue la visita', tone: 'error' },
  llamar_atrasado: { label: 'Llamar, se pasó la fecha', tone: 'error' },
  visita_hoy: { label: 'Visita hoy', tone: 'warning' },
  llamar_hoy: { label: 'Llamar hoy', tone: 'warning' },
  sin_contactar: { label: 'Sin contactar', tone: 'warning' },
}

/**
 * Lo que hay que hacer hoy con un lead, o `null` si nada. `hoy` es el día de
 * Caracas 'YYYY-MM-DD'.
 */
export function pendienteDe(l: Lead, hoy: string, ahora: Date): Pendiente | null {
  if (estaCerrado(l)) return null
  if (visitaSinResultado(l, ahora)) return 'visita_pasada'
  if (l.volverEl !== null && l.volverEl < hoy) return 'llamar_atrasado'
  if (tieneVisita(l) && l.reunion !== null && diaDeCaracas(l.reunion) === hoy) return 'visita_hoy'
  if (l.volverEl === hoy) return 'llamar_hoy'
  if (l.estado === 'nuevo') return 'sin_contactar'
  return null
}

const PUESTO: Record<Pendiente, number> = {
  visita_pasada: 0,
  llamar_atrasado: 1,
  visita_hoy: 2,
  llamar_hoy: 3,
  sin_contactar: 4,
}

/**
 * El orden de trabajo: lo pendiente primero (lo atrasado, lo de hoy, los que
 * nadie ha llamado), después los abiertos por su próxima cita (visita o
 * llamada), y al final los cerrados, el más reciente primero.
 */
export function ordenarAgenda(leads: ReadonlyArray<Lead>, hoy: string, ahora: Date): Lead[] {
  const proxima = (l: Lead) => {
    const r = tieneVisita(l) && l.reunion ? diaDeCaracas(l.reunion) : null
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
 * ni los no interesados. `afiliados` y `descartados`: solo esos. `todos`: todo.
 */
export type QueSeVe = 'para_hoy' | 'abiertos' | 'afiliados' | 'descartados' | 'todos'

export const VALORES_QUE_SE_VE: readonly QueSeVe[] = ['para_hoy', 'abiertos', 'afiliados', 'descartados', 'todos']

function sinTildes(t: string): string {
  return t.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase().trim()
}

/**
 * Los leads que se ven. La búsqueda va por el nombre, el consultorio, la
 * especialidad y la dirección, y por los dígitos del teléfono: «0414 700»
 * encuentra «+584147000001».
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
    const textos = [l.nombre, l.consultorio, l.especialidad, l.direccion]
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

// ── Las cifras de arriba ───────────────────────────────────────────────────

export type CifrasDeLaAgenda = {
  /** Todos los médicos de la agenda. */
  apuntados: number
  /** Los que ya salieron de «Sin contactar». */
  contactados: number
  /** Los que tienen una visita agendada o ya la tuvieron. */
  citas: number
  /** De esas, las que todavía no han sido. */
  citasPorVenir: number
  /** Los afiliados. */
  activados: number
  /** De esos, los que ya tienen su clínica dada de alta. */
  conClinica: number
}

/**
 * Las tres cifras del embudo de la Agenda, sobre todos los médicos (no sobre
 * lo filtrado): cuántos se contactaron, cuántos llegaron a una visita y
 * cuántos se activaron. Una visita cancelada se borra del médico, así que no
 * cuenta como cita.
 */
export function cifrasDeLaAgenda(leads: ReadonlyArray<Lead>, ahora: Date): CifrasDeLaAgenda {
  const conCita = leads.filter((l) => l.reunion !== null || l.estado === 'reunion' || l.estado === 'visitado')
  const activados = leads.filter((l) => l.estado === 'convertido')
  return {
    apuntados: leads.length,
    contactados: leads.filter((l) => l.estado !== 'nuevo').length,
    citas: conCita.length,
    citasPorVenir: conCita.filter((l) => tieneVisita(l) && l.reunion !== null && new Date(l.reunion) >= ahora).length,
    activados: activados.length,
    conClinica: activados.filter((l) => l.clinicaId !== null).length,
  }
}

// ── El calendario ──────────────────────────────────────────────────────────

export type Cita = {
  lead: Lead
  /** 'visita': la visita agendada. 'llamada': el día de volver a llamar. */
  tipo: 'visita' | 'llamada'
  dia: string
  /** 'HH:MM' de la visita; las llamadas no tienen hora. */
  hora: string | null
  /** La visita es la capacitación que pidió en el formulario (`esCapacitacion`). */
  capacitacion: boolean
}

/**
 * Las citas de la agenda: las visitas (también las que ya pasaron, para ver
 * lo hecho) y los días de volver a llamar de los que siguen abiertos. En
 * orden de día y hora; las llamadas, detrás de las visitas de su día.
 */
export function citasDe(leads: ReadonlyArray<Lead>): Cita[] {
  const citas: Cita[] = []
  for (const l of leads) {
    if (l.reunion) {
      citas.push({
        lead: l,
        tipo: 'visita',
        dia: diaDeCaracas(l.reunion),
        hora: horaDeCaracas(l.reunion),
        capacitacion: esCapacitacion(l),
      })
    }
    if (l.volverEl && !estaCerrado(l)) {
      citas.push({ lead: l, tipo: 'llamada', dia: l.volverEl, hora: null, capacitacion: false })
    }
  }
  return citas.sort(
    (a, b) =>
      a.dia.localeCompare(b.dia) ||
      (a.tipo === b.tipo ? 0 : a.tipo === 'visita' ? -1 : 1) ||
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

const DIAS_DE_LA_SEMANA = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado']

/** 'Hoy', 'Mañana', 'Ayer' o 'Jueves 23 oct'. */
export function rotuloDelDia(dia: string, hoy: string): string {
  if (dia === hoy) return 'Hoy'
  if (dia === sumarDias(hoy, 1)) return 'Mañana'
  if (dia === sumarDias(hoy, -1)) return 'Ayer'
  const [y = 0, m = 1, d = 1] = dia.split('-').map(Number)
  const semana = DIAS_DE_LA_SEMANA[new Date(Date.UTC(y, m - 1, d)).getUTCDay()] ?? ''
  return `${semana.charAt(0).toUpperCase()}${semana.slice(1)} ${d} ${MESES_CORTOS[m - 1] ?? m}`
}

// ── Apuntar y corregir ─────────────────────────────────────────────────────

export type BorradorDeLead = {
  nombre: string
  consultorio: string
  especialidad: string
  telefono: string
  direccion: string
  notas: string
  responsableId: string
}

export function borradorDeLead(l?: Lead): BorradorDeLead {
  return {
    nombre: l?.nombre ?? '',
    consultorio: l?.consultorio ?? '',
    especialidad: l?.especialidad ?? '',
    telefono: l?.telefono ?? '',
    direccion: l?.direccion ?? '',
    notas: l?.notas ?? '',
    responsableId: l?.responsableId ?? '',
  }
}

/** Por qué no se puede guardar todavía, o `undefined` si se puede. */
export function motivoParaNoGuardar(b: BorradorDeLead): string | undefined {
  if (b.nombre.trim().length < 3) return 'Escribe el nombre del médico.'
  const digitos = b.telefono.replace(/\D/g, '')
  if (digitos && !/^(58)?0?\d{10}$/.test(digitos)) return 'El teléfono no parece venezolano.'
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
    address: o(b.direccion),
    notes: o(b.notas),
    assigned_to: b.responsableId || null,
  }
}

// ── Anotar una gestión ─────────────────────────────────────────────────────

export type BorradorDeGestion = {
  nota: string
  /** 'YYYY-MM-DD' y 'HH:MM' de la visita, en Caracas. */
  visitaDia: string
  visitaHora: string
  modo: ModoDeVisita
  lugar: string
  volverEl: string
}

export function borradorDeGestion(l: Lead): BorradorDeGestion {
  return {
    nota: '',
    visitaDia: '',
    visitaHora: l.reunion ? horaDeCaracas(l.reunion) : '10:00',
    modo: l.modo ?? 'presencial',
    lugar: l.lugar ?? l.direccion ?? '',
    volverEl: '',
  }
}

/** Por qué no se puede anotar todavía, o `undefined` si se puede. */
export function motivoParaNoAnotar(
  r: Resultado | null,
  b: BorradorDeGestion,
  l: Lead,
  hoy: string,
): string | undefined {
  if (r === null) return 'Elige qué pasó.'
  if (pideFechaDeVisita(r)) {
    if (!b.visitaDia || !b.visitaHora) return 'Pon el día y la hora de la visita.'
    if (b.visitaDia < hoy) return 'La fecha de la visita ya pasó.'
    if (
      r === 'visita_pospuesta' &&
      l.reunion !== null &&
      new Date(instanteDeCaracas(b.visitaDia, b.visitaHora)).getTime() === new Date(l.reunion).getTime()
    ) {
      return 'Pon la nueva fecha de la visita.'
    }
  }
  if (r === 'nota' && !b.nota.trim()) return 'Escribe la nota.'
  if (b.volverEl && b.volverEl < hoy) return 'La fecha para volver a llamar ya pasó.'
  if (b.nota.length > NOTA_MAXIMA) return `La nota no puede pasar de ${NOTA_MAXIMA} caracteres.`
  return undefined
}

/** Si al anotar se anula una visita que todavía no ha sido. */
export function anulaLaVisita(r: Resultado | null, l: Lead, ahora: Date): boolean {
  if (r === null || !tieneVisita(l) || l.reunion === null || new Date(l.reunion) <= ahora) return false
  if (r === 'visita_cancelada') return true
  const despues = estadoDelResultado(r, l)
  return despues !== 'reunion' && despues !== 'visitado' && despues !== 'convertido'
}

/** Los parámetros de `admin_log_doctor_lead_contact`. */
export function aParametros(leadId: string, r: Resultado, canal: CanalDelLead | null, b: BorradorDeGestion) {
  const conFecha = pideFechaDeVisita(r)
  return {
    p_lead_id: leadId,
    p_result: r,
    p_channel: canal ?? undefined,
    p_note: b.nota.trim() || undefined,
    p_meeting_at: conFecha ? instanteDeCaracas(b.visitaDia, b.visitaHora) : undefined,
    p_meeting_mode: conFecha ? b.modo : undefined,
    p_meeting_place: conFecha ? b.lugar.trim() || undefined : undefined,
    p_next_contact_on: pideVolver(r) ? b.volverEl || undefined : undefined,
  }
}
