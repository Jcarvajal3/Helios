import {
  comoFila,
  filas,
  numero,
  numeroONulo,
  texto,
  textoONulo,
} from '@/lib/json'
import { supabase } from '@/lib/supabase'
import { leerMoneda } from '@/components/ui'
import type { Moneda } from '@/components/ui'
import { ESTADOS_PERSONA } from '@/features/admin/estados'
import { leerConsumosDePersona } from '@/features/admin/directorio/consumosDePersona'
import type { ConsumoDePersona } from '@/features/admin/directorio/consumosDePersona'
import { comoMotivoSinDisponible } from '@/features/admin/directorio/cupo'
import { leerDatosDelPaciente } from '@/features/admin/pacientes/datos'
import type { DatosDelPaciente } from '@/features/admin/pacientes/datos'
import type { MotivoSinDisponible } from '@/features/admin/directorio/cupo'

/**
 * Cliente de la gestión de usuarios y de la cola de cobranza.
 *
 * Las tres acciones que escriben (`setUserStatus`, `setUserLevel`,
 * `setBlacklist`) exigen motivo en el servidor. El panel lo pide antes de
 * enviarlo, pero no valida por su cuenta: la regla vive en la base, y una
 * validación duplicada en el cliente es una que se puede olvidar de actualizar.
 */

export type ProfileStatus =
  | 'pending_kyc'
  | 'pending_pin'
  | 'active'
  | 'frozen'
  | 'suspended'
  | 'expelled'

/**
 * La etiqueta de cada estado. Sale de `ESTADOS_PERSONA` (estados.ts), que
 * lleva además el tono: lo nuevo usa `estadoDePersona` o `EstadoBadge`.
 */
export const PROFILE_STATUS_LABEL: Record<ProfileStatus, string> = {
  pending_kyc: ESTADOS_PERSONA.pending_kyc.label,
  pending_pin: ESTADOS_PERSONA.pending_pin.label,
  active: ESTADOS_PERSONA.active.label,
  frozen: ESTADOS_PERSONA.frozen.label,
  suspended: ESTADOS_PERSONA.suspended.label,
  expelled: ESTADOS_PERSONA.expelled.label,
}

// ── Directorio ─────────────────────────────────────────────────────────────

export type UserRow = {
  userId: string
  fullName: string | null
  phone: string | null
  document: string | null
  status: ProfileStatus
  level: number
  levelLimitUsd: number
  isBlacklisted: boolean
  /** Cuenta de prueba: sigue apareciendo en la lista, pero no cuenta en nada. */
  isTest: boolean
  createdAt: string
  /** PAYABLE: la deuda viva (vencido + por vencer), sin lo dado por perdido. */
  openDebtUsd: number
  /** PAYABLE: lo vencido, sin lo dado por perdido. */
  overdueUsd: number
  /**
   * Las dos partes de cada deuda: facturado (sin comisión) y Comisión Helios + IVA.
   * `null` si la base todavía no las manda: no se inventan.
   */
  openDebtDesglose?: { financedUsd: number; feeUsd: number } | null
  overdueDesglose?: { financedUsd: number; feeUsd: number } | null
  daysOverdue: number
  chargeCount: number
  lastChargeAt: string | null
  /** El cupo libre, sin mirar si hoy puede gastarlo. */
  availableUsd: number
  /**
   * Lo que puede gastar HOY: cero con una cuota vencida, con la cuenta no
   * activa o con un bloqueo. `null` si la base no lo dice (el padrón viejo):
   * entonces no se pinta, porque el nominal de una cuenta congelada es falso.
   */
  availableNowUsd: number | null
  /** Por qué el disponible de hoy es cero, si lo es. */
  sinDisponible: MotivoSinDisponible | null
  /** Dónde consumió la última vez. Es la primera pregunta de cualquiera que
   *  mire la lista. */
  lastMerchantName: string | null
  /** Cobrado a tiempo: de sus cuotas con el plazo cerrado (vencimiento +
   *  días de gracia), cuántas pagó dentro de él. Dice más del comportamiento
   *  que la deuda de hoy, que puede ser de esta noche. */
  onTimePaid: number
  onTimeTotal: number
  /** La clínica que lo registró (Helios: el paciente nace en una clínica). */
  registeredMerchantName?: string | null
  /** Cuándo rebotó su correo. `null` si el correo sirve (o si la base no lo manda). */
  emailInvalidAt?: string | null
}

