import { booleano, comoFila, comoLista, filas, numero, numeroONulo, texto, textoONulo } from '@/lib/json'
import { unoDe } from '@/lib/busqueda'
import { supabase } from '@/lib/supabase'
import { VALORES_ESTADO_CONSUMO } from '@/features/admin/estados'
import type { EstadoConsumo } from '@/features/admin/estados'

/** Cliente del historial de transacciones, la bitácora y la configuración. */

// ── Transacciones ──────────────────────────────────────────────────────────

/**
 * Los estados de un consumo, «reverted» incluido. La etiqueta y el tono
 * viven en `estados.ts` (`ESTADOS_CONSUMO`, `estadoDeConsumo`).
 */
export type ChargeStatus = EstadoConsumo

export type ChargeRow = {
  chargeId: string
  /**
   * El número con el que se habla de esta orden.
   *
   * El uuid sirve para el QR; cuando el local llama por teléfono dice «la
   * 1043». Es único global y empieza en 1000.
   *
   * Nullable por precaución y no porque la columna lo sea: si la migración
   * 20260913100000 todavía no está aplicada en ese proyecto, la RPC no
   * devuelve el campo y esto se queda en null en vez de convertirse en un NaN
   * paseándose por la pantalla.
   */
  orderNumber: number | null
  /** PAYABLE: lo que se debe, con la Comisión Helios y su IVA dentro. No se enseña como consumo. */
  amountUsd: number
  /** FINANCED: el consumo en el local, sin la comisión. Es la cifra que se enseña. */
  financedUsd: number
  status: ChargeStatus
  businessDate: string | null
  createdAt: string
  confirmedAt: string | null
  voidReason: string | null
  userId: string | null
  fullName: string | null
  phone: string | null
  userStatus: string | null
  merchantId: string
  merchantName: string
  branchName: string
  /** El consumo es de prueba si lo es la persona o el local. */
  isTest: boolean
  installmentsPaid: number
  installmentsTotal: number
}

export async function fetchCharges(params: {
  search?: string
  merchantId?: string | null
  status?: ChargeStatus | null
  from?: string | null
  to?: string | null
  limit?: number
}): Promise<ChargeRow[]> {
  const { data, error } = await supabase.rpc('admin_charges', {
    p_search: params.search?.trim() || null,
    p_merchant_id: params.merchantId ?? null,
    p_status: params.status ?? null,
    p_from: params.from ?? null,
    p_to: params.to ?? null,
    p_limit: params.limit ?? 100,
  })
  if (error) throw error

  return filas(data).map((row) => ({
    chargeId: texto(row.charge_id),
    orderNumber: numeroONulo(row.order_number),
    amountUsd: numero(row.amount_usd),
    // `coalesce(base_usd, amount_usd)` en la base (20260925133000).
    financedUsd: numero(row.financed_usd),
    // Un estado que no se conoce se enseña como pendiente: es el que pide mirarlo.
    status: unoDe(VALORES_ESTADO_CONSUMO, row.status) ?? 'pending',
    businessDate: textoONulo(row.business_date),
    createdAt: texto(row.created_at),
    confirmedAt: textoONulo(row.confirmed_at),
    voidReason: textoONulo(row.void_reason),
    userId: textoONulo(row.user_id),
    fullName: textoONulo(row.full_name),
    phone: textoONulo(row.phone_e164),
    userStatus: textoONulo(row.user_status),
    merchantId: texto(row.merchant_id),
    merchantName: texto(row.merchant_name),
    branchName: texto(row.branch_name),
    isTest: booleano(row.is_test),
    installmentsPaid: numero(row.installments_paid),
    installmentsTotal: numero(row.installments_total),
  }))
}

/**
 * Anula un cobro **pendiente** — un QR generado y nunca reclamado.
 *
 * Un consumo ya confirmado NO se puede anular desde aquí. Esa es la válvula de
 * escape que recomienda docs/06 §2 para el cajero que teclea €500 en vez de
 * €50, y sigue sin construirse porque D-13 no está decidida: revertirlo exige
 * tocar el ledger, borrar el plan de cuotas y devolver el cupo del bloque.
 */
