import { comoFila } from '@/lib/json'
import { supabase } from '@/lib/supabase'

/**
 * El freno de emergencia global.
 *
 * Lo lee cualquiera con sesión —el panel del comercio lo pinta como banner
 * para que el cajero no genere QR que van a rebotar— y solo lo mueve un super
 * admin. Ver la migración 20260909160000.
 */
export type Maintenance = {
  isActive: boolean
  /** false = solo avisa; el saldo de la gente sigue funcionando. */
  blocksBalance: boolean
  title: string
  message: string
  /** Texto libre: "hoy a las 10 PM". Una fecha exacta que luego se incumple
   *  es peor que no prometer nada. */
  expectedBack: string | null
  /** Cuándo empezó este episodio. Null si está apagado. */
  startedAt: string | null
  updatedAt: string
}

function toMaintenance(fila: unknown): Maintenance {
  const raw = comoFila(fila)
  return {
    isActive: Boolean(raw.is_active),
    blocksBalance: Boolean(raw.blocks_balance),
    title: String(raw.title),
    message: String(raw.message),
    expectedBack: typeof raw.expected_back === 'string' ? raw.expected_back : null,
    startedAt: typeof raw.started_at === 'string' ? raw.started_at : null,
    updatedAt: String(raw.updated_at),
  }
}

export async function fetchMaintenance(): Promise<Maintenance> {
  const { data, error } = await supabase.rpc('helios_maintenance')
  if (error) throw error
  return toMaintenance(data)
}

export async function setMaintenance(params: {
  isActive: boolean
  blocksBalance: boolean
  title: string
  message: string
  expectedBack?: string
  /** El motivo del diálogo al encender: va a la bitácora (`maintenance.on`). */
  note?: string | null
}): Promise<Maintenance> {
  const { data, error } = await supabase.rpc('admin_set_maintenance', {
    p_is_active: params.isActive,
    p_blocks_balance: params.blocksBalance,
    p_title: params.title,
    p_message: params.message,
    p_expected_back: params.expectedBack ?? null,
    p_note: params.note || null,
  })
  if (error) throw error
  return toMaintenance(data)
}
