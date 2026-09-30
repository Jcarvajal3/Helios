import { supabase } from '@/lib/supabase'

/**
 * La bandera de cuenta de prueba.
 *
 * Marcar a alguien la saca de **todas** las cifras y de todas las colas, y
 * deja de recibir promociones. Sigue apareciendo en listas y búsquedas, con su
 * etiqueta, y sus consumos siguen escribiéndose en el libro marcados como
 * prueba: una prueba tiene que dejar rastro, solo que no puede contaminar la
 * contabilidad.
 *
 * Al cambiarla, el servidor recoloca los consumos y las cuotas que ya existían:
 * marcar hoy no deja lo de ayer contando como real para siempre.
 */
export async function setTestAccount(params: {
  kind: 'user' | 'merchant'
  id: string
  flag: boolean
  note?: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_test_account', {
    p_kind: params.kind,
    p_id: params.id,
    p_flag: params.flag,
    p_note: params.note ?? null,
  })
  if (error) throw error
}
