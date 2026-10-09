import { rotuloDePestana } from '@/features/admin/ajustesNavegacion'
import type { PestanaAjustes } from '@/features/admin/ajustesNavegacion'
import type { Destino } from '@/features/admin/catalogo/tipos'
import type { AuditEntry } from '@/features/admin/ops'

// ═══════════════════════════════════════════════════════════════════════════
// A qué apunta cada línea de la bitácora.
//
// Una línea que dice «aprobó un pago reportado» y no deja abrir el pago sirve
// de poco: para saber cuál era había que copiar el id y buscarlo. Aquí se
// decide, por el código de la acción, qué es su `target_id` (una persona, un
// local, un consumo, un pago…) y, cuando el destino va en el `detail`, se saca
// de ahí. Lo que cambió un ajuste apunta a su sección de Ajustes.
//
// Qué es el `target_id` de cada código sale de los `audit.log(...)` de las
// migraciones, no de adivinarlo por el nombre: `kyc.approved` apunta a la
// verificación y no a la persona, `deposit.assigned` a la línea del extracto.
// ═══════════════════════════════════════════════════════════════════════════

/** Las pantallas sin ficha a las que puede llevar una línea, con sus parámetros. */
export type PantallaDeBitacora = Extract<
  Destino,
  { to: '/admin/avisos' | '/admin/cobros' }
>

/** Las fichas: una entidad concreta, por su id. */
export type FichaDeBitacora =
  | 'persona'
  | 'local'
  | 'consumo'
  | 'pago'
  | 'transferencia'
  | 'pagos-del-local'

export type DestinoBitacora =
  | {
      que: FichaDeBitacora
      id: string
      /** El nombre de la persona o del local, si la acción lo guardó. */
      nombre: string | null
      /** La clave del `detail` de donde salió el nombre, para no repetirlo. */
      claveNombre: string | null
    }
  | { que: 'ajustes'; tab: PestanaAjustes }
  | { que: 'pantalla'; destino: PantallaDeBitacora; titulo: string }

/** Qué es el `target_id` de cada acción que apunta a una ficha. */
const FICHA_DEL_TARGET: Record<string, FichaDeBitacora | undefined> = {
  'payment.reconciled': 'pago',
  'payment.rejected': 'pago',
  'payment.flagged': 'pago',
  'payment.statement_linked': 'pago',

  'charge.void': 'consumo',
  'charge.reverted': 'consumo',

  'user.set_status': 'persona',
  'user.set_level': 'persona',
  'user.set_blacklist': 'persona',
  'user.blocked': 'persona',
  'user.unblocked': 'persona',
  'collection.contact': 'persona',
  'kyc.retry_requested': 'persona',
  'risk_alert.reviewed': 'persona',
  'waitlist.enrolled': 'persona',
  'waitlist.released': 'persona',

  'merchant.created': 'local',
  'merchant.status_changed': 'local',
  'merchant.set_profile': 'local',
  'merchant.set_owner': 'local',
  'merchant.payout_account_set': 'local',
  'merchant_application.approved': 'local',
  'merchant.set_terms': 'local',
  'merchant.terms_changed': 'local',
  'merchant.staff_added': 'local',
  'merchant.staff_welcome_sent': 'local',
  'merchant.staff_updated': 'local',
  'merchant.staff_removed': 'local',
  'merchant.staff_password_reset': 'local',
  'vault.configured': 'local',
  'vault.topup': 'local',
  'waitlist.released_batch': 'local',

  // El `target_id` es el local; la transferencia concreta va en el detail
  // (`payout_id`) desde 20260911191000, y se prefiere cuando está.
  'merchant.payout': 'pagos-del-local',
  'merchant.paid': 'pagos-del-local',
}

/**
 * Acciones cuyo `target_id` no es la persona (la línea del extracto, el cargo
 * condonado, la solicitud), pero que guardan a la persona en `detail.user_id`.
 */
const PERSONA_EN_EL_DETALLE: ReadonlySet<string> = new Set([
  'late_fee.waived',
  'deposit.assigned',
  'account_deletion.completed',
  'account_deletion.rejected',
])

/** Lo que cambió un ajuste: su sección. */
const SECCION_DE_AJUSTES: Record<string, PestanaAjustes | undefined> = {
  'parameter.set': 'parametros',
  'level.configure': 'niveles',
  'holiday.set': 'feriados',
  'holiday.removed': 'feriados',
  'fx_rate.manual': 'tasa',
  'fx_rate.sync': 'tasa',
  'payment_destination.set': 'cobro',
  'terms.published': 'terminos',
  'maintenance.on': 'mantenimiento',
  'maintenance.off': 'mantenimiento',
  'platform_admin.set': 'equipo',
  'platform_admin.revoke': 'equipo',
  'platform_admin.restore': 'equipo',
  'security.require_mfa': 'seguridad',
}

