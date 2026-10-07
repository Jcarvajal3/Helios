import { formatUsd, sumarDias } from '@/components/ui'
import {
  QUE_PASA_EN_EL_TRAMO,
  TRAMOS_VENCIDOS,
  rotuloDeTramo,
  tramoDe,
  tramosConRotulo,
} from '@/features/admin/tramos'
import type { CortesDeTramo, TramoVencido } from '@/features/admin/tramos'
import { unoDe } from '@/lib/busqueda'
import { CANALES, RESULTADOS } from './gestion'
import type { Canal, Resultado } from './gestion'
import { booleano, comoFila, comoLista, filaONula, numero, numeroONulo, texto, textoONulo, textos } from '@/lib/json'
import { PERFILES_DEUDOR, PRIORIDADES, ROTULO_PERFIL } from '@/features/admin/metricas/cobranza/perfiles'
import type { PerfilDeudor, Prioridad, UmbralesDePerfil } from '@/features/admin/metricas/cobranza/perfiles'
import { leerUmbralesDePerfil } from '@/features/admin/metricas/cobranza/deudores'
import { VALORES_ESTADO_PROMESA } from '@/features/admin/estados'
import type { EstadoPromesa } from '@/features/admin/estados'
import { leerHechos } from './senales'
import type { HechosDeDeudor } from './senales'

// ═══════════════════════════════════════════════════════════════════════════
// La cartera vencida: la fila de cada persona, qué filas entran en cada
// filtro y cuántas hay.
//
// Módulo puro. La lista, el caso y las pruebas usan las mismas reglas, así
// que el número de una pestaña y las filas que enseña no pueden discrepar.
// ═══════════════════════════════════════════════════════════════════════════

/** Cuántos días por delante mira la cartera: lo que vence esta semana. */
export const HORIZONTE_CARTERA = 7

/**
 * El horizonte de la Lista de Por cobrar: todo lo que queda por vencer, para
 * que su total sea el «Por cobrar» de Métricas › Global. Es el tope que
 * admite `admin_collections` (20260928211000).
 */
export const HORIZONTE_TODO = 3650

// ── La fila de `admin_collections` ─────────────────────────────────────────

/**
 * La agrupación de `admin_collections` por días de atraso. Aquí solo sirve
 * para distinguir «por vencer» de «vence hoy»; lo vencido se reparte por los
 * tramos de `tramos.ts`, en los filtros y en la plantilla de WhatsApp.
 */
export type CollectionBucket = 'por_vencer' | 'vence_hoy' | 'congelado' | 'baja_nivel' | 'expulsion'

const BUCKETS: readonly CollectionBucket[] = [
  'por_vencer',
  'vence_hoy',
  'congelado',
  'baja_nivel',
  'expulsion',
]

/**
 * Las dos partes de una deuda: el consumo (financed, sin el fee) y el service
 * fee con su IVA (payable − financed). Una deuda se enseña siempre con ellas.
 */
export type PartesDeDeuda = { financedUsd: number; feeUsd: number }

/** «consumo €37,00 · fee €8,20»: el desglose donde no cabe más, bajo un importe. */
export function desgloseCorto(p: PartesDeDeuda): string {
  return `financiamiento ${formatUsd(p.financedUsd)} · fee ${formatUsd(p.feeUsd)}`
}

