/**
 * Helios Lab — operación del equipo: inventario de kits, logística y ruta del
 * driver (docs/09-HELIOS-LAB.md §5.2). Aquí están las llamadas a las RPC
 * `admin_lab_*`, `lab_ruta_del_dia` y `lab_parada_completar`; la lectura de
 * sus respuestas está en `operacionLogica.ts`.
 */
import { queryOptions } from '@tanstack/react-query'

import { llamarRpc } from '@/features/admin/metricas/consulta'
import { leerInventarioDeMedicos, leerKits, leerLogistica, leerRuta } from '@/features/lab/operacionLogica'
import type { KitTipo } from '@/features/lab/tipos'
import { describeError } from '@/lib/supabase'

export * from '@/features/lab/operacionLogica'

export const CLAVE_LAB_OPERACION = ['lab-operacion'] as const

// ── Errores ────────────────────────────────────────────────────────────────

/** El mensaje de un error de la base, en castellano y sin jerga. */
export function mensajeDeErrorLab(error: unknown): string {
  const codigo = typeof error === 'object' && error !== null ? (error as { code?: unknown }).code : undefined
  if (codigo === '42501') return 'No tienes permiso para hacer esto en Helios Lab.'
  if (codigo === 'P0002') return 'Eso ya no existe o cambió. Actualiza la pantalla e inténtalo de nuevo.'
  return describeError(error) ?? 'No se pudo completar. Inténtalo de nuevo.'
}

/** Una clave nueva para una operación idempotente (misma clave, mismo efecto). */
export function claveDeOperacion(): string {
  return globalThis.crypto.randomUUID()
}

// ── Consultas ──────────────────────────────────────────────────────────────

export function consultaKits() {
  return queryOptions({
    queryKey: [...CLAVE_LAB_OPERACION, 'kits'],
    queryFn: ({ signal }) => llamarRpc('admin_lab_kits', undefined, { signal, leer: leerKits }),
    refetchOnWindowFocus: true,
  })
}

export function consultaInventarioDeMedicos() {
  return queryOptions({
    queryKey: [...CLAVE_LAB_OPERACION, 'inventario-por-medico'],
    queryFn: ({ signal }) =>
      llamarRpc('admin_lab_inventario_por_medico', undefined, { signal, leer: leerInventarioDeMedicos }),
    refetchOnWindowFocus: true,
  })
}

export function consultaLogistica(fecha: string) {
  return queryOptions({
    queryKey: [...CLAVE_LAB_OPERACION, 'logistica', fecha],
    queryFn: ({ signal }) => llamarRpc('admin_lab_logistica', { p_fecha: fecha }, { signal, leer: leerLogistica }),
    refetchOnWindowFocus: true,
  })
}

/** La ruta de un día: la leen Logística (armar y ordenar) y la pantalla del driver. */
export function consultaRutaDelDia(fecha: string, opciones: { cadaMinuto?: boolean } = {}) {
  return queryOptions({
    queryKey: [...CLAVE_LAB_OPERACION, 'ruta', fecha],
    queryFn: ({ signal }) => llamarRpc('lab_ruta_del_dia', { p_fecha: fecha }, { signal, leer: leerRuta }),
    refetchOnWindowFocus: true,
    refetchInterval: opciones.cadaMinuto ? 60_000 : false,
  })
}

// ── Escrituras ─────────────────────────────────────────────────────────────

export async function guardarMinimos(params: { tipo: KitTipo; minimoHelios: number; minimoPorMedico: number }) {
  await llamarRpc('admin_lab_kit_minimo_guardar', {
    p_tipo: params.tipo,
    p_minimo_helios: params.minimoHelios,
    p_minimo_por_medico: params.minimoPorMedico,
  })
}

export type MovimientoDeKits = {
  tipo: 'entrada' | 'ajuste'
  kit: KitTipo
  cantidad: number
  nota: string
  /** Misma clave en cada reintento del mismo formulario. */
  clave: string
  merchantId?: string | null
}

export async function registrarMovimiento(m: MovimientoDeKits) {
  await llamarRpc('admin_lab_kit_movimiento', {
    p_tipo: m.tipo,
    p_kit_tipo: m.kit,
    p_cantidad: m.cantidad,
    p_merchant_id: m.merchantId ?? null,
    p_nota: m.nota.trim() === '' ? null : m.nota.trim(),
    p_idempotency_key: m.clave,
  })
}

export async function armarRuta(fecha: string) {
  await llamarRpc('admin_lab_ruta_armar', { p_fecha: fecha })
}

export async function moverParada(paradaId: string, orden: number) {
  await llamarRpc('admin_lab_parada_mover', { p_parada_id: paradaId, p_orden: orden })
}

export async function fijarKitsDeParada(paradaId: string, kit: KitTipo, cantidad: number) {
  await llamarRpc('admin_lab_parada_kits', { p_parada_id: paradaId, p_kit_tipo: kit, p_cantidad: cantidad })
}

export async function iniciarRuta(fecha: string) {
  await llamarRpc('admin_lab_ruta_iniciar', { p_fecha: fecha })
}

export async function completarParada(paradaId: string, nota: string) {
  await llamarRpc('lab_parada_completar', {
    p_parada_id: paradaId,
    p_nota: nota.trim() === '' ? null : nota.trim(),
  })
}

