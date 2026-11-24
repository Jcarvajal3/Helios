import { queryOptions } from '@tanstack/react-query'

import {
  listarColaPagosCompra,
  listarMedicosSimulador,
  listarMensajesSimulador,
  listarSolicitudesCompra,
  listarSolicitudesSimulador,
  obtenerAjustesCompras,
  obtenerConteosCompras,
  obtenerDetalleCompra,
  preverPagoCompra,
} from './api'
import type { CanalCompra, EstadoPagoCompra, EstadoSolicitudCompra } from './tipos'

export const CLAVE_COMPRAS = ['admin-compras'] as const

export function consultaConteosCompras() {
  return queryOptions({
    queryKey: [...CLAVE_COMPRAS, 'conteos'],
    queryFn: ({ signal }) => obtenerConteosCompras(signal),
    refetchInterval: 60_000,
    staleTime: 20_000,
  })
}

export function consultaSolicitudesCompra(params: {
  statuses?: EstadoSolicitudCompra[] | null
  channel?: CanalCompra | null
  search?: string | null
  limit?: number
} = {}) {
  return queryOptions({
    queryKey: [
      ...CLAVE_COMPRAS,
      'lista',
      params.statuses ?? null,
      params.channel ?? null,
      params.search ?? null,
      params.limit ?? 150,
    ],
    queryFn: ({ signal }) => listarSolicitudesCompra(params, signal),
    refetchInterval: 30_000,
    refetchOnWindowFocus: true,
  })
}

export function consultaDetalleCompra(requestId: string) {
  return queryOptions({
    queryKey: [...CLAVE_COMPRAS, 'detalle', requestId],
    queryFn: ({ signal }) => obtenerDetalleCompra(requestId, signal),
    refetchOnWindowFocus: true,
  })
}

export function consultaColaPagosCompra(statuses: EstadoPagoCompra[] | null) {
  return queryOptions({
    queryKey: [...CLAVE_COMPRAS, 'pagos', statuses ?? 'todos'],
    queryFn: ({ signal }) => listarColaPagosCompra(statuses, signal),
    refetchInterval: 30_000,
    refetchOnWindowFocus: true,
  })
}

export function consultaPrevisionPagoCompra(requestId: string, paidOn: string) {
  return queryOptions({
    queryKey: [...CLAVE_COMPRAS, 'prevision-pago', requestId, paidOn],
    queryFn: ({ signal }) => preverPagoCompra({ requestId, paidOn }, signal),
  })
}

export function consultaAjustesCompras() {
  return queryOptions({
    queryKey: [...CLAVE_COMPRAS, 'ajustes'],
    queryFn: ({ signal }) => obtenerAjustesCompras(signal),
    staleTime: 60_000,
  })
}

export function consultaMedicosSimulador() {
  return queryOptions({
    queryKey: [...CLAVE_COMPRAS, 'sim', 'medicos'],
    queryFn: ({ signal }) => listarMedicosSimulador(signal),
    staleTime: 60_000,
  })
}

export function consultaMensajesSimulador(phone: string) {
  return queryOptions({
    queryKey: [...CLAVE_COMPRAS, 'sim', 'mensajes', phone],
    queryFn: ({ signal }) => listarMensajesSimulador(phone, signal),
    enabled: phone.trim().length > 0,
    refetchOnWindowFocus: true,
  })
}

export function consultaSolicitudesSimulador(phone: string) {
  return queryOptions({
    queryKey: [...CLAVE_COMPRAS, 'sim', 'solicitudes', phone],
    queryFn: ({ signal }) => listarSolicitudesSimulador(phone, signal),
    enabled: phone.trim().length > 0,
    refetchOnWindowFocus: true,
  })
}