/** Una persona de la cartera. Los montos son PAYABLE: deuda, con el service fee dentro. */
export type CollectionRow = {
  userId: string
  fullName: string | null
  phone: string | null
  /** El estado de la cuenta, tal como lo dejó el estado automático. */
  status: string
  level: number
  bucket: CollectionBucket
  openUsd: number
  overdueUsd: number
  upcomingUsd: number
  /**
   * Las partes de `overdueUsd` y de `upcomingUsd`. `null` si la base no las
   * manda: las trae la cola (`admin_collections`), no el caso de una persona.
   */
  overdueDesglose: PartesDeDeuda | null
  upcomingDesglose: PartesDeDeuda | null
  /**
   * De `overdueUsd`, lo dado por perdido, y su consumo. La cola lo sigue
   * cobrando, pero no es «por cobrar» en Métricas. 0 si la base no lo manda.
   */
  lostUsd: number
  lostFinancedUsd: number
  /**
   * Lo vencido y lo por vencer dichos en la moneda de cada orden («€56,96 +
   * $2») y sus bolívares de hoy, cada parte a la tasa BCV de su moneda
   * (2026-10-07). Es lo que se le pide al paciente. `null` si la base no lo
   * manda o no hay tasa.
   */
  overdueText: string | null
  overdueVesHoy: number | null
  upcomingText: string | null
  upcomingVesHoy: number | null
  daysOverdue: number
  nextDueDate: string
  installmentCount: number
  merchants: string[]
  lastPaymentAt: string | null
  /**
   * La última gestión, si la hubo. Existe para que nadie llame dos veces a la
   * misma persona el mismo día.
   */
  lastContactAt: string | null
  lastContactChannel: Canal | null
  lastContactBy: string | null
  lastContactNote: string | null
  lastContactOutcome: Resultado | null
  /** 'YYYY-MM-DD': cuándo volver a llamar, según la última gestión. */
  lastContactNextActionOn: string | null
  /** La de la última gestión que traía promesa: un «no contesta» no la borra. */
  promiseDate: string | null
  promiseStatus: EstadoPromesa | null
  /** Si se habló con ella DESPUÉS de que se le venciera lo más viejo. */
  contactedSinceDue: boolean
  /**
   * Su perfil de deudor (`metricas.perfil_deudor`, el mismo de Métricas ›
   * Cobranza y riesgo). `null`: debe algo pero no encaja en ninguno (por
   * vencer y sin señal, o con la deuda ya dada por perdida).
   */
  perfil: PerfilDeudor | null
  prioridad: Prioridad | null
  /** El orden de la cola por prioridad: 1 es a quien se llama primero. */
  orden: number | null
  /** Por qué tiene ese perfil, en una línea con cifras. */
  motivo: string | null
  /** Lo que hizo: los hechos de los que salen sus señales (`senales.ts`). */
  senales: HechosDeDeudor
}

/**
 * La cola, con los días de baja y expulsión que usó la base. Vienen fuera de
 * las filas para poder pintarse cuando no hay nadie en la cola.
 */
export type CollectionQueue = {
  demotionDays: number
  expulsionDays: number
  /** Los umbrales con que la base puso los perfiles de deudor. */
  umbralesDePerfil: UmbralesDePerfil
  rows: CollectionRow[]
}

/** Las dos partes, o `null` si la base no manda el consumo (una respuesta de antes). */
function leerPartes(financed: unknown, fee: unknown): PartesDeDeuda | null {
  const f = numeroONulo(financed)
  return f === null ? null : { financedUsd: f, feeUsd: numero(fee) }
}