export async function voidCharge(chargeId: string, reason: string): Promise<void> {
  const { error } = await supabase.rpc('admin_void_charge', {
    p_charge_id: chargeId,
    p_reason: reason,
  })
  if (error) throw error
}

// ── Bitácora ───────────────────────────────────────────────────────────────

export type AuditEntry = {
  id: number
  /** Quién lo hizo. `null` si lo escribió el propio sistema, sin sesión. */
  actor: string | null
  actorName: string | null
  action: string
  targetId: string | null
  detail: Record<string, unknown>
  createdAt: string
}

/**
 * La bitácora, filtrable por tema, por quién la hizo y sobre quién.
 *
 * `actions` es una lista porque un tema son varios códigos: «pagos de
 * usuarios» es el aceptado, el rechazado y el que se dejó en revisión. Cuando
 * era un texto suelto, el filtro mandaba un código inventado y la pantalla
 * enseñaba una tabla vacía encima de once pagos conciliados.
 *
 * `target` es lo que convierte la bitácora en la última sección de la ficha de
 * una persona: todo lo que se le hizo a esa cuenta, incluido lo que hizo el
 * motor. Sin él, para saber por qué alguien está congelado había que leer la
 * bitácora entera.
 */
export async function fetchAuditLog(params: {
  actions?: string[] | null
  actor?: string | null
  target?: string | null
  limit?: number
  from?: string | null
  to?: string | null
  offset?: number
}): Promise<{ rows: AuditEntry[]; total: number }> {
  const { data, error } = await supabase.rpc('admin_audit_log', {
    p_actions: params.actions ?? null,
    p_actor: params.actor ?? null,
    p_target: params.target ?? null,
    p_limit: params.limit ?? 100,
    p_from: params.from ?? null,
    p_to: params.to ?? null,
    p_offset: params.offset ?? 0,
  })
  if (error) throw error

  const raw = comoLista(data).map(comoFila)

  return {
    rows: raw.map((row) => ({
      id: Number(row.id),
      actor: textoONulo(row.actor),
      actorName: textoONulo(row.actor_name),
      action: String(row.action),
      targetId: textoONulo(row.target_id),
      // Puede venir nulo de la base; se normaliza aquí para que nadie más
      // tenga que acordarse.
      detail: comoFila(row.detail),
      createdAt: String(row.created_at),
    })),
    // El total viaja repetido en cada fila: es lo que deja decir "1 a 100 de
    // 3.412" sin una segunda consulta. Con cero filas, cero.
    total: raw.length > 0 ? Number(raw[0].total_count) : 0,
  }
}

// ── Niveles ────────────────────────────────────────────────────────────────

export type LevelConfig = {
  level: number
  label: string
  monthlyLimitUsd: number
  requiredSpendUsd: number
  requiredMonths: number
  isActive: boolean
  userCount: number
  /** Deuda viva de la gente que hoy está en ese nivel. Subir el límite sin
   *  mirar este número es abrir exposición a ciegas. */
  exposureUsd: number
}

export async function fetchLevelConfig(): Promise<LevelConfig[]> {
  const { data, error } = await supabase.rpc('admin_level_config')
  if (error) throw error

  return (data as Array<Record<string, unknown>>).map((row) => ({
    level: Number(row.level),
    label: String(row.label),
    monthlyLimitUsd: Number(row.monthly_limit_usd),
    requiredSpendUsd: Number(row.required_spend_usd),
    requiredMonths: Number(row.required_months),
    isActive: Boolean(row.is_active),
    userCount: Number(row.user_count),
    exposureUsd: Number(row.exposure_usd),
  }))
}