/** Las dos partes de una deuda, o `null` si la base no manda el facturado. */
function partes(financed: unknown, fee: unknown): { financedUsd: number; feeUsd: number } | null {
  const f = numeroONulo(financed)
  return f === null ? null : { financedUsd: f, feeUsd: numero(fee) }
}

/** Unas pocas personas, las que más se parecen: el buscador de arriba. */
export async function fetchUsers(params: {
  search?: string
  status?: ProfileStatus | null
  limit?: number
}): Promise<UserRow[]> {
  return (await fetchPaginaDeUsuarios({ ...params, pagina: 1, porPagina: params.limit ?? 50 })).filas
}

/**
 * Las columnas por las que el padrón sabe ordenarse en la base: las mismas
 * claves que las columnas de la tabla. «Disponible hoy» no está: es una
 * función cara que solo se calcula para la página.
 */
export const ORDENES_DEL_PADRON = [
  'persona',
  'estado',
  'nivel',
  'deuda',
  'vencido',
  'dias-atraso',
  'a-tiempo',
  'registro',
  'ultimo',
  'ultimo-local',
] as const
export type OrdenDelPadron = (typeof ORDENES_DEL_PADRON)[number]

/** Una página del padrón y cuántas personas cumplen el filtro. */
export type PaginaDeUsuarios = { filas: UserRow[]; total: number }

/**
 * Una página del padrón, con todos los filtros en el servidor: con la lista
 * paginada, filtrar en el navegador solo miraría la página que se ve.
 */
export async function fetchPaginaDeUsuarios(params: {
  search?: string
  status?: ProfileStatus | null
  level?: number
  soloPrueba?: boolean
  soloMarcadas?: boolean
  /** Desde 1. */
  pagina: number
  porPagina: number
  /** Sin él, el orden de siempre: lo más parecido a la búsqueda y lo más atrasado. */
  orden?: { key: OrdenDelPadron; dir: 'asc' | 'desc' }
}): Promise<PaginaDeUsuarios> {
  const { data, error } = await supabase.rpc('admin_user_directory', {
    p_search: params.search?.trim() || null,
    p_status: params.status ?? null,
    p_limit: params.porPagina,
    p_level: params.level ?? null,
    p_is_test: params.soloPrueba ? true : null,
    p_blacklisted: params.soloMarcadas ? true : null,
    p_offset: (params.pagina - 1) * params.porPagina,
    p_orden: params.orden?.key ?? null,
    p_dir: params.orden?.dir ?? null,
  })
  if (error) throw error

  const leidas = (data as Array<Record<string, unknown>>).map(leerUsuario)
  // Cada fila trae el total del filtro; una página vacía no trae ninguna.
  const total = Number((data as Array<Record<string, unknown>>)[0]?.total_count ?? 0)
  return { filas: leidas, total }
}

function leerUsuario(row: Record<string, unknown>): UserRow {
  return ({
    userId: String(row.user_id),
    fullName: (row.full_name as string | null) ?? null,
    phone: (row.phone_e164 as string | null) ?? null,
    document: (row.document_number as string | null) ?? null,
    status: row.status as ProfileStatus,
    level: Number(row.level),
    levelLimitUsd: Number(row.level_limit_usd),
    isBlacklisted: Boolean(row.is_blacklisted),
    isTest: Boolean(row.is_test),
    createdAt: String(row.created_at),
    openDebtUsd: Number(row.open_debt_usd),
    overdueUsd: Number(row.overdue_usd),
    openDebtDesglose: partes(row.open_debt_financed_usd, row.open_debt_fee_usd),
    overdueDesglose: partes(row.overdue_financed_usd, row.overdue_fee_usd),
    daysOverdue: Number(row.days_overdue),
    chargeCount: Number(row.charge_count),
    lastChargeAt: (row.last_charge_at as string | null) ?? null,
    availableUsd: Number(row.available_usd ?? 0),
    availableNowUsd: numeroONulo(row.available_now_usd),
    sinDisponible: comoMotivoSinDisponible(row.available_blocked_reason),
    lastMerchantName: (row.last_merchant_name as string | null) ?? null,
    onTimePaid: Number(row.on_time_paid ?? 0),
    onTimeTotal: Number(row.on_time_total ?? 0),
    registeredMerchantName: textoONulo(row.registered_merchant_name),
    emailInvalidAt: textoONulo(row.email_invalid_at),
  })
}

// ── Ficha ──────────────────────────────────────────────────────────────────

