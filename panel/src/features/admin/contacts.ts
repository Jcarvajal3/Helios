import { unoDe } from '@/lib/busqueda'
import { supabase } from '@/lib/supabase'
import { CANALES, RESULTADOS } from '@/features/admin/cobranza/gestion'
import type { Canal, GestionNueva, Resultado } from '@/features/admin/cobranza/gestion'
import { comoLista, comoFila, texto, textoONulo } from '@/lib/json'
import { VALORES_ESTADO_PROMESA } from '@/features/admin/estados'
import type { EstadoPromesa } from '@/features/admin/estados'

/**
 * Las gestiones de cobranza.
 *
 * Sin registro, dos personas llaman al mismo usuario el mismo día y nadie
 * sabe qué dijo. Cada gestión guarda por dónde, qué pasó, qué prometió y
 * cuándo hay que volver a llamar. La promesa **no cambia lo que hace el
 * estado automático**: es información para quien retome el caso.
 */
export type CollectionContact = {
  id: string
  contactedAt: string
  channel: Canal
  /** Qué plantilla se mandó, si se mandó una. */
  template: string | null
  note: string | null
  promiseDate: string | null
  actorName: string
  /** Null en las gestiones anotadas antes de que existiera el resultado. */
  outcome: Resultado | null
  /** 'YYYY-MM-DD': el día en que hay que volver a llamar. */
  nextActionOn: string | null
  /** Null si la gestión no traía promesa. */
  promiseStatus: EstadoPromesa | null
}

/** El tope que acepta la base: `admin_user_contacts` no devuelve más. */
export const MAXIMO_DE_GESTIONES = 100

function leerGestion(raw: unknown): CollectionContact {
  const r = comoFila(raw)
  return {
    id: texto(r.id),
    contactedAt: texto(r.contacted_at),
    channel: unoDe(CANALES, r.channel) ?? 'otro',
    template: textoONulo(r.template),
    note: textoONulo(r.note),
    promiseDate: textoONulo(r.promise_date),
    actorName: texto(r.actor_name, 'Alguien del equipo'),
    outcome: unoDe(RESULTADOS, r.outcome) ?? null,
    nextActionOn: textoONulo(r.next_action_on),
    promiseStatus: unoDe(VALORES_ESTADO_PROMESA, r.promise_status) ?? null,
  }
}

/** Las gestiones de una persona, la última primero. */
export async function fetchUserContacts(
  userId: string,
  limit = 20,
): Promise<CollectionContact[]> {
  const { data, error } = await supabase.rpc('admin_user_contacts', {
    p_user: userId,
    p_limit: limit,
  })
  if (error) throw error
  return comoLista(data).map(leerGestion)
}

/**
 * Anota una gestión. La base rechaza, con un mensaje que se puede enseñar tal
 * cual, una promesa o una próxima acción en el pasado y una promesa sin fecha.
 */
export async function logContact(userId: string, g: GestionNueva): Promise<void> {
  const { error } = await supabase.rpc('admin_log_contact', {
    p_user: userId,
    p_channel: g.canal,
    p_note: g.nota,
    p_template: g.plantilla,
    p_promise_date: g.fechaPrometida,
    p_outcome: g.resultado,
    p_next_action_on: g.volverALlamar,
  })
  if (error) throw error
}
