import { queryOptions } from '@tanstack/react-query'

import { llamarRpc } from '@/features/admin/metricas/consulta'
import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'
import { leerAviso } from './avisos'
import type { Aviso, CanalAviso, EstadoAviso } from './avisos'

// ═══════════════════════════════════════════════════════════════════════════
// Las lecturas y escrituras de Avisos (contrato §2.2) y sus claves de caché.
//
// Todo cuelga de ['admin-avisos', …]: marcar un aviso invalida la cola del
// día, el historial y los contadores del menú y de Inicio de una vez.
// ═══════════════════════════════════════════════════════════════════════════

export const CLAVE_AVISOS = ['admin-avisos'] as const

/** Cada minuto: la cola la generan los crons y la vacía el equipo. */
const CADA_MINUTO = 60_000

/** La cola de un día (por defecto, hoy en Caracas) de un canal. */
export function consultaColaDeAvisos(dia: string, canal: CanalAviso = 'whatsapp_manual') {
  return queryOptions({
    queryKey: [...CLAVE_AVISOS, 'cola', canal, dia],
    queryFn: ({ signal }) =>
      llamarRpc('admin_outbound_queue', { p_day: dia, p_channel: canal }, {
        signal,
        leer: (d) => comoLista(d).map(leerAviso),
      }),
    refetchInterval: CADA_MINUTO,
  })
}

/** Una página del historial. `total` si la base lo manda (`total_count`), si no `null`. */
export type PaginaDeAvisos = { filas: Aviso[]; total: number | null }

export function consultaHistorialDeAvisos(f: {
  canal: CanalAviso
  estado?: EstadoAviso | null
  q?: string | null
  limite: number
  desde: number
}) {
  return queryOptions({
    queryKey: [...CLAVE_AVISOS, 'historial', f.canal, f.estado ?? null, f.q ?? null, f.limite, f.desde],
    queryFn: ({ signal }) =>
      llamarRpc(
        'admin_outbound_history',
        {
          p_channel: f.canal,
          p_status: f.estado ?? null,
          p_q: f.q?.trim() || null,
          p_limit: f.limite,
          p_offset: f.desde,
        },
        {
          signal,
          leer: (d): PaginaDeAvisos => {
            const lista = comoLista(d)
            return {
              filas: lista.map(leerAviso),
              total: lista.length > 0 ? numeroONulo(comoFila(lista[0]).total_count) : 0,
            }
          },
        },
      ),
  })
}

/** Los últimos correos, para contar los rebotados sin corregir (Inicio y el menú). */
export const TOPE_CORREOS_RECIENTES = 200

export function consultaCorreosRecientes() {
  return queryOptions({
    ...consultaHistorialDeAvisos({ canal: 'email', limite: TOPE_CORREOS_RECIENTES, desde: 0 }),
    refetchInterval: 5 * CADA_MINUTO,
  })
}

/**
 * Marca un aviso. `enviado` además deja la gestión en `collection_contacts`
 * (canal WhatsApp); `omitido` exige nota. Operador o super admin.
 */
export async function marcarAviso(params: { id: string; estado: EstadoAviso; nota?: string | null }): Promise<void> {
  await llamarRpc<unknown>('admin_mark_outbound', {
    p_id: params.id,
    p_status: params.estado,
    p_note: params.nota?.trim() || null,
  })
}

export type ReenvioDeComprobante = { ok: boolean; email: string | null; status: string | null }

/**
 * Encola otro comprobante. Con `email`, además corrige el correo del
 * paciente (queda en la bitácora con el motivo).
 */
export async function reenviarComprobante(params: {
  chargeId: string
  email?: string | null
}): Promise<ReenvioDeComprobante> {
  return llamarRpc(
    'admin_resend_receipt',
    { p_charge_id: params.chargeId, p_email: params.email?.trim() || null },
    {
      leer: (d) => {
        const r = comoFila(d)
        return {
          ok: r.ok !== false,
          email: textoONulo(r.email) ?? textoONulo(r.email_enmascarado),
          status: textoONulo(r.status),
        }
      },
    },
  )
}
