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
  /** Secretaria que solo registra y ve sus comisiones: sin el historial de
   *  pagos en cuotas. Lo decide el médico al crearla; siempre false para un
   *  administrador. */
  soloRegistra: boolean
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
    soloRegistra: row.solo_registra === true,
  }))
}

export async function addStaff(params: {
  merchantId: string
  email: string
  password: string
  fullName: string
  role: MerchantRole
  /** Solo cuenta para una secretaria. Sin él, ve su historial. */
  soloRegistra?: boolean
}): Promise<string> {
  const { data, error } = await supabase.rpc('merchant_staff_add', {
    p_merchant_id: params.merchantId,
    p_email: params.email.trim(),
    p_password: params.password,
    p_full_name: params.fullName.trim(),
    p_role: params.role,
    p_branch_id: null,
    p_solo_registra: params.role === 'cajero' && params.soloRegistra === true,
  })
  if (error) throw error
  return String((data as { user_id: unknown }).user_id)
}

/** Cómo le fue al correo de bienvenida. */
export type ResultadoBienvenida = { status: 'enviado' | 'sin_configurar' | 'fallido'; error: string | null }

/**
 * El correo de bienvenida con los datos de acceso (y cómo usar el bot), con
 * copia oculta a Helios. La base comprueba que la contraseña sea la de la
 * cuenta y no la guarda. No lanza si el correo no sale: lo dice el resultado.
 */
export async function enviarBienvenida(params: {
  merchantId: string
  userId: string
  password: string
}): Promise<ResultadoBienvenida> {
  const { data, error } = await supabase.rpc('merchant_staff_send_welcome', {
    p_merchant_id: params.merchantId,
    p_user_id: params.userId,
    p_password: params.password,
  })
  if (error) throw error
  const r = data as { status?: string; error?: string | null }
  const status = r.status === 'enviado' || r.status === 'sin_configurar' ? r.status : 'fallido'
  return { status, error: r.error ?? null }
}

/** Nombre, rol y si solo registra. La sucursal la resuelve el servidor
 *  según el rol. */
export async function updateStaff(params: {
  merchantId: string
  userId: string
  fullName: string
  role: MerchantRole
  soloRegistra: boolean
}): Promise<void> {
  const { error } = await supabase.rpc('merchant_staff_update', {
    p_merchant_id: params.merchantId,
    p_user_id: params.userId,
    p_full_name: params.fullName.trim(),
    p_role: params.role,
    p_branch_id: null,
    p_solo_registra: params.role === 'cajero' && params.soloRegistra,
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
    hace: 'lo ve todo de la clínica, registra pagos en cuotas y gestiona el personal',
  },
  cajero: {
    label: 'Secretaria',
    hace: 'registra pagos en cuotas y consulta los suyos',
  },
}

export const ROLES: Array<{ value: MerchantRole; label: string }> = (
  ['gerente', 'cajero'] as const
).map((value) => ({ value, label: ROL[value].label }))

/** Qué hace la secretaria que solo registra. */
export const HACE_SOLO_REGISTRA =
  'registra pagos en cuotas, sin ver el historial ni el monto de cada consulta'

/** Qué hace esta persona: lo de su rol, o lo de la secretaria que solo registra. */
export function queHace(m: { role: MerchantRole; soloRegistra: boolean }): string {
  return m.role === 'cajero' && m.soloRegistra ? HACE_SOLO_REGISTRA : ROL[m.role].hace
}
