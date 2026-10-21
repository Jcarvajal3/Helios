import type { BadgeTone } from '@/components/ui'
import type { MerchantRow, PaymentReportStatus } from '@/features/admin/api'
import type { ProfileStatus } from '@/features/admin/users'

// ═══════════════════════════════════════════════════════════════════════════
// Cómo se llama y de qué color va cada estado. Una tabla por tipo.
//
// Cada pantalla tenía su copia: el estado de un consumo vivía en `ops.ts` y en
// `consumos.ts` con nombres distintos, y la de `ops.ts` no sabía que existía
// «Revertido»; el tono de una persona estaba escrito cuatro veces. Un estado
// que se llama distinto en dos pantallas son dos estados para quien las lee.
//
// Módulo puro, sin React: se usa desde las funciones de datos y desde las
// pruebas. La insignia lista para pintar es `EstadoBadge`
// (components/admin/EstadoBadge.tsx).
// ═══════════════════════════════════════════════════════════════════════════

export type EstadoVisual = {
  /** Singular, como va en la insignia: «Confirmado». */
  label: string
  /** El mismo vocabulario que `Badge`: el estado se pinta igual en todo el panel. */
  tone: BadgeTone
  /** Plural, como va en un filtro: «Confirmados». */
  plural: string
  /** Qué significa, en una frase. Para el `InfoDot` de la columna. */
  que?: string
}

// ── Consumo ────────────────────────────────────────────────────────────────

export type EstadoConsumo = 'pending' | 'confirmed' | 'voided' | 'reverted'

/** En el orden en que se ofrecen en un filtro. Sirve también para `unoDe`. */
export const VALORES_ESTADO_CONSUMO: ReadonlyArray<EstadoConsumo> = [
  'confirmed',
  'pending',
  'voided',
  'reverted',
]

/**
 * Los cuatro estados de un consumo, sin ambigüedad.
 *
 * Un cobro sin usuario se pintaba como «Sin reclamar» tanto si el QR seguía
 * vivo como si ya había expirado. Son dos cosas distintas: una está pendiente
 * de pasar y la otra no va a pasar nunca.
 */
export const ESTADOS_CONSUMO: Record<EstadoConsumo, EstadoVisual & { que: string }> = {
  pending: {
    label: 'Pendiente',
    plural: 'Pendientes',
    tone: 'warning',
    que: 'Registrado y sin confirmar. En Helios un financiamiento nace confirmado: este estado solo aparece en datos heredados.',
  },
  confirmed: {
    label: 'Confirmado',
    plural: 'Confirmados',
    tone: 'success',
    que: 'La clínica lo registró. Existe la deuda, las cuotas y el asiento en el libro.',
  },
  voided: {
    label: 'Anulado',
    plural: 'Anulados',
    tone: 'error',
    que: 'Un pendiente que expiró o que alguien anuló. No generó deuda ni asiento.',
  },
  reverted: {
    label: 'Revertido',
    plural: 'Revertidos',
    tone: 'neutral',
    que: 'Estuvo confirmado y se deshizo desde el panel: se escribió el asiento contrario, se borraron las cuotas y se devolvió el cupo. El asiento original sigue en el libro.',
  },
}

// ── Pago reportado ─────────────────────────────────────────────────────────

export const VALORES_ESTADO_PAGO: ReadonlyArray<PaymentReportStatus> = [
  'reported',
  'in_review',
  'reconciled',
  'rejected',
  'duplicate',
]

/** El pago que se le registró (lo manda por WhatsApp). «Aprobado», nunca «conciliado». */
export const ESTADOS_PAGO_REPORTADO: Record<PaymentReportStatus, EstadoVisual> = {
  reported: { label: 'Pendiente', plural: 'Pendientes', tone: 'warning' },
  in_review: { label: 'En revisión', plural: 'En revisión', tone: 'warning' },
  reconciled: { label: 'Aprobado', plural: 'Aprobados', tone: 'success' },
  rejected: { label: 'Rechazado', plural: 'Rechazados', tone: 'error' },
  duplicate: { label: 'Duplicado', plural: 'Duplicados', tone: 'error' },
}

// ── Persona ────────────────────────────────────────────────────────────────

/**
 * Los que se ofrecen en un filtro. `pending_kyc` y `pending_pin` siguen en el
 * enum de la base (Ronda) pero un paciente de Helios nace activo: no se ofrecen.
 */
export const VALORES_ESTADO_PERSONA: ReadonlyArray<ProfileStatus> = [
  'active',
  'frozen',
  'suspended',
  'expelled',
]

/**
 * El estado de la cuenta. Congelado y suspendido comparten el ámbar: los dos
 * se levantan pagando; expulsado es rojo porque ya no.
 *
 * `suspended` se rotula «Suspendido» y no «Bloqueado»: el bloqueo es otra
 * cosa, el manual («Bloquear la cuenta»), que el estado automático no
 * levanta. Con el mismo nombre, una persona suspendida parecía bloqueada a
 * mano.
 */