export type UserDetail = {
  userId: string
  fullName: string | null
  phone: string | null
  document: string | null
  birthDate: string | null
  /** La pestaña Datos: lo que tecleó la clínica al registrarlo (contrato §2.4). */
  datos: DatosDelPaciente
  status: ProfileStatus
  level: number
  isBlacklisted: boolean
  blacklistReason: string | null
  /** Cuenta de prueba: no cuenta en ninguna cifra ni entra en ninguna cola. */
  isTest: boolean
  createdAt: string
  credit: {
    levelLimitUsd: number
    blockChargedUsd: number
    blockPaidUsd: number
    /**
     * FINANCED: lo que puede gastar HOY, la misma cifra que ve en la app. Cero
     * si no puede tomar deuda, aunque le quede cupo: ver `availableBlockedReason`.
     */
    availableNowUsd: number
    /** FINANCED: el límite menos lo que ocupan sus consumos, sin mirar si hoy puede gastar. */
    availableNominalUsd: number
    /** Por qué `availableNowUsd` es cero con cupo libre. `null` si puede gastar. */
    availableBlockedReason: MotivoSinDisponible | null
    /**
     * El bloque de crédito: consumo sin comisión menos cuotas con comisión. Mezcla dos
     * clases de cifra y responde a la regla de antes de 20260830240000 (hoy el
     * cupo se libera por consumo): no se pinta en ninguna parte (AUD-OPERACION C1).
     */
    toUnlockUsd: number
    blockOpenedAt: string | null
  }
  debt: {
    /** PAYABLE: sus cuotas sin pagar, vencidas y por vencer, sin las perdidas. */
    openUsd: number
    /** PAYABLE: las de `openUsd` con vencimiento anterior a hoy. */
    overdueUsd: number
    /** PAYABLE: sus cuotas pagadas, con la comisión dentro. */
    paidUsd: number
    /**
     * FINANCED: el consumo de sus cuotas pagadas, la cifra del motor de
     * niveles. Null si la base no tiene 20260927696000.
     */
    paidFinancedUsd: number | null
    daysOverdue: number
    /** PAYABLE: sus cuotas sin pagar dadas por perdidas. Null sin 20260927696000. */
    writtenOffUsd: number | null
    /** FINANCED: el consumo que llevan dentro esas cuotas perdidas. */
    writtenOffFinancedUsd: number | null
  }
  installments: Array<{
    id: string
    chargeId: string
    /**
     * El número de la orden de la que sale la cuota.
     *
     * Null si la base no tiene aplicada 20260917160000: la columna sale con un
     * guion en vez de un `NaN` paseándose por la pantalla.
     */
    orderNumber: number | null
    sequence: number
    /** PAYABLE: lo que se paga en esta cuota, con su parte de la Comisión Helios dentro. */
    amountUsd: number
    /** FINANCED: el consumo que lleva dentro esta cuota. */
    financedUsd: number
    /**
     * La moneda en que se cobró su orden (2026-10-07). Las cifras de arriba
     * siguen en dólares; en una de euros, el paciente paga `amountCur` euros
     * a la tasa BCV del euro del día en que paga.
     */
    currency: Moneda
    /** La cuota en la moneda de su orden (en una de dólares, igual a `amountUsd`). */
    amountCur: number
    /** El consumo de la cuota en la moneda de su orden. */
    financedCur: number
    dueDate: string
    status: 'pending' | 'paid'
    paidAt: string | null
    merchantName: string
    daysOverdue: number
    /** Dada por perdida: sigue `pending` pero ya no es deuda viva. */
    writtenOffAt: string | null
    /**
     * El día operativo en que REPORTÓ el pago que la saldó (sin reporte, el de
     * la aprobación): `metricas.cuotas.pagada_dia`. Null si no está pagada o
     * si la base no tiene 20260927696000.
     */
    paidDay: string | null
    /**
     * Cobrada a tiempo con la regla canónica (`metricas.a_tiempo`: el día del
     * reporte, como mucho el vencimiento más los días de gracia). Null si no
     * está pagada o si la base no lo manda.
     */
    onTime: boolean | null
  }>
  /** Los consumos que PUSO. Los de grupo en los que está van en `consumos`. */
  charges: Array<{
    id: string
    /** Ver `installments[].orderNumber`. */
    orderNumber: number | null
    /** PAYABLE: el consumo con la Comisión Helios dentro. */
    amountUsd: number
    /** FINANCED: el consumo en el local, sin la comisión. */
    financedUsd: number
    /** La moneda en que la cobró el médico. Las cifras de arriba siguen en dólares. */
    currency: Moneda
    /** El total, con la comisión dentro, en la moneda de la orden. */
    amountCur: number | null
    /** La consulta, sin comisión, en la moneda de la orden. */
    baseCur: number | null
    status: string
    businessDate: string | null
    confirmedAt: string | null
    merchantId: string
    merchantName: string
    branchName: string
    voidReason: string | null
  }>
  /**
   * Todos los consumos en los que está: los que puso y los de grupo en los que
   * tiene cuotas, del más reciente al más viejo. Montos en consumo (financed).
   */
  consumos: ConsumoDePersona[]
  payments: Array<{
    id: string
    status: string
    bank: string | null
    reference: string | null
    method: string
    /** Lo que transfirió: sus cuotas (PAYABLE) más los cargos por atraso. */
    amountUsd: number
    amountVes: number
    rejectionNote: string | null
    createdAt: string
    /**
     * Los sumandos de `amountUsd`: sus cuotas partidas en consumo y comisión, y
     * los cargos por atraso. Null si la base no tiene 20260927696000.
     */
    partes: {
      cuotasPayableUsd: number
      cuotasFinancedUsd: number
      cuotasFeeUsd: number
      lateFeesUsd: number
    } | null
  }>
  levelChanges: Array<{
    fromLevel: number
    toLevel: number
    reason: string
    note: string | null
    createdAt: string
  }>
}

