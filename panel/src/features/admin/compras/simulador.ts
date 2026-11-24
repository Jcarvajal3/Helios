// ═══════════════════════════════════════════════════════════════════════════
// Cliente de la Edge Function `compras-simulador` (contrato §4).
//
// El simulador no implementa nada del bot: manda cada turno a la función, que
// corre el MISMO flujo de compras del webhook con un transporte de prueba. Los
// mensajes no viajan en la respuesta: se leen con `admin_purchase_sim_messages`.
// ═══════════════════════════════════════════════════════════════════════════

import { comoFila, textoONulo } from '@/lib/json'
import { describeError, supabase } from '@/lib/supabase'
import { subirComprobanteCompra } from './api'
import { leerProveedor } from './lectores'
import type {
  DiagnosticoSimulador,
  PeticionSimulador,
  ResultadoTurnoSimulador,
} from './tipos'

async function invocar(
  body: PeticionSimulador,
): Promise<Record<string, unknown>> {
  const { data, error } = await supabase.functions.invoke('compras-simulador', {
    body,
  })
  if (error) {
    // Con HTTP 4xx/5xx el detalle viaja en el cuerpo `{ ok: false, error }`.
    const contexto: unknown = (error as { context?: unknown }).context
    let detalle: string | null = null
    if (contexto instanceof Response) {
      try {
        detalle = textoONulo(comoFila(await contexto.json()).error)
      } catch {
        detalle = null
      }
    }
    throw new Error(
      detalle ?? describeError(error) ?? 'El simulador no respondió.',
    )
  }
  const r = comoFila(data)
  if (r.ok !== true)
    throw new Error(textoONulo(r.error) ?? 'El simulador devolvió un error.')
  return r
}

function leerDiagnostico(r: Record<string, unknown>): DiagnosticoSimulador {
  if (typeof r.proveedor_listo !== 'boolean') {
    throw new Error(
      'Respuesta inesperada del simulador: falta «proveedor_listo».',
    )
  }
  return {
    proveedor: leerProveedor(r.proveedor, 'el simulador'),
    proveedorListo: r.proveedor_listo,
  }
}

export async function diagnosticarSimulador(): Promise<DiagnosticoSimulador> {
  return leerDiagnostico(await invocar({ accion: 'diagnostico' }))
}

export async function turnoSimulador(params: {
  phone: string
  texto?: string
  respuesta?: { id: string; title: string }
  adjunto?: { receipt_path: string }
}): Promise<ResultadoTurnoSimulador> {
  const r = await invocar({ accion: 'turno', ...params })
  return { ...leerDiagnostico(r), estado: textoONulo(r.estado) }
}

export async function reiniciarSimulador(phone: string): Promise<void> {
  await invocar({ accion: 'reiniciar', phone })
}

/** Sube la captura del simulador y devuelve la ruta que se manda como `adjunto.receipt_path`. */
export function subirCapturaSimulador(file: File): Promise<string> {
  return subirComprobanteCompra({ carpeta: 'compras/simulador', file })
}
