import { queryOptions } from '@tanstack/react-query'
import type { QueryClient } from '@tanstack/react-query'

import { fetchCollectionTemplates } from '@/features/admin/ajustes'
import { MAXIMO_DE_GESTIONES, fetchUserContacts } from '@/features/admin/contacts'
import { fetchFxStatus } from '@/features/admin/fx'
import { fetchUserLateFees } from '@/features/admin/lateFees'
import { fetchPaymentDestinations } from '@/features/admin/ops'
import { supabase } from '@/lib/supabase'
import { HORIZONTE_CARTERA, leerCartera, leerCasoDeCobranza } from './cartera'
import type { CollectionQueue, CollectionRow } from './cartera'
import { llamarRpc } from '@/features/admin/metricas/consulta'
import { leerDeudoresDeLaSemana } from './deudoresDeLaSemana'
import { leerPerfilDeMorosos } from './perfilDeMorosos'
import type { PerfilDeMorosos } from './perfilDeMorosos'
import type { DeudoresDeLaSemana } from './deudoresDeLaSemana'
import { leerPromesas } from './promesas'
import type { Promesas } from './promesas'
import { leerCura, leerEfectividadDeCobranza, leerRecuperado } from './rendimiento'
import type { Cura, EfectividadDeCobranza, Recuperado } from './rendimiento'

// ═══════════════════════════════════════════════════════════════════════════
// Las lecturas de Cobranza y sus claves de caché.
//
// Las claves que ya usaban otras pantallas se conservan tal cual: la cartera
// comparte `['admin-collections', 7]` con Inicio, y los cargos por atraso
// `['admin-late-fees', id]` con la pestaña de consumos de la ficha. Así una
// misma cifra sale de una sola llamada y no puede decir dos cosas.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * La cartera. Con `cohorte` (el lunes de una semana de consumo), solo la
 * gente que debe algo vencido de lo consumido esa semana, con sus importes de
 * siempre: la cola es por persona.
 */
export async function fetchCollections(horizonDays = 3, cohorte?: string): Promise<CollectionQueue> {
  const { data, error } = await supabase.rpc('admin_collections', {
    p_horizon_days: horizonDays,
    ...(cohorte ? { p_cohorte: cohorte } : {}),
  })
  if (error) throw error
  return leerCartera(data)
}

/**
 * La fila de la cartera de una persona, sin pedir la cartera entera: con el
 * mismo horizonte que la lista, es idéntica a su fila de allí. `null` si no
 * está en la cartera.
 */
export async function fetchCasoDeCobranza(userId: string): Promise<CollectionRow | null> {
  const { data, error } = await supabase.rpc('admin_collection_case', {
    p_user: userId,
    p_horizon_days: HORIZONTE_CARTERA,
  })
  if (error) throw error
  return leerCasoDeCobranza(data)
}

/** Las promesas de los últimos 30 días operativos y todas las futuras. */
export async function fetchPromesas(): Promise<Promesas> {
  const { data, error } = await supabase.rpc('admin_collection_promises', {})
  if (error) throw error
  return leerPromesas(data)
}

/** Lo recuperado entre dos días operativos, los dos incluidos. */
export async function fetchRecuperado(desde: string, hasta: string): Promise<Recuperado> {
  const { data, error } = await supabase.rpc('admin_collection_recovered', {
    p_from: desde,
    p_to: hasta,
  })
  if (error) throw error
  return leerRecuperado(data)
}

/** La cura por tramo de las últimas `semanas` semanas, lunes a lunes. */
export async function fetchCura(semanas: number): Promise<Cura> {
  const { data, error } = await supabase.rpc('admin_collection_flow', { p_weeks: semanas })
  if (error) throw error
  return leerCura(data)
}

/** Las gestiones entre dos días de Caracas, con o sin pago en 72 h. */
export async function fetchEfectividad(
  desde: string,
  hasta: string,
): Promise<EfectividadDeCobranza> {
  const { data, error } = await supabase.rpc('admin_contact_effectiveness', {
    p_from: desde,
    p_to: hasta,
  })
  if (error) throw error
  return leerEfectividadDeCobranza(data)
}

// ── Las consultas, listas para `useQuery` ──────────────────────────────────

/**
 * La cartera. Se refresca cada minuto: la columna del último contacto existe
 * para no llamar dos veces a la misma persona, y con una sola gestora eso
 * pasa si la lista se queda vieja en otra pestaña.
 */