export async function fetchUserDetail(userId: string): Promise<UserDetail> {
  const { data, error } = await supabase.rpc('admin_user_detail', { p_user_id: userId })
  if (error) throw error

  const raw = comoFila(data)
  const credit = comoFila(raw.credit)
  const debt = comoFila(raw.debt)

  return {
    userId: texto(raw.user_id),
    fullName: textoONulo(raw.full_name),
    phone: textoONulo(raw.phone_e164),
    document: textoONulo(raw.document_number),
    birthDate: textoONulo(raw.birth_date),
    datos: leerDatosDelPaciente(raw),
    // La base lo guarda en un enum (`profile_status`): viene uno de la lista.
    status: texto(raw.status) as ProfileStatus,
    level: numero(raw.level),
    isBlacklisted: raw.is_blacklisted === true,
    blacklistReason: textoONulo(raw.blacklist_reason),
    isTest: raw.is_test === true,
    createdAt: texto(raw.created_at),
    credit: {
      levelLimitUsd: numero(credit.level_limit_usd),
      blockChargedUsd: numero(credit.block_charged_usd),
      blockPaidUsd: numero(credit.block_paid_usd),
      // `available_usd` no se lee: sale del bloque de crédito y no coincide
      // con el freno real de la compra (D4 §9).
      availableNowUsd: numero(credit.available_now_usd),
      availableNominalUsd: numero(credit.available_nominal_usd),
      availableBlockedReason: comoMotivoSinDisponible(credit.available_blocked_reason),
      toUnlockUsd: numero(credit.to_unlock_usd),
      blockOpenedAt: textoONulo(credit.block_opened_at),
    },
    debt: {
      openUsd: numero(debt.open_usd),
      overdueUsd: numero(debt.overdue_usd),
      paidUsd: numero(debt.paid_usd),
      paidFinancedUsd: numeroONulo(debt.paid_financed_usd),
      daysOverdue: numero(debt.days_overdue),
      writtenOffUsd: numeroONulo(debt.written_off_usd),
      writtenOffFinancedUsd: numeroONulo(debt.written_off_financed_usd),
    },
    installments: filas(raw.installments).map((i) => ({
      id: texto(i.id),
      chargeId: texto(i.charge_id),
      orderNumber: numeroONulo(i.order_number),
      sequence: numero(i.sequence),
      amountUsd: numero(i.amount_usd),
      financedUsd: numero(i.financed_usd),
      currency: leerMoneda(i.currency),
      amountCur: numeroONulo(i.amount_cur) ?? numero(i.amount_usd),
      financedCur: numeroONulo(i.financed_cur) ?? numero(i.financed_usd),
      dueDate: texto(i.due_date),
      status: i.status === 'paid' ? 'paid' : 'pending',
      paidAt: textoONulo(i.paid_at),
      merchantName: texto(i.merchant_name),
      daysOverdue: numero(i.days_overdue),
      writtenOffAt: textoONulo(i.written_off_at),
      paidDay: textoONulo(i.paid_day),
      onTime: typeof i.on_time === 'boolean' ? i.on_time : null,
    })),
    charges: filas(raw.charges).map((c) => ({
      id: texto(c.id),
      orderNumber: numeroONulo(c.order_number),
      amountUsd: numero(c.amount_usd),
      financedUsd: numero(c.financed_usd),
      currency: leerMoneda(c.currency),
      amountCur: numeroONulo(c.amount_cur),
      baseCur: numeroONulo(c.base_cur),
      status: texto(c.status),
      businessDate: textoONulo(c.business_date),
      confirmedAt: textoONulo(c.confirmed_at),
      merchantId: texto(c.merchant_id),
      merchantName: texto(c.merchant_name),
      branchName: texto(c.branch_name),
      voidReason: textoONulo(c.void_reason),
    })),
    consumos: leerConsumosDePersona(raw.consumos),
    payments: filas(raw.payments).map((p) => ({
      id: texto(p.id),
      status: texto(p.status),
      bank: textoONulo(p.bank),
      reference: textoONulo(p.reference),
      method: texto(p.method),
      amountUsd: numero(p.amount_usd),
      amountVes: numero(p.amount_ves),
      rejectionNote: textoONulo(p.rejection_note),
      createdAt: texto(p.created_at),
      partes:
        p.cuotas_payable_usd === undefined || p.cuotas_payable_usd === null
          ? null
          : {
              cuotasPayableUsd: numero(p.cuotas_payable_usd),
              cuotasFinancedUsd: numero(p.cuotas_financed_usd),
              cuotasFeeUsd: numero(p.cuotas_fee_usd),
              lateFeesUsd: numero(p.late_fees_usd),
            },
    })),
    levelChanges: filas(raw.level_changes).map((l) => ({
      fromLevel: numero(l.from_level),
      toLevel: numero(l.to_level),
      reason: texto(l.reason),
      note: textoONulo(l.note),
      createdAt: texto(l.created_at),
    })),
  }
}