export async function saveLevelConfig(config: {
  level: number
  monthlyLimitUsd: number
  requiredSpendUsd: number
  requiredMonths: number
  isActive: boolean
  label: string
  /** El motivo del diálogo: va a la bitácora (`level.configure`). */
  note?: string | null
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_level_config', {
    p_level: config.level,
    p_monthly_limit_usd: config.monthlyLimitUsd,
    p_required_spend_usd: config.requiredSpendUsd,
    p_required_months: config.requiredMonths,
    p_is_active: config.isActive,
    p_label: config.label,
    p_note: config.note || null,
  })
  if (error) throw error
}

// ── Cuenta de cobro ────────────────────────────────────────────────────────

/**
 * Cómo paga el paciente a esa cuenta: cada método exige sus datos (contrato
 * §2.3). Desde el 2026-10-07 el paciente solo paga en bolívares: Pago Móvil o
 * transferencia (`20261007000300_el_paciente_solo_paga_en_bolivares`).
 */
export type MetodoDeCobro = 'pago_movil' | 'transferencia'

/**
 * Lo que puede traer una cuenta guardada: las de Zelle de antes del
 * 2026-10-07 siguen en la base, apagadas, porque los pagos viejos se cotejan
 * contra ellas. Se enseñan como historia y no se editan.
 */
export type MetodoDeCuenta = MetodoDeCobro | 'zelle'

export const METODOS_DE_COBRO: Array<{ value: MetodoDeCobro; label: string }> = [
  { value: 'pago_movil', label: 'Pago Móvil' },
  { value: 'transferencia', label: 'Transferencia' },
]

/** El nombre de un método de cuenta, también el de una histórica. */
export function nombreDelMetodoDeCobro(metodo: MetodoDeCuenta): string {
  return metodo === 'zelle'
    ? 'Zelle'
    : (METODOS_DE_COBRO.find((m) => m.value === metodo)?.label ?? metodo)
}

export type PaymentDestination = {
  id: string
  method: MetodoDeCuenta
  /** Vacío si el método no lo usa (las de Zelle, históricas). */
  bankName: string
  rif: string
  phone: string
  accountNumber: string | null
  email: string | null
  holderName: string | null
  isActive: boolean
  createdAt: string
  reportCount: number
  /**
   * El orden en que la ven los pacientes (Helios: puede haber varias
   * activas). `null` si la base no lo manda.
   */
  sortOrder: number | null
}

export async function fetchPaymentDestinations(): Promise<PaymentDestination[]> {
  const { data, error } = await supabase.rpc('admin_payment_destinations')
  if (error) throw error

  return comoLista(data)
    .map(comoFila)
    .map((row) => ({
      id: String(row.id),
      method: leerMetodo(row.method),
      bankName: textoONulo(row.bank_name) ?? '',
      rif: textoONulo(row.rif) ?? '',
      phone: textoONulo(row.phone) ?? '',
      accountNumber: textoONulo(row.account_number),
      email: textoONulo(row.email),
      holderName: textoONulo(row.holder_name),
      isActive: Boolean(row.is_active),
      createdAt: String(row.created_at),
      reportCount: Number(row.report_count),
      sortOrder: numeroONulo(row.sort_order),
    }))
}

/** Un método que no se conoce se lee como Pago Móvil, el único que hubo en Ronda. */
export function leerMetodo(valor: unknown): MetodoDeCuenta {
  return valor === 'transferencia' || valor === 'zelle' ? valor : 'pago_movil'
}

/** Una cuenta en bolívares: la única que se puede activar, ordenar o editar. */
export type CuentaEnBolivares = PaymentDestination & { method: MetodoDeCobro }

/**
 * Si la cuenta es de las que el paciente puede usar hoy (Pago Móvil o
 * transferencia). Una de Zelle es histórica: se lista, pero ni se activa ni
 * se edita, y la base la rechazaría.
 */
export function esCuentaEnBolivares(cuenta: PaymentDestination): cuenta is CuentaEnBolivares {
  return cuenta.method !== 'zelle'
}

