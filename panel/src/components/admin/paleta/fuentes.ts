import { booleano, filas, numeroONulo, texto, textoONulo } from '@/lib/json'
import { supabase } from '@/lib/supabase'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que la paleta le pregunta al servidor y no tenía ya una función.
//
// Personas, consumos y locales usan las funciones de siempre (`fetchUsers`,
// `fetchCharges`, `fetchMerchants`), con claves de caché propias donde el
// resultado es distinto al de su pantalla. Esto es solo lo que faltaba: los
// pagos reportados por referencia, en TODOS los estados.
// ═══════════════════════════════════════════════════════════════════════════

/** Un pago reportado encontrado por su referencia. */
export type PagoEncontrado = {
  reportId: string
  reference: string | null
  bank: string | null
  status: string
  createdAt: string
  userId: string
  fullName: string | null
  /** Lo que la persona tenía que transferir, en bolívares. */
  amountVes: number | null
  /** Cuenta de prueba: se encuentra igual, con su etiqueta. */
  isTest: boolean
}

/** Cuántos candidatos se piden: la paleta los vuelve a ordenar y enseña cinco. */
const CANDIDATOS = 20

/**
 * Los pagos reportados cuya referencia casa con `aguja`, de cualquier estado,
 * con el nombre de la persona en la misma llamada
 * (`admin_search_payment_reports`, migración 20260925135000).
 *
 * La base compara solo letras y cifras («12-36-54» encuentra «123654») y pone
 * primero la exacta y después la que termina así. Con menos de tres letras o
 * cifras devuelve una lista vacía.
 */
export async function buscarPagosPorReferencia(aguja: string): Promise<PagoEncontrado[]> {
  const { data, error } = await supabase.rpc('admin_search_payment_reports', {
    p_reference: aguja,
    p_limit: CANDIDATOS,
  })
  if (error) throw error

  return filas(data).map((f) => ({
    reportId: texto(f.report_id),
    reference: textoONulo(f.reference),
    bank: textoONulo(f.bank),
    status: texto(f.status),
    createdAt: texto(f.created_at),
    userId: texto(f.user_id),
    fullName: textoONulo(f.full_name),
    amountVes: numeroONulo(f.amount_ves),
    isTest: booleano(f.is_test),
  }))
}