/** Lo que vive en una pantalla sin ficha propia. */
const PANTALLA_DE_LA_ACCION: Record<string, { destino: PantallaDeBitacora; titulo: string } | undefined> =
  {
    'collection_template.set': {
      destino: { to: '/admin/avisos', search: { vista: 'plantillas' } },
      titulo: 'Plantillas de WhatsApp',
    },
    'collection_template.reset': {
      destino: { to: '/admin/avisos', search: { vista: 'plantillas' } },
      titulo: 'Plantillas de WhatsApp',
    },
    'deposit.discarded': {
      destino: { to: '/admin/cobros', search: { vista: 'abonos', abonos: 'descartados' } },
      titulo: 'Abonos descartados',
    },
    'statement.import': {
      destino: { to: '/admin/cobros', search: { vista: 'abonos' } },
      titulo: 'Abonos sin dueño',
    },
    'statement.imported': {
      destino: { to: '/admin/cobros', search: { vista: 'abonos' } },
      titulo: 'Abonos sin dueño',
    },
  }

/** Las claves del `detail` que pueden llevar el nombre, por orden de preferencia. */
const CLAVES_NOMBRE = ['full_name', 'merchant_name', 'name'] as const

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function comoUuid(v: unknown): string | null {
  return typeof v === 'string' && UUID.test(v) ? v.toLowerCase() : null
}

function nombreDe(detail: Record<string, unknown>): { nombre: string | null; clave: string | null } {
  for (const clave of CLAVES_NOMBRE) {
    const v = detail[clave]
    if (typeof v === 'string' && v.trim() !== '') return { nombre: v.trim(), clave }
  }
  return { nombre: null, clave: null }
}

function ficha(
  que: FichaDeBitacora,
  id: string,
  detail: Record<string, unknown>,
): DestinoBitacora {
  // Solo una persona o un local se nombran en el enlace. El nombre que guarda
  // un consumo revertido es el de quien consumió, y ese sigue en los datos.
  if (que !== 'persona' && que !== 'local') return { que, id, nombre: null, claveNombre: null }
  const { nombre, clave } = nombreDe(detail)
  return { que, id, nombre, claveNombre: clave }
}

/**
 * Lo que afectó una línea de la bitácora, o `null` si no hay adónde llevar.
 *
 * Un `target_id` que no es un uuid no se sigue: un enlace a una ficha que no
 * existe es peor que no enlazar.
 */
export function destinoDe(
  entrada: Pick<AuditEntry, 'action' | 'targetId' | 'detail'>,
): DestinoBitacora | null {
  const { action, detail } = entrada
  const target = comoUuid(entrada.targetId)

  // La transferencia concreta, si la línea la guardó.
  if (action === 'merchant.payout') {
    const pago = comoUuid(detail.payout_id)
    if (pago) return ficha('transferencia', pago, detail)
  }

  // `account.set_test` marca personas y locales: lo dice `detail.kind`.
  if (action === 'account.set_test' && target) {
    if (detail.kind === 'user') return ficha('persona', target, detail)
    if (detail.kind === 'merchant') return ficha('local', target, detail)
    return null
  }

  if (PERSONA_EN_EL_DETALLE.has(action)) {
    const persona = comoUuid(detail.user_id)
    return persona ? ficha('persona', persona, detail) : null
  }

  const que = FICHA_DEL_TARGET[action]
  if (que) return target ? ficha(que, target, detail) : null

  const tab = SECCION_DE_AJUSTES[action]
  if (tab) return { que: 'ajustes', tab }

  const pantalla = PANTALLA_DE_LA_ACCION[action]
  if (pantalla) return { que: 'pantalla', ...pantalla }

  return null
}

const ROTULO_DE_FICHA: Record<FichaDeBitacora, string> = {
  persona: 'Ver el paciente',
  local: 'Ver la clínica',
  consumo: 'Ver el financiamiento',
  pago: 'Ver el pago reportado',
  transferencia: 'Ver la transferencia',
  'pagos-del-local': 'Ver los pagos a la clínica',
}

/**
 * El texto del enlace: el nombre, si lo hay, porque todo nombre de persona o
 * local enlaza a su ficha; si no, qué se va a abrir.
 */
export function rotuloDeDestino(destino: DestinoBitacora): string {
  if (destino.que === 'ajustes') return `Ajustes › ${rotuloDePestana(destino.tab)}`
  if (destino.que === 'pantalla') return destino.titulo
  return destino.nombre ?? ROTULO_DE_FICHA[destino.que]
}