/**
 * Da de alta una cuenta de cobro (sin `id`) o edita una que ya existe (con
 * `id`): orden, estado o datos (contrato §2.3). En Helios puede haber varias
 * activas: activar una ya no retira las demás.
 *
 * ⚠️ Al editar, la base reescribe TODOS los datos de la cuenta con lo que
 * llega: hay que mandarla completa (`datosDe(cuenta)`), o se borran el número
 * de cuenta o el correo.
 */
export async function setPaymentDestination(params: {
  id?: string
  method: MetodoDeCobro
  bankName: string
  rif: string
  phone: string
  accountNumber?: string | null
  email?: string | null
  holderName?: string
  /** El motivo del diálogo: va a la bitácora (`payment_destination.set`). */
  note?: string | null
  /** El puesto en que la ven los pacientes. */
  sortOrder?: number | null
  /** Sin él, activa. */
  isActive?: boolean
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_payment_destination', {
    p_bank_name: params.bankName,
    p_rif: params.rif,
    p_phone: params.phone,
    p_holder_name: params.holderName ?? null,
    p_note: params.note || null,
    p_sort_order: params.sortOrder ?? null,
    p_is_active: params.isActive ?? true,
    p_id: params.id ?? null,
    p_method: params.method,
    p_account_number: params.accountNumber || null,
    p_email: params.email || null,
  })
  if (error) throw error
}

/** Los datos de una cuenta tal cual, para editar solo su orden o su estado. */
export function datosDe(cuenta: CuentaEnBolivares) {
  return {
    id: cuenta.id,
    method: cuenta.method,
    bankName: cuenta.bankName,
    rif: cuenta.rif,
    phone: cuenta.phone,
    accountNumber: cuenta.accountNumber,
    email: cuenta.email,
    holderName: cuenta.holderName ?? undefined,
  }
}

// ── Equipo de Ronda ────────────────────────────────────────────────────────

export type RolDelPanel = 'operador' | 'super_admin'

export type TeamMember = {
  userId: string
  fullName: string | null
  email: string | null
  role: RolDelPanel
  isActive: boolean
  createdAt: string
  actionCount: number
  lastActionAt: string | null
}

export async function fetchTeam(): Promise<TeamMember[]> {
  const { data, error } = await supabase.rpc('admin_platform_team')
  if (error) throw error

  return comoLista(data)
    .map(comoFila)
    .map((row) => ({
      userId: String(row.user_id),
      fullName: textoONulo(row.full_name),
      email: textoONulo(row.email),
      // Un rol que no se conoce se lee como el de menos poder: pintar a alguien
      // como super admin sin serlo es peor que al revés.
      role: row.role === 'super_admin' ? 'super_admin' : 'operador',
      isActive: Boolean(row.is_active),
      createdAt: String(row.created_at),
      actionCount: Number(row.action_count),
      lastActionAt: textoONulo(row.last_action_at),
    }))
}

export async function addTeamMember(params: {
  email: string
  password: string
  fullName: string
  role: RolDelPanel
  /** El motivo, si se pidió (dar acceso de super admin): va a la bitácora. */
  note?: string | null
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_platform_admin', {
    p_email: params.email,
    p_password: params.password,
    p_full_name: params.fullName,
    p_role: params.role,
    p_note: params.note || null,
  })
  if (error) throw error
}

export async function revokeTeamMember(userId: string, note?: string | null): Promise<void> {
  const { error } = await supabase.rpc('admin_revoke_platform_admin', {
    p_user_id: userId,
    p_note: note || null,
  })
  if (error) throw error
}

/** Vuelve a activar una fila revocada.
 *
 *  No es `addTeamMember`: aquella crea la cuenta de Auth y contra un correo
 *  que ya existe falla, así que sin esto revocar por error no tenía vuelta
 *  atrás desde el panel. La persona conserva su cuenta y su historial — solo
 *  se levanta la bandera. */
export async function restoreTeamMember(userId: string, note?: string | null): Promise<void> {
  const { error } = await supabase.rpc('admin_restore_platform_admin', {
    p_user_id: userId,
    p_note: note || null,
  })
  if (error) throw error
}