export function leerFilaDeCartera(raw: unknown): CollectionRow {
  const r = comoFila(raw)
  const dias = numero(r.days_overdue)
  return {
    userId: texto(r.user_id),
    fullName: textoONulo(r.full_name),
    phone: textoONulo(r.phone_e164),
    status: texto(r.status),
    level: numero(r.level),
    // Un nombre que no se conoce no puede elegir plantilla: se deduce del atraso.
    bucket: unoDe(BUCKETS, r.bucket) ?? (dias > 0 ? 'congelado' : 'por_vencer'),
    openUsd: numero(r.open_usd),
    overdueUsd: numero(r.overdue_usd),
    upcomingUsd: numero(r.upcoming_usd),
    overdueDesglose: leerPartes(r.overdue_financed_usd, r.overdue_fee_usd),
    upcomingDesglose: leerPartes(r.upcoming_financed_usd, r.upcoming_fee_usd),
    lostUsd: numero(r.lost_usd),
    lostFinancedUsd: numero(r.lost_financed_usd),
    overdueText: textoONulo(r.overdue_text),
    overdueVesHoy: numeroONulo(r.overdue_ves_hoy),
    upcomingText: textoONulo(r.upcoming_text),
    upcomingVesHoy: numeroONulo(r.upcoming_ves_hoy),
    daysOverdue: dias,
    nextDueDate: texto(r.next_due_date),
    installmentCount: numero(r.installment_count),
    merchants: textos(r.merchants),
    lastPaymentAt: textoONulo(r.last_payment_at),
    lastContactAt: textoONulo(r.last_contact_at),
    lastContactChannel: unoDe(CANALES, r.last_contact_channel) ?? null,
    lastContactBy: textoONulo(r.last_contact_by),
    lastContactNote: textoONulo(r.last_contact_note),
    lastContactOutcome: unoDe(RESULTADOS, r.last_contact_outcome) ?? null,
    lastContactNextActionOn: textoONulo(r.last_contact_next_action_on),
    promiseDate: textoONulo(r.promise_date),
    promiseStatus: unoDe(VALORES_ESTADO_PROMESA, r.promise_status) ?? null,
    contactedSinceDue: booleano(r.contacted_since_due),
    perfil: unoDe(PERFILES_DEUDOR, r.perfil) ?? null,
    prioridad: unoDe(PRIORIDADES, r.prioridad) ?? null,
    orden: numeroONulo(r.orden),
    motivo: textoONulo(r.motivo),
    senales: leerHechos(r.senales),
  }
}

/**
 * El caso de una persona (`admin_collection_case`): su fila de la cartera, o
 * `null` si no está en ella.
 *
 * La base manda la fila también a quien no está en la cartera, con
 * `bucket: 'al_dia'`, montos en cero y su última gestión. Aquí esa fila es
 * `null`, lo mismo que cuando no aparecía en `admin_collections`: no hay
 * plantilla de cobro para ella y la ficha dice que no debe nada esta semana.
 * También es `null` una cuenta de prueba, que la base no devuelve.
 */
export function leerCasoDeCobranza(raw: unknown): CollectionRow | null {
  const r = filaONula(raw)
  if (r === null || r.bucket === 'al_dia') return null
  return leerFilaDeCartera(r)
}

/** La respuesta entera de `admin_collections`. */
export function leerCartera(raw: unknown): CollectionQueue {
  const d = comoFila(raw)
  return {
    demotionDays: numero(d.demotion_days),
    expulsionDays: numero(d.expulsion_days),
    umbralesDePerfil: leerUmbralesDePerfil(d.umbrales_perfil),
    rows: comoLista(d.rows).map(leerFilaDeCartera),
  }
}

// ── Filtros ────────────────────────────────────────────────────────────────

/**
 * Los filtros de la lista, por orden de vencimiento: Todos · Plazo vigente ·
 * Vence mañana · Vence hoy · Plazo vencido.
 *
 * - `por_vencer`, `vence_hoy` y `plazo_vencido` parten la cola sin solaparse:
 *   cada usuario está en uno y solo uno, así que suman «Todos».
 * - `recordar_hoy` («Vence mañana») es una parte de `por_vencer`.
 * - Los tramos y `sin_contactar` son partes de `plazo_vencido`. `sin_contactar`
 *   ya no es un botón: la URL lo sigue aceptando (Inicio y el catálogo
 *   empiezan la cola por ahí) y se pinta como una etiqueta que se quita.
 *
 * Las claves de la URL no cambian de nombre aunque cambie el rótulo: los
 * enlaces guardados siguen llegando.
 */
export type FiltroCartera =
  | 'todos'
  | 'por_vencer'
  | 'recordar_hoy'
  | 'vence_hoy'
  | 'plazo_vencido'
  | 'sin_contactar'
  | TramoVencido

