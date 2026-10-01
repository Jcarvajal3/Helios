import { llamarRpc } from '@/features/admin/metricas/consulta'
import type { PayoutMethod } from '@/features/admin/liquidaciones'
import { supabase } from '@/lib/supabase'
import { BUCKET_COMPROBANTES, extensionDelComprobante, leerPagoRegistrado, rutaDelComprobante } from './registrarPago'
import type { PagoRegistrado } from './registrarPago'

// ═══════════════════════════════════════════════════════════════════════════
// Registrar un pago recibido por WhatsApp: subir la captura y llamar a
// `admin_register_payment` (contrato §2.1). Operador o super admin.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Sube la captura al bucket privado `payment-receipts` y devuelve la ruta
 * (no una URL): la fila guarda la ruta y el enlace se firma al mirarla, como
 * los comprobantes de las transferencias a clínicas.
 */
export async function subirComprobanteDePago(params: { userId: string; file: File }): Promise<string> {
  const ext = extensionDelComprobante(params.file)
  if (!ext) throw new Error('La captura tiene que ser una imagen o un PDF.')
  const ruta = rutaDelComprobante(params.userId, crypto.randomUUID(), ext)

  const { error } = await supabase.storage
    .from(BUCKET_COMPROBANTES)
    .upload(ruta, params.file, { contentType: params.file.type || undefined, upsert: false })
  if (error) throw error
  return ruta
}

/** Enlace firmado para mirar la captura de un pago. Caduca en diez minutos. */
export async function enlaceDelComprobanteDePago(ruta: string): Promise<string> {
  const { data, error } = await supabase.storage.from(BUCKET_COMPROBANTES).createSignedUrl(ruta, 600)
  if (error) throw error
  return data.signedUrl
}

export async function registrarPago(params: {
  userId: string
  installmentIds: string[]
  method: PayoutMethod
  bank: string | null
  reference: string
  paidOn: string
  /** Lo que dice el comprobante; `null` si fue en dólares. */
  amountVes: number | null
  receiptPath: string | null
  note: string | null
}): Promise<PagoRegistrado> {
  return llamarRpc(
    'admin_register_payment',
    {
      p_user: params.userId,
      p_installment_ids: params.installmentIds,
      p_method: params.method,
      p_bank: params.bank,
      p_reference: params.reference.trim(),
      p_paid_on: params.paidOn,
      p_amount_ves: params.amountVes,
      p_receipt_path: params.receiptPath,
      p_note: params.note?.trim() || null,
    },
    { leer: leerPagoRegistrado },
  )
}
