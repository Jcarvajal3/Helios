import { supabase } from '@/lib/supabase'
import type { MerchantRole } from '@/features/auth/session'

// ═══════════════════════════════════════════════════════════════════════════
// El personal de un local.
//
// Un solo cliente para los DOS paneles. Quien puede lo decide el servidor
// —`can_manage_merchant_staff`: el equipo de Ronda, o el gerente activo de ese
// comercio— y no el panel desde el que se llama. Aquí no hay ninguna rama por
// rol a propósito: si la hubiera, sería una segunda versión de la regla y
// tarde o temprano diría algo distinto que la de la base.
// ═══════════════════════════════════════════════════════════════════════════

export type StaffMember = {
  userId: string
  name: string | null
  email: string | null
  /** Solo lo tienen las cuentas antiguas, de cuando el alta buscaba por
   *  teléfono en vez de crear la cuenta. */
  phone: string | null
  role: MerchantRole
  branchId: string | null
  branch: string | null
  createdAt: string
  /** Quien está mirando. El servidor le prohíbe cambiarse el rol y darse de
   *  baja; esto es para apagar los botones en vez de dejar que falle. */
  isSelf: boolean
}

export async function fetchStaff(merchantId: string): Promise<StaffMember[]> {
  const { data, error } = await supabase.rpc('merchant_staff_list', {
    p_merchant_id: merchantId,
  })
  if (error) throw error

  const raw = data as { rows?: Array<Record<string, unknown>> }

  return (raw.rows ?? []).map((row) => ({
    userId: String(row.user_id),
    name: (row.name as string | null) ?? null,
    email: (row.email as string | null) ?? null,
    phone: (row.phone as string | null) ?? null,
    role: row.role as MerchantRole,
    branchId: (row.branch_id as string | null) ?? null,
    branch: (row.branch as string | null) ?? null,
    createdAt: String(row.created_at),
    isSelf: Boolean(row.is_self),
  }))
}

export async function addStaff(params: {
  merchantId: string
  email: string
  password: string
  fullName: string
  role: MerchantRole
}): Promise<void> {
  const { error } = await supabase.rpc('merchant_staff_add', {
    p_merchant_id: params.merchantId,
    p_email: params.email.trim(),
    p_password: params.password,
    p_full_name: params.fullName.trim(),
    p_role: params.role,
    p_branch_id: null,
  })
  if (error) throw error
}

/** Nombre y rol. La sucursal la resuelve el servidor según el rol. */
export async function updateStaff(params: {
  merchantId: string
  userId: string
  fullName: string
  role: MerchantRole
}): Promise<void> {
  const { error } = await supabase.rpc('merchant_staff_update', {
    p_merchant_id: params.merchantId,
    p_user_id: params.userId,
    p_full_name: params.fullName.trim(),
    p_role: params.role,
    p_branch_id: null,
  })
  if (error) throw error
}

/**
 * Contraseña nueva.
 *
 * La genera el panel y se enseña una sola vez: el servidor guarda el hash y
 * no la devuelve nunca más. Quien la resetea tiene que pasársela a la persona
 * por otro canal.
 */
export async function setStaffPassword(params: {
  merchantId: string
  userId: string
  password: string
}): Promise<void> {
  const { error } = await supabase.rpc('merchant_staff_set_password', {
    p_merchant_id: params.merchantId,
    p_user_id: params.userId,
    p_password: params.password,
  })
  if (error) throw error
}

export async function removeStaff(params: {
  merchantId: string
  userId: string
}): Promise<void> {
  const { error } = await supabase.rpc('merchant_staff_remove', {
    p_merchant_id: params.merchantId,
    p_user_id: params.userId,
  })
  if (error) throw error
}

/** Cómo se llama cada rol y qué hace, en las dos pantallas que lo enseñan. */
export const ROL: Record<MerchantRole, { label: string; hace: string }> = {
  gerente: {
    label: 'Administrador',
    hace: 'lo ve todo de la clínica, registra financiamientos y gestiona el personal',
  },
  cajero: {
    label: 'Secretaria',
    hace: 'registra financiamientos y consulta los suyos',
  },
}

export const ROLES: Array<{ value: MerchantRole; label: string }> = (
  ['gerente', 'cajero'] as const
).map((value) => ({ value, label: ROL[value].label }))
