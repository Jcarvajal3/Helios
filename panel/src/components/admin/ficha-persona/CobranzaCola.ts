import { useMemo, useSyncExternalStore } from 'react'

import { abrirEnCola, useCola } from '@/components/admin/ModoCola'
import type { Cola } from '@/components/admin/ModoCola'
import { FILTROS_CARTERA, idsSinRepetir } from '@/features/admin/cobranza/cartera'
import type { FiltroCartera } from '@/features/admin/cobranza/cartera'
import { comoFila } from '@/lib/json'
import { unoDe } from '@/lib/busqueda'
import { VALORES_ESTADO_PROMESA } from '@/features/admin/estados'
import type { EstadoPromesa } from '@/features/admin/estados'

// ═══════════════════════════════════════════════════════════════════════════
// Recorrer los casos de cobranza uno a uno.
//
// Dos listas abren el caso en modo cola: la cartera vencida y las promesas.
// Cada una guarda su orden con `abrirEnCola` (colas «cobranza» y «promesas»)
// y, además, de dónde se vino y con qué filtro, para que «volver» regrese a
// la misma lista filtrada y no a la primera pestaña.
// ═══════════════════════════════════════════════════════════════════════════

export type OrigenDelCaso =
  | { lista: 'cobranza'; tramo: FiltroCartera }
  /** Por cobrar › Morosos: la misma cola «cobranza», con otra lista a la que volver. */
  | { lista: 'morosos' }
  | { lista: 'promesas'; estado: EstadoPromesa }

const CLAVE = 'helios-panel:cola-cobranza:origen'

/**
 * Apunta el orden de la lista y de dónde viene. Los ids van en el orden en
 * que se ven; una persona que sale dos veces (dos promesas) es un solo caso.
 */
export function abrirCasoEnCola(origen: OrigenDelCaso, ids: ReadonlyArray<string>): void {
  try {
    sessionStorage.setItem(CLAVE, JSON.stringify(origen))
  } catch {
    // Sin almacenamiento, «volver» lleva a la cartera sin filtro.
  }
  // Morosos recorre la misma cola que la Lista: solo cambia a qué lista se
  // vuelve. Con su propio nombre la ficha no la encontraba y caía en Personas.
  abrirEnCola(origen.lista === 'promesas' ? 'promesas' : 'cobranza', idsSinRepetir(ids))
}

function leerOrigen(crudo: string | null): OrigenDelCaso | null {
  if (!crudo) return null
  try {
    const o = comoFila(JSON.parse(crudo))
    if (o.lista === 'promesas') {
      const estado = unoDe(VALORES_ESTADO_PROMESA, o.estado)
      return estado ? { lista: 'promesas', estado } : null
    }
    if (o.lista === 'morosos') return { lista: 'morosos' }
    if (o.lista === 'cobranza') return { lista: 'cobranza', tramo: unoDe(FILTROS_CARTERA, o.tramo) ?? 'todos' }
    return null
  } catch {
    return null
  }
}

function leerCrudo(): string | null {
  try {
    return sessionStorage.getItem(CLAVE)
  } catch {
    return null
  }
}

/** El origen se escribe antes de navegar al caso: no hace falta escuchar cambios. */
function sinSuscripcion(): () => void {
  return () => {}
}

/**
 * La cola en la que está este caso y la lista a la que se vuelve.
 *
 * Si la persona está en las dos colas, manda la de la última lista que se
 * abrió. Si no está en ninguna, `cola.total` es 0 y la barra no se pinta.
 */
export function useColaDelCaso(userId: string): { cola: Cola; volverA: OrigenDelCaso } {
  const crudo = useSyncExternalStore(sinSuscripcion, leerCrudo, () => null)
  const origen = useMemo(() => leerOrigen(crudo), [crudo])
  const deCartera = useCola('cobranza', userId)
  const dePromesas = useCola('promesas', userId)

  const porDefecto: OrigenDelCaso = { lista: 'cobranza', tramo: 'todos' }

  if (origen?.lista === 'promesas' && dePromesas.total > 0) return { cola: dePromesas, volverA: origen }
  if (deCartera.total > 0) {
    return { cola: deCartera, volverA: origen?.lista === 'cobranza' || origen?.lista === 'morosos' ? origen : porDefecto }
  }
  if (dePromesas.total > 0) {
    return { cola: dePromesas, volverA: origen?.lista === 'promesas' ? origen : { lista: 'promesas', estado: 'vence_hoy' } }
  }
  return { cola: deCartera, volverA: origen ?? porDefecto }
}