// ── Acciones ───────────────────────────────────────────────────────────────

export async function setUserStatus(params: {
  userId: string
  status: ProfileStatus
  note: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_user_status', {
    p_user_id: params.userId,
    p_status: params.status,
    p_note: params.note,
  })
  if (error) throw error
}

export async function setUserLevel(params: {
  userId: string
  level: number
  note: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_user_level', {
    p_user_id: params.userId,
    p_level: params.level,
    p_note: params.note,
  })
  if (error) throw error
}

// ── Bloqueo manual ──────────────────────────────────────────────

/**
 * La sanción del equipo, que NO es `profiles.status`.
 *
 * El estado lo gobierna el motor de mora, que cada mañana devuelve a `active`
 * a quien no debe nada — así que un castigo puesto ahí se deshacía solo al día
 * siguiente. El bloqueo vive en su propia tabla y solo lo levanta una persona.
 * Ver la migración 20260909160000.
 */
export type UserBlock = {
  id: string
  /** Interno, para el equipo. No se le enseña al usuario. */
  reason: string
  /** Lo que el usuario lee en la app. */
  message: string
  blockedAt: string
  blockedByName: string | null
  liftedAt: string | null
  liftNote: string | null
  liftedByName: string | null
}

export async function fetchUserBlocks(userId: string): Promise<UserBlock[]> {
  const { data, error } = await supabase.rpc('admin_user_blocks', {
    p_user_id: userId,
  })
  if (error) throw error

  return (data as Array<Record<string, unknown>>).map((row) => ({
    id: String(row.id),
    reason: String(row.reason),
    message: String(row.message),
    blockedAt: String(row.blocked_at),
    blockedByName: (row.blocked_by_name as string | null) ?? null,
    liftedAt: (row.lifted_at as string | null) ?? null,
    liftNote: (row.lift_note as string | null) ?? null,
    liftedByName: (row.lifted_by_name as string | null) ?? null,
  }))
}

export async function blockUser(params: {
  userId: string
  reason: string
  message: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_block_user', {
    p_user_id: params.userId,
    p_reason: params.reason,
    p_message: params.message,
  })
  if (error) throw error
}

export async function unblockUser(params: {
  userId: string
  note: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_unblock_user', {
    p_user_id: params.userId,
    p_note: params.note,
  })
  if (error) throw error
}

export async function setBlacklist(params: {
  userId: string
  flag: boolean
  reason: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_blacklist', {
    p_user_id: params.userId,
    p_flag: params.flag,
    p_reason: params.reason,
  })
  if (error) throw error
}

// ── Cobranza ───────────────────────────────────────────────────────────────

// La cola de cobranza vive con el resto de las lecturas de Cobranza, en
// `cobranza/`. Se reexporta aquí para quien ya la importaba.
export { fetchCollections } from '@/features/admin/cobranza/consultas'
export type {
  CollectionBucket,
  CollectionQueue,
  CollectionRow,
} from '@/features/admin/cobranza/cartera'
