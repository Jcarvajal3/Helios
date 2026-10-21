import { supabase } from '@/lib/supabase'
import { leerLectura, leerRevisionLector } from './lectorComprobantes'
import type { Lectura, ModoLector, RevisionLector } from './lectorComprobantes'

/** Las llamadas del lector de comprobantes. La lógica pura vive en `lectorComprobantes.ts`. */

/** Las lecturas de un rango de días (por el día en que llegaron) y el modo del lector. */
export async function fetchRevisionLector(desde: string, hasta: string): Promise<RevisionLector> {
  const { data, error } = await supabase.rpc('admin_receipt_reads', { p_from: desde, p_to: hasta })
  if (error) throw error
  return leerRevisionLector(data)
}

/** La última lectura de un paciente que el bot no convirtió en pago (7 días), o null. */
export async function fetchUltimaLectura(userId: string): Promise<Lectura | null> {
  const { data, error } = await supabase.rpc('admin_receipt_read_latest', { p_user: userId })
  if (error) throw error
  return data ? leerLectura(data) : null
}

/** La lectura que creó un pago, o null si lo registró el equipo. */
export async function fetchLecturaDelPago(reportId: string): Promise<Lectura | null> {
  const { data, error } = await supabase.rpc('admin_receipt_read_for_report', { p_report_id: reportId })
  if (error) throw error
  return data ? leerLectura(data) : null
}

/** Solo el super admin, con motivo. */
export async function cambiarModoLector(modo: ModoLector, motivo: string): Promise<void> {
  const { error } = await supabase.rpc('admin_set_receipt_reader_mode', { p_mode: modo, p_note: motivo })
  if (error) throw error
}