/** Todos los que acepta la URL. */
export const FILTROS_CARTERA: readonly FiltroCartera[] = [
  'todos',
  'por_vencer',
  'recordar_hoy',
  'vence_hoy',
  'plazo_vencido',
  'sin_contactar',
  ...TRAMOS_VENCIDOS,
]

const ROTULO_FIJO: Record<Exclude<FiltroCartera, TramoVencido>, string> = {
  todos: 'Todos',
  por_vencer: 'Plazo vigente',
  recordar_hoy: 'Vence mañana',
  vence_hoy: 'Vence hoy',
  plazo_vencido: 'Plazo vencido',
  sin_contactar: 'Vencidos sin contactar',
}

/** Qué cuenta cada filtro, en una frase: la ayuda del filtro activo. */
const QUE_ES_FIJO: Record<Exclude<FiltroCartera, TramoVencido>, string> = {
  todos: `Pacientes con alguna cuota sin pagar vencida o que vence en los próximos ${HORIZONTE_CARTERA} días.`,
  por_vencer: `Pacientes sin nada vencido ni que venza hoy, con alguna cuota sin pagar que vence en los próximos ${HORIZONTE_CARTERA} días.`,
  recordar_hoy: 'Pacientes sin nada vencido cuya próxima cuota sin pagar vence mañana (día operativo).',
  vence_hoy: 'Pacientes sin nada vencido con alguna cuota sin pagar que vence hoy (día operativo).',
  plazo_vencido:
    'Pacientes con alguna cuota vencida sin pagar, en cualquier tramo de atraso e incluida la deuda dada por perdida.',
  sin_contactar:
    'Pacientes con alguna cuota vencida sin pagar y sin ninguna gestión anotada desde el vencimiento de su cuota pendiente más antigua.',
}

function esTramo(f: FiltroCartera): f is TramoVencido {
  return TRAMOS_VENCIDOS.some((t) => t === f)
}

/** Lo que una fila tiene que traer para poder filtrarla. */
export type FilaCartera = Pick<
  CollectionRow,
  'bucket' | 'overdueUsd' | 'daysOverdue' | 'nextDueDate' | 'contactedSinceDue'
>

export type ContextoCartera = {
  /** Día operativo de hoy. */
  hoy: string
  /** Los cortes de los tramos, o `null` si los parámetros no se han leído. */
  cortes: CortesDeTramo | null
}

/** El tramo de atraso de una fila, o `null` si no debe nada vencido. */
export function tramoDeFila(
  fila: Pick<CollectionRow, 'daysOverdue'>,
  cortes: CortesDeTramo,
): TramoVencido | null {
  const t = tramoDe(fila.daysOverdue, cortes)
  return t === 'al_dia' ? null : t
}

export function pasaElFiltro(fila: FilaCartera, filtro: FiltroCartera, ctx: ContextoCartera): boolean {
  switch (filtro) {
    case 'todos':
      return true
    case 'por_vencer':
      return fila.bucket === 'por_vencer'
    case 'recordar_hoy':
      return fila.bucket === 'por_vencer' && fila.nextDueDate === sumarDias(ctx.hoy, 1)
    case 'vence_hoy':
      return fila.bucket === 'vence_hoy'
    case 'plazo_vencido':
      return fila.overdueUsd > 0
    case 'sin_contactar':
      return fila.overdueUsd > 0 && !fila.contactedSinceDue
    default:
      return ctx.cortes !== null && tramoDeFila(fila, ctx.cortes) === filtro
  }
}

/** Cuántas filas caen en cada filtro. Un tramo sin cortes cuenta 0 y no se pinta. */
export function recuentoPorFiltro(
  filas: ReadonlyArray<FilaCartera>,
  ctx: ContextoCartera,
): Record<FiltroCartera, number> {
  const recuento: Record<FiltroCartera, number> = {
    todos: 0,
    por_vencer: 0,
    recordar_hoy: 0,
    vence_hoy: 0,
    plazo_vencido: 0,
    sin_contactar: 0,
    t1: 0,
    t2: 0,
    t3: 0,
    t4: 0,
    t5: 0,
  }
  for (const fila of filas) {
    for (const f of FILTROS_CARTERA) {
      if (pasaElFiltro(fila, f, ctx)) recuento[f] += 1
    }
  }
  return recuento
}