export const ESTADOS_PERSONA: Record<ProfileStatus, EstadoVisual> = {
  pending_kyc: { label: 'Sin verificar', plural: 'Sin verificar', tone: 'neutral' },
  pending_pin: { label: 'Sin PIN', plural: 'Sin PIN', tone: 'neutral' },
  active: { label: 'Activo', plural: 'Activos', tone: 'success' },
  frozen: { label: 'Congelado', plural: 'Congelados', tone: 'warning' },
  suspended: { label: 'Suspendido', plural: 'Suspendidos', tone: 'warning' },
  expelled: { label: 'Expulsado', plural: 'Expulsados', tone: 'error' },
}

// ── Local ──────────────────────────────────────────────────────────────────

export type EstadoLocal = MerchantRow['status']

export const VALORES_ESTADO_LOCAL: ReadonlyArray<EstadoLocal> = ['active', 'paused', 'terminated']

/** Pausado se puede reactivar; terminado ya no, por eso va en rojo. */
export const ESTADOS_LOCAL: Record<EstadoLocal, EstadoVisual> = {
  active: { label: 'Activo', plural: 'Activos', tone: 'success' },
  paused: { label: 'Pausado', plural: 'Pausados', tone: 'warning' },
  terminated: { label: 'Terminado', plural: 'Terminados', tone: 'error' },
}

// ── Promesa de pago ────────────────────────────────────────────────────────

export type EstadoPromesa = 'vence_hoy' | 'pendiente' | 'cumplida' | 'rota'

/** El orden de los filtros: lo que hay que mirar hoy, primero. */
export const VALORES_ESTADO_PROMESA: ReadonlyArray<EstadoPromesa> = [
  'vence_hoy',
  'pendiente',
  'rota',
  'cumplida',
]

/**
 * Las reglas son las de `helios_promise_status`: se cumple con un pago
 * reportado (no rechazado ni duplicado) entre la gestión y el final del día
 * operativo prometido.
 */
export const ESTADOS_PROMESA: Record<EstadoPromesa, EstadoVisual & { que: string }> = {
  vence_hoy: {
    label: 'Vence hoy',
    plural: 'Vencen hoy',
    tone: 'warning',
    que: 'El día prometido es hoy y el paciente todavía no ha reportado el pago.',
  },
  pendiente: {
    label: 'Pendiente',
    plural: 'Pendientes',
    tone: 'neutral',
    que: 'El día prometido todavía no ha llegado.',
  },
  rota: {
    label: 'Rota',
    plural: 'Rotas',
    tone: 'error',
    que: 'Terminó el día operativo prometido sin un pago reportado.',
  },
  cumplida: {
    label: 'Cumplida',
    plural: 'Cumplidas',
    tone: 'success',
    que: 'El paciente reportó un pago entre la gestión y el final del día prometido. Si ese pago se rechaza deja de contar: vuelve a pendiente o, si el día ya pasó, a rota.',
  },
}

// ── Lectura con respaldo ───────────────────────────────────────────────────

/** Los tipos que conoce `estadoDe` y `EstadoBadge`. */
export type TipoEstado = 'consumo' | 'pago' | 'persona' | 'local' | 'promesa'

const TABLAS: Record<TipoEstado, Partial<Record<string, EstadoVisual>>> = {
  consumo: ESTADOS_CONSUMO,
  pago: ESTADOS_PAGO_REPORTADO,
  persona: ESTADOS_PERSONA,
  local: ESTADOS_LOCAL,
  promesa: ESTADOS_PROMESA,
}

/**
 * El estado con su etiqueta y su tono, o el nombre crudo en gris.
 *
 * El respaldo no sobra: las tablas se escriben a mano y la base puede
 * devolver un estado nuevo antes de que llegue aquí. Enseñar el nombre crudo
 * es feo pero es verdad; un hueco haría pensar que la fila no tiene estado.
 */
export function estadoDe(tipo: TipoEstado, valor: string): EstadoVisual {
  const tabla = TABLAS[tipo]
  // `hasOwn`: sin él, un estado llamado «toString» devolvería la función del
  // prototipo en vez del respaldo.
  const estado = Object.hasOwn(tabla, valor) ? tabla[valor] : undefined
  return estado ?? { label: valor, plural: valor, tone: 'neutral' }
}

export function estadoDeConsumo(status: string): EstadoVisual {
  return estadoDe('consumo', status)
}

export function estadoDePagoReportado(status: string): EstadoVisual {
  return estadoDe('pago', status)
}

export function estadoDePersona(status: string): EstadoVisual {
  return estadoDe('persona', status)
}

/**
 * Las opciones de un `Segmented` o un `Select` de estado, con «Todos» delante.
 * El valor vacío es «sin filtro», como en el resto de los filtros.
 */
export function opcionesDeEstado<T extends string>(
  valores: ReadonlyArray<T>,
  tabla: Record<T, EstadoVisual>,
  todos = 'Todos',
): Array<{ value: T | ''; label: string }> {
  return [{ value: '', label: todos }, ...valores.map((v) => ({ value: v, label: tabla[v].plural }))]
}
