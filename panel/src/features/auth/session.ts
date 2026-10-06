import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import type { Session } from '@supabase/supabase-js'

import { supabase } from '@/lib/supabase'

/**
 * Los roles del personal de una clínica, con sus nombres de la base: `gerente`
 * es el Administrador y `cajero` la Secretaria. El `inventario` de Ronda
 * queda sin uso en Helios (no hay catálogo).
 */
export type MerchantRole = 'gerente' | 'cajero'

export type StaffContext = {
  userId: string
  merchantId: string
  merchantName: string
  /** Razón social. Null si el comercio no la cargó: no todos la tienen
   *  distinta del nombre comercial. */
  merchantLegalName: string | null
  /** RIF, tal como lo guarda la base: mayúscula, un guion, sin espacios.
   *  Obligatorio desde 2026-08-25, pero los comercios de antes pueden no
   *  tenerlo. */
  merchantTaxId: string | null
  /** Null para un gerente general: cubre todas las sucursales. */
  branchId: string | null
  branchName: string
  /** Dirección de la sucursal. Opcional en la base. */
  branchAddress: string | null
  role: MerchantRole
}

/**
 * Sesión del navegador. `undefined` mientras se resuelve, `null` si no hay.
 *
 * La distinción importa: pintar la pantalla de login durante el instante en
 * que Supabase todavía está leyendo la sesión de localStorage haría parpadear
 * el login en cada recarga.
 */
export function useSession(): Session | null | undefined {
  const [session, setSession] = useState<Session | null | undefined>(undefined)

  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => setSession(data.session))

    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next)
    })

    return () => sub.subscription.unsubscribe()
  }, [])

  return session
}

/**
 * El staff del usuario actual, para las pantallas que cuelgan de `_comercio`.
 *
 * `_comercio.tsx` ya lo resolvió con StaffGate, pero TanStack Router no pasa
 * el contexto del layout al hijo. Se vuelve a pedir con la MISMA queryKey, así
 * que sale de la caché de React Query en vez de ir al servidor otra vez —
 * cambiar esa clave aquí duplicaría la consulta en cada pantalla.
 *
 * Devuelve `undefined` mientras resuelve y `null` si la persona no es personal
 * de ningún comercio (caso que StaffGate ya atajó antes de llegar aquí).
 */
export function useStaff(): StaffContext | null | undefined {
  const session = useSession()

  const { data } = useQuery({
    queryKey: ['staff', session?.user.id],
    queryFn: () => fetchStaffContext(session!.user.id),
    enabled: !!session,
  })

  return data
}

/**
 * A qué comercio y sucursal pertenece el usuario autenticado.
 *
 * Devuelve null si la sesión es válida pero la persona no es personal de
 * ningún comercio — el caso de un cliente que entra por error a la URL del
 * panel. No es un error: es un "esto no es para ti".
 */
export async function fetchStaffContext(userId: string): Promise<StaffContext | null> {
  const { data, error } = await supabase
    .from('merchant_users')
    // La razón social, el RIF y la dirección salen de aquí y no de una
    // consulta aparte: es la MISMA fila que ya se lee al entrar al panel, y
    // sin ellos el comprobante del cobro no dice quién emite.
    .select(
      'merchant_id, branch_id, role, ' +
        'merchants(name, legal_name, tax_id), ' +
        'merchant_branches(name, address)',
    )
    // El filtro por user_id es imprescindible, no redundante. Antes se
    // confiaba solo en que RLS acotara la consulta a la fila propia, y eso
    // dejó de ser cierto al añadir la política que deja al super admin leer
    // todo `merchant_users`: un operador de Ronda entraba y veía el panel
    // del primer comercio de la lista como si fuera su personal.
    .eq('user_id', userId)
    .eq('is_active', true)
    .limit(1)
    .maybeSingle()

  if (error) throw error
  if (!data) return null

  // Sin tipos generados de la base, supabase-js infiere los embeds como no
  // nulos y eso no es cierto: `branch_id` es null para un gerente general,
  // así que `merchant_branches` viene null. El tipo explícito evita que el
  // linter nos empuje a quitar un `?.` que sí hace falta.
  type Row = {
    merchant_id: string
    branch_id: string | null
    role: MerchantRole | 'inventario'
    merchants: {
      name: string
      legal_name: string | null
      tax_id: string | null
    } | null
    merchant_branches: { name: string; address: string | null } | null
  }

  const row = data as unknown as Row

  // El rol `inventario` de Ronda no tiene pantallas en Helios: quien lo
  // tenga no es personal con acceso al panel.
  if (row.role === 'inventario') return null

  return {
    userId,
    merchantId: row.merchant_id,
    merchantName: row.merchants?.name ?? 'Clínica',
    merchantLegalName: row.merchants?.legal_name ?? null,
    merchantTaxId: row.merchants?.tax_id ?? null,
    branchId: row.branch_id,
    branchName: row.merchant_branches?.name ?? 'Todas las sedes',
    branchAddress: row.merchant_branches?.address ?? null,
    role: row.role,
  }
}

/**
 * Sucursal a la que se imputa un cobro.
 *
 * Un cajero siempre tiene la suya (lo exige el check `cajero_requires_branch`
 * en la base). Un gerente general no, así que se usa la sucursal por defecto
 * del comercio — v1 no expone selector de sucursal.
 */
export async function resolveBranchId(staff: StaffContext): Promise<string> {
  if (staff.branchId) return staff.branchId

  const { data, error } = await supabase
    .from('merchant_branches')
    .select('id')
    .eq('merchant_id', staff.merchantId)
    .eq('is_default', true)
    .single()

  if (error) throw error
  return data.id as string
}