// ── El filtro en pantalla: «Vencimiento», «Tramo» y una etiqueta ───────────
//
// La URL guarda un solo filtro (`?tramo=`), así que los enlaces de Inicio,
// del catálogo y los guardados siguen llegando igual. En pantalla se reparte:
// el Segmented «Vencimiento» con los cinco plazos, el desplegable «Tramo» con
// los días de atraso y, si toca, la etiqueta «Vencidos sin contactar». Un
// tramo o la etiqueta son partes de «Plazo vencido»: con ellos, el Segmented
// marca Plazo vencido.

/** Los cinco botones del Segmented «Vencimiento», en su orden. */
export type FiltroDePlazo = Exclude<FiltroCartera, TramoVencido | 'sin_contactar'>

export const FILTROS_DE_PLAZO: readonly FiltroDePlazo[] = [
  'todos',
  'por_vencer',
  'recordar_hoy',
  'vence_hoy',
  'plazo_vencido',
]

/** El valor de «Tramo» cuando no se acota por tramo. */
export const CUALQUIER_TRAMO = 'cualquiera'
export type OpcionTramo = TramoVencido | typeof CUALQUIER_TRAMO

/** El filtro de la URL repartido en lo que se ve. */
export function partirFiltro(filtro: FiltroCartera): {
  plazo: FiltroDePlazo
  tramo: OpcionTramo
  sinContactar: boolean
} {
  if (esTramo(filtro)) return { plazo: 'plazo_vencido', tramo: filtro, sinContactar: false }
  if (filtro === 'sin_contactar') return { plazo: 'plazo_vencido', tramo: CUALQUIER_TRAMO, sinContactar: true }
  return { plazo: filtro, tramo: CUALQUIER_TRAMO, sinContactar: false }
}

/**
 * Lo que se escribe en la URL al elegir un tramo. «Todos los tramos» solo se
 * elige viniendo de un tramo, es decir, dentro de Plazo vencido: vuelve a él.
 */
export function filtroDeTramo(tramo: OpcionTramo): FiltroCartera {
  return tramo === CUALQUIER_TRAMO ? 'plazo_vencido' : tramo
}

/** Quitar la etiqueta «Vencidos sin contactar» deja Plazo vencido entero. */
export const FILTRO_SIN_LA_ETIQUETA: FiltroCartera = 'plazo_vencido'

/** Las opciones de «Vencimiento», con su recuento. */
export function opcionesDePlazo(
  recuento: Record<FiltroCartera, number>,
): Array<{ value: FiltroDePlazo; label: string }> {
  return FILTROS_DE_PLAZO.map((f) => ({ value: f, label: `${ROTULO_FIJO[f]} · ${recuento[f]}` }))
}

/**
 * Las opciones de «Tramo», con su recuento. Los tramos solo salen cuando se
 * conocen sus cortes, y un tramo vacío (parámetros cruzados) no se ofrece.
 */
export function opcionesDeTramo(
  recuento: Record<FiltroCartera, number>,
  cortes: CortesDeTramo | null,
): Array<{ value: OpcionTramo; label: string }> {
  const cualquiera: { value: OpcionTramo; label: string } = {
    value: CUALQUIER_TRAMO,
    label: 'Todos los tramos',
  }
  if (!cortes) return [cualquiera]
  const tramos = tramosConRotulo(cortes).map(({ tramo, rotulo }) => ({
    value: tramo,
    label: `${rotulo} · ${recuento[tramo]}`,
  }))
  return [cualquiera, ...tramos]
}