export function consultaCartera(cohorte?: string, horizonte: number = HORIZONTE_CARTERA) {
  return queryOptions({
    // Sin cohorte y a 7 días, la clave de siempre (la comparten Inicio y la
    // insignia). La Lista de Por cobrar pide la cola entera (HORIZONTE_TODO).
    queryKey: cohorte
      ? ['admin-collections', horizonte, 'cohorte', cohorte]
      : ['admin-collections', horizonte],
    queryFn: () => fetchCollections(horizonte, cohorte),
    refetchInterval: 60_000,
  })
}

/**
 * Quién debe de lo consumido una semana (Por cobrar › Cohortes). La clave
 * cuelga de `admin-collections`: anotar una gestión la refresca igual que a
 * la cola.
 */
export function consultaDeudoresDeLaSemana(lunes: string, local: string | null) {
  return queryOptions({
    queryKey: ['admin-collections', 'semana', lunes, local],
    // Con reloj: una lectura que no contesta tiene que acabar en error, no en
    // un esqueleto para siempre.
    queryFn: ({ signal }): Promise<DeudoresDeLaSemana> =>
      llamarRpc(
        'admin_deudores_de_la_semana',
        { p_semana: lunes, p_merchant_id: local },
        { signal, leer: leerDeudoresDeLaSemana },
      ),
    refetchInterval: 60_000,
    placeholderData: (previa) => previa,
  })
}

/** Cómo es quien debe algo vencido, frente a quien está al día (Por cobrar › Morosos). */
export function consultaPerfilDeMorosos() {
  return queryOptions({
    queryKey: ['admin-collections', 'perfil-morosos'],
    queryFn: ({ signal }): Promise<PerfilDeMorosos> =>
      llamarRpc('admin_perfil_de_morosos', {}, { signal, leer: leerPerfilDeMorosos }),
  })
}

/**
 * El caso de una persona, para su ficha. La clave cuelga de
 * `admin-collections`: lo que refresca la cartera (anotar una gestión, asignar
 * un abono) refresca también el caso.
 */
export function consultaCasoDeCobranza(userId: string) {
  return queryOptions({
    queryKey: ['admin-collections', 'caso', userId, HORIZONTE_CARTERA],
    queryFn: () => fetchCasoDeCobranza(userId),
    refetchInterval: 60_000,
  })
}

export function consultaPlantillas() {
  return queryOptions({ queryKey: ['collection-templates'], queryFn: fetchCollectionTemplates })
}

export function consultaTasa() {
  return queryOptions({ queryKey: ['fx-status'], queryFn: () => fetchFxStatus() })
}

/** La tasa BCV del euro: la de las órdenes en euros. Misma clave que Ajustes › Tasa BCV. */
export function consultaTasaEuro() {
  return queryOptions({ queryKey: ['fx-status', 'EUR'], queryFn: () => fetchFxStatus('EUR') })
}

export function consultaCuentasDeCobro() {
  return queryOptions({ queryKey: ['payment-destinations'], queryFn: fetchPaymentDestinations })
}

/** Las gestiones de una persona, hasta el tope de la base. */
export function consultaGestiones(userId: string) {
  return queryOptions({
    queryKey: ['admin-contacts', userId, MAXIMO_DE_GESTIONES],
    queryFn: () => fetchUserContacts(userId, MAXIMO_DE_GESTIONES),
  })
}

export function consultaCargosPorAtraso(userId: string) {
  return queryOptions({
    queryKey: ['admin-late-fees', userId],
    queryFn: () => fetchUserLateFees(userId),
  })
}

export function consultaPromesas() {
  return queryOptions({
    queryKey: ['cobranza', 'promesas'],
    queryFn: fetchPromesas,
    refetchInterval: 60_000,
  })
}

export function consultaRecuperado(desde: string, hasta: string) {
  return queryOptions({
    queryKey: ['cobranza', 'recuperado', desde, hasta],
    queryFn: () => fetchRecuperado(desde, hasta),
  })
}

export function consultaCura(semanas: number) {
  return queryOptions({
    queryKey: ['cobranza', 'cura', semanas],
    queryFn: () => fetchCura(semanas),
  })
}

export function consultaEfectividad(desde: string, hasta: string) {
  return queryOptions({
    queryKey: ['cobranza', 'efectividad', desde, hasta],
    queryFn: () => fetchEfectividad(desde, hasta),
  })
}

/**
 * Lo que cambia al anotar una gestión: la cartera (último contacto, promesa),
 * el caso de esa persona, las promesas, la efectividad y la bitácora.
 */
export function refrescarTrasAnotar(client: QueryClient, userId: string): void {
  void client.invalidateQueries({ queryKey: ['admin-collections'] })
  void client.invalidateQueries({ queryKey: ['admin-contacts', userId] })
  void client.invalidateQueries({ queryKey: ['cobranza'] })
  void client.invalidateQueries({ queryKey: ['admin-audit'] })
}
