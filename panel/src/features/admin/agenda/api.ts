import { queryOptions } from '@tanstack/react-query'
import type { QueryClient } from '@tanstack/react-query'

import { supabase } from '@/lib/supabase'
import { comoFila, comoLista, numero, texto, textoONulo } from '@/lib/json'
import { unoDe } from '@/lib/busqueda'
import { ESTADOS_DEL_LEAD, FASES, aDatos, aParametros, leerAgenda, leerHistoria } from './agenda'
import type { BorradorDeGestion, BorradorDeLead, CanalDelLead, EstadoDelLead, Fase, Resultado } from './agenda'

// ═══════════════════════════════════════════════════════════════════════════
// Las lecturas y las escrituras de la Agenda, con sus claves de caché.
//
// Todo cuelga de ['admin-agenda', …]: guardar, anotar o borrar invalida el
// tablero y la historia de una vez.
// ═══════════════════════════════════════════════════════════════════════════

const CLAVE_AGENDA = ['admin-agenda'] as const

/** Todos los médicos por afiliar, con su estado, su reunión y su última gestión. */
export function consultaAgenda() {
  return queryOptions({
    queryKey: [...CLAVE_AGENDA, 'tablero'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('admin_doctor_leads')
      if (error) throw error
      return leerAgenda(data)
    },
  })
}

/** La historia de un lead, lo último primero. */
export function consultaHistoria(leadId: string) {
  return queryOptions({
    queryKey: [...CLAVE_AGENDA, 'historia', leadId],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('admin_doctor_lead_activities', { p_lead_id: leadId })
      if (error) throw error
      return leerHistoria(data)
    },
  })
}

/**
 * El equipo activo, para elegir quién gestiona a cada médico. Es la lista de
 * `admin_agenda_team` y no la de Ajustes › Equipo, que el rol de la agenda
 * no puede leer.
 */
export function consultaEquipoDeLaAgenda() {
  return queryOptions({
    queryKey: [...CLAVE_AGENDA, 'equipo'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('admin_agenda_team')
      if (error) throw error
      return comoLista(data).map((fila) => {
        const r = comoFila(fila)
        return {
          userId: texto(r.user_id),
          nombre: texto(r.name, 'Sin nombre'),
          rol: texto(r.role),
          /** Las fases en que trabaja: deciden el reparto automático. */
          fases: comoLista(r.stages).flatMap((s) => unoDe(FASES, s) ?? []),
        }
      })
    },
    staleTime: 5 * 60 * 1000,
  })
}

/** Cambia las fases en que trabaja alguien del equipo (super admin). */
export async function guardarFasesDe(userId: string, fases: readonly Fase[]): Promise<void> {
  const { error } = await supabase.rpc('admin_set_agenda_phases', { p_user_id: userId, p_stages: [...fases] })
  if (error) throw error
}

export type ActividadDeUnaPersona = {
  userId: string
  nombre: string
  gestiones: number
  mensajes: number
  interesados: number
  llamadas: number
  visitasAgendadas: number
  visitasRealizadas: number
  ultima: string | null
}

/** Lo que hizo cada persona, por quien anotó cada gestión (no por quién lleva hoy al médico). */
export function consultaActividadPorPersona() {
  return queryOptions({
    queryKey: [...CLAVE_AGENDA, 'actividad'],
    queryFn: async (): Promise<ActividadDeUnaPersona[]> => {
      const { data, error } = await supabase.rpc('admin_agenda_activity_by_person', {})
      if (error) throw error
      return comoLista(data).map((fila) => {
        const r = comoFila(fila)
        return {
          userId: texto(r.user_id),
          nombre: texto(r.name, 'Sin nombre'),
          gestiones: numero(r.gestiones),
          mensajes: numero(r.mensajes),
          interesados: numero(r.interesados),
          llamadas: numero(r.llamadas),
          visitasAgendadas: numero(r.visitas_agendadas),
          visitasRealizadas: numero(r.visitas_realizadas),
          ultima: textoONulo(r.ultima),
        }
      })
    },
  })
}

export type LeadGuardado = {
  id: string
  estado: EstadoDelLead
  /** La clínica, si al guardarlo resultó que ya es cliente. */
  clinica: string | null
}

/**
 * Apunta un médico (`leadId` null) o corrige sus datos. La base rechaza, con
 * un mensaje que se puede enseñar tal cual, un teléfono o un correo que ya
 * están en la agenda; y si el médico ya es cliente, lo deja afiliado.
 */
export async function guardarLead(leadId: string | null, borrador: BorradorDeLead): Promise<LeadGuardado> {
  // `p_lead_id` va en null y no en `undefined`: sin la clave, PostgREST busca
  // una función que solo recibe `p`, y no existe.
  const { data, error } = await supabase.rpc('admin_save_doctor_lead', {
    p_lead_id: leadId,
    p: aDatos(borrador),
  })
  if (error) throw error
  const r = comoFila(data)
  return {
    id: texto(r.id),
    estado: unoDe(ESTADOS_DEL_LEAD, r.status) ?? 'nuevo',
    clinica: textoONulo(r.merchant_name),
  }
}

/** Anota una gestión con su resultado (mensaje, llamada o visita). El estado sale de él. */
export async function anotarGestion(
  leadId: string,
  resultado: Resultado,
  canal: CanalDelLead | null,
  borrador: BorradorDeGestion,
): Promise<void> {
  const { error } = await supabase.rpc('admin_log_doctor_lead_contact', aParametros(leadId, resultado, canal, borrador))
  if (error) throw error
}

/**
 * Le asigna a quien llama hasta `cantidad` médicos al azar que no tienen a
 * nadie y siguen abiertos. Devuelve cuántos le tocaron (0 si no quedaba
 * ninguno libre).
 */
export async function asignarmeMedicos(cantidad = 20): Promise<number> {
  const { data, error } = await supabase.rpc('admin_assign_me_doctor_leads', { p_cantidad: cantidad })
  if (error) throw error
  return typeof data === 'number' ? data : Number(data ?? 0)
}

/** Borra un lead y su historia. La bitácora guarda sus datos. */
export async function borrarLead(leadId: string): Promise<void> {
  const { error } = await supabase.rpc('admin_delete_doctor_lead', { p_lead_id: leadId })
  if (error) throw error
}

export function refrescarAgenda(client: QueryClient): void {
  void client.invalidateQueries({ queryKey: CLAVE_AGENDA })
}