/** El nombre del filtro sin recuento, para un título o un enlace. */
export function rotuloDeFiltro(filtro: FiltroCartera, cortes: CortesDeTramo | null): string {
  if (!esTramo(filtro)) return ROTULO_FIJO[filtro]
  return cortes ? `Plazo vencido, ${rotuloDeTramo(filtro, cortes)} de atraso` : 'Tramo de atraso'
}

/**
 * La ayuda del filtro activo: qué cuenta. La de un tramo dice sus días (sin
 * cortes no se inventan) y lo que le pasa a quien está en él.
 */
export function queEsElFiltro(filtro: FiltroCartera, cortes: CortesDeTramo | null): string {
  if (!esTramo(filtro)) return QUE_ES_FIJO[filtro]
  const dias = cortes ? rotuloDeTramo(filtro, cortes).toLowerCase() : 'los días de este tramo'
  return `Pacientes cuya cuota vencida más antigua lleva ${dias} de atraso. ${QUE_PASA_EN_EL_TRAMO[filtro]}`
}

export function esFiltroDeTramo(filtro: FiltroCartera): filtro is TramoVencido {
  return esTramo(filtro)
}

/** Las cifras de lo que se ve: van en la línea de resumen de la tabla. */
export function sumasDeCartera(
  filas: ReadonlyArray<
    Pick<CollectionRow, 'overdueUsd' | 'upcomingUsd'> &
      Partial<Pick<CollectionRow, 'overdueDesglose' | 'upcomingDesglose'>>
  >,
): {
  vencidoUsd: number
  personasConVencido: number
  porVencerUsd: number
  /** Las partes de cada suma; `null` si a alguna fila le faltan (no se inventan). */
  vencidoDesglose: PartesDeDeuda | null
  porVencerDesglose: PartesDeDeuda | null
} {
  return {
    vencidoUsd: filas.reduce((s, f) => s + f.overdueUsd, 0),
    personasConVencido: filas.filter((f) => f.overdueUsd > 0).length,
    porVencerUsd: filas.reduce((s, f) => s + f.upcomingUsd, 0),
    vencidoDesglose: sumarPartes(filas.map((f) => f.overdueDesglose ?? null)),
    porVencerDesglose: sumarPartes(filas.map((f) => f.upcomingDesglose ?? null)),
  }
}

/** Lo vencido de una fila sin lo dado por perdido, con sus dos partes. */
export function vencidoCobrable(
  f: Pick<CollectionRow, 'overdueUsd' | 'overdueDesglose' | 'lostUsd' | 'lostFinancedUsd'>,
): { usd: number; partes: PartesDeDeuda | null } {
  const usd = Math.max(f.overdueUsd - f.lostUsd, 0)
  const partes = f.overdueDesglose && {
    financedUsd: Math.max(f.overdueDesglose.financedUsd - f.lostFinancedUsd, 0),
    feeUsd: Math.max(f.overdueDesglose.feeUsd - (f.lostUsd - f.lostFinancedUsd), 0),
  }
  return { usd, partes }
}

/**
 * Lo que Métricas › Global llama «Por cobrar»: lo vencido sin lo perdido más
 * lo por vencer, y cuánta gente lo debe. Lo perdido va aparte, con su gente.
 * Con la cola entera (`HORIZONTE_TODO`), es la misma cifra que Global.
 */
export function totalPorCobrar(
  filas: ReadonlyArray<
    Pick<CollectionRow, 'overdueUsd' | 'overdueDesglose' | 'upcomingUsd' | 'upcomingDesglose' | 'lostUsd' | 'lostFinancedUsd'>
  >,
): { usd: number; partes: PartesDeDeuda | null; personas: number; perdido: { usd: number; personas: number } } {
  const vencidos = filas.map(vencidoCobrable)
  const partes = sumarPartes([
    ...vencidos.map((v) => (v.usd > 0 ? v.partes : { financedUsd: 0, feeUsd: 0 })),
    ...filas.map((f) => (f.upcomingUsd > 0 ? f.upcomingDesglose : { financedUsd: 0, feeUsd: 0 })),
  ])
  return {
    usd: vencidos.reduce((a, v) => a + v.usd, 0) + filas.reduce((a, f) => a + f.upcomingUsd, 0),
    partes,
    personas: filas.filter((f, i) => vencidos[i].usd > 0 || f.upcomingUsd > 0).length,
    perdido: {
      usd: filas.reduce((a, f) => a + f.lostUsd, 0),
      personas: filas.filter((f) => f.lostUsd > 0).length,
    },
  }
}

