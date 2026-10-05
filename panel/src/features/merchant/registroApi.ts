import { supabase } from '@/lib/supabase'

import {
  leerElegibilidad,
  leerFinanciamiento,
  leerReenvio,
  leerVistaPrevia,
} from './registro'
import type { Elegibilidad, Financiamiento, Reenvio, VistaPrevia } from './registro'

// ═══════════════════════════════════════════════════════════════════════════
// Las llamadas del alta. Cada una lanza el error de PostgREST tal cual: el
// texto lo escribe la base en español para enseñarlo sin tocar
// (`describeError`), y el `code` decide qué se hace con él.
// ═══════════════════════════════════════════════════════════════════════════

/** Paso 1: ¿se puede financiar a esta cédula? (contrato §1.1) */
export async function consultarCedula(params: {
  merchantId: string
  document: string
}): Promise<Elegibilidad> {
  const { data, error } = await supabase.rpc('helios_patient_eligibility', {
    p_merchant_id: params.merchantId,
    p_document: params.document,
  })
  if (error) throw error
  return leerElegibilidad(data)
}

/** Paso 4: las dos cuotas con sus fechas, sin crear nada (contrato §1.2). */
export async function fetchVistaPrevia(params: {
  merchantId: string
  document: string
  amountUsd: number
}): Promise<VistaPrevia> {
  const { data, error } = await supabase.rpc('preview_patient_charge', {
    p_merchant_id: params.merchantId,
    p_document: params.document,
    p_amount_usd: params.amountUsd,
  })
  if (error) throw error
  return leerVistaPrevia(data)
}

/**
 * ¿Espera la orden el «Sí» del paciente por WhatsApp? (contrato §1.3.1). Lo
 * decide Helios con un interruptor; cambia lo que dice el paso de confirmar.
 */
export async function fetchConfirmacionRequerida(): Promise<boolean> {
  const { data, error } = await supabase.rpc('helios_patient_confirmation_required')
  if (error) throw error
  return data === true
}

/**
 * Paso 5: el alta (contrato §1.3). Con la confirmación del paciente crea la
 * orden PENDIENTE: la deuda existe cuando el paciente responde Sí.
 *
 * `patient` lleva solo `{ document }` si el paciente ya existe: la base no
 * sobrescribe nada de un paciente conocido, y mandarle unos datos que la
 * secretaria no ha podido ver sería inventarlos.
 */
export async function registrarFinanciamiento(params: {
  merchantId: string
  branchId: string | null
  patient: Record<string, string | null>
  amountUsd: number
  concept: string | null
  beneficiaryName: string | null
  idempotencyKey: string
}): Promise<Financiamiento> {
  const { data, error } = await supabase.rpc('create_patient_charge', {
    p_merchant_id: params.merchantId,
    p_branch_id: params.branchId,
    p_patient: params.patient,
    p_amount_usd: params.amountUsd,
    p_concept: params.concept,
    p_beneficiary_name: params.beneficiaryName,
    p_idempotency_key: params.idempotencyKey,
  })
  if (error) throw error
  return leerFinanciamiento(data)
}

/**
 * Cómo está un financiamiento ahora (`helios_charge_for_staff`). La pantalla
 * de espera lo vuelve a pedir cada pocos segundos mientras la orden espera.
 */
export async function fetchFinanciamiento(chargeId: string): Promise<Financiamiento> {
  const { data, error } = await supabase.rpc('helios_charge_for_staff', {
    p_charge_id: chargeId,
  })
  if (error) throw error
  return leerFinanciamiento(data)
}

/**
 * «Reenviar al paciente» (contrato §1.3.2): otra pregunta por WhatsApp. Una
 * orden vencida se reabre con plazo nuevo y las fechas de hoy.
 */
export async function reenviarConfirmacion(chargeId: string): Promise<Financiamiento> {
  const { data, error } = await supabase.rpc('staff_resend_confirmation', {
    p_charge_id: chargeId,
  })
  if (error) throw error
  return leerFinanciamiento(data)
}

/** Vuelve a mandar el comprobante al correo REGISTRADO (contrato §1.4). */
export async function reenviarComprobante(chargeId: string): Promise<Reenvio> {
  const { data, error } = await supabase.rpc('staff_resend_receipt', {
    p_charge_id: chargeId,
  })
  if (error) throw error
  return leerReenvio(data)
}