/** Suma partes a partes; `null` si falta alguna: medio desglose mentiría. */
function sumarPartes(partes: ReadonlyArray<PartesDeDeuda | null>): PartesDeDeuda | null {
  let financedUsd = 0
  let feeUsd = 0
  for (const p of partes) {
    if (p === null) return null
    financedUsd += p.financedUsd
    feeUsd += p.feeUsd
  }
  return { financedUsd, feeUsd }
}

/**
 * La próxima acción de la última gestión, y si ya toca.
 *
 * `atrasada` es que el día pasó y nadie ha vuelto a anotar nada: la próxima
 * acción siempre es la de la ÚLTIMA gestión, así que una llamada nueva la
 * reemplaza.
 */
export function proximaAccion(
  fecha: string | null,
  hoy: string,
): { fecha: string; cuando: 'atrasada' | 'hoy' | 'mas_adelante' } | null {
  if (!fecha) return null
  if (fecha < hoy) return { fecha, cuando: 'atrasada' }
  if (fecha === hoy) return { fecha, cuando: 'hoy' }
  return { fecha, cuando: 'mas_adelante' }
}

/** Los ids en orden, sin repetir: una persona con dos promesas es un caso. */
export function idsSinRepetir(ids: ReadonlyArray<string>): string[] {
  return [...new Set(ids)]
}

// ── El perfil de deudor ────────────────────────────────────────────────────
//
// Un filtro más, aparte de «Qué hacer» y «Tramo», que se suma a ellos: la
// URL lo guarda en `?perfil=`. El perfil lo pone la base; aquí solo se filtra
// y se ordena por él.

/** El valor de «Perfil» cuando no se acota por perfil. */
export const CUALQUIER_PERFIL = 'cualquiera'
export type OpcionPerfil = PerfilDeudor | typeof CUALQUIER_PERFIL

export function pasaElPerfil(fila: Pick<CollectionRow, 'perfil'>, perfil: PerfilDeudor | undefined): boolean {
  return perfil === undefined || fila.perfil === perfil
}

/** Cuántas filas hay de cada perfil (las que no tienen perfil no cuentan en ninguno). */
export function recuentoPorPerfil(filas: ReadonlyArray<Pick<CollectionRow, 'perfil'>>): Record<PerfilDeudor, number> {
  const recuento: Record<PerfilDeudor, number> = {
    nunca_ha_pagado: 0,
    promesa_rota: 0,
    sin_respuesta: 0,
    reincidente: 0,
    paga_tarde_pero_paga: 0,
    se_le_paso: 0,
    vigilar: 0,
  }
  for (const f of filas) if (f.perfil) recuento[f.perfil] += 1
  return recuento
}

/** Las opciones de «Perfil», con su recuento, en el orden en que se trabajan. */
export function opcionesDePerfil(recuento: Record<PerfilDeudor, number>): Array<{ value: OpcionPerfil; label: string }> {
  return [
    { value: CUALQUIER_PERFIL, label: 'Todos los perfiles' },
    ...PERFILES_DEUDOR.map((p) => ({ value: p, label: `${ROTULO_PERFIL[p]} · ${recuento[p]}` })),
  ]
}

/** El orden por prioridad: el de la base, y quien no tiene perfil al final. */
export function ordenPorPrioridad(fila: Pick<CollectionRow, 'orden'>): number | null {
  return fila.orden
}
