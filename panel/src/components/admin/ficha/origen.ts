import { useSyncExternalStore } from 'react'
import { useRouter, useRouterState } from '@tanstack/react-router'
import type { AnyRouter } from '@tanstack/react-router'

import { enLaMismaCola } from '@/components/admin/ModoCola'
import {
  guardarOrigen,
  indiceDe,
  leerOrigenCrudo,
  leerOrigenes,
  origenAlEntrar,
  pasosHaciaAtras,
  suscribirOrigenes,
} from '@/features/navegacion/origenDeFicha'
import type { Origen } from '@/features/navegacion/origenDeFicha'
import { comoFila } from '@/lib/json'

/**
 * Cómo se llama la pantalla que se está dejando: el título de la pestaña del
 * navegador («Por cobrar · Ronda Admin» → «Por cobrar») y, si tiene
 * pestañas, la que está puesta: «Por cobrar › Morosos». Se lee antes de
 * navegar, cuando la pantalla todavía está pintada.
 */
function tituloDeLaPantalla(): string {
  const base = document.title.split(' · ')[0]?.trim() || 'Atrás'
  const pestana = document
    .querySelector('main [role="tab"][aria-selected="true"]')
    ?.getAttribute('data-rotulo')
    ?.trim()
  return pestana && pestana !== base ? `${base} › ${pestana}` : base
}

/**
 * Escucha las navegaciones del panel y apunta el origen de cada ficha a la
 * que se entra. Se engancha una vez, al crear el router, y solo en el
 * navegador.
 */
export function apuntarOrigenesDeFichas(router: AnyRouter): void {
  if (typeof window === 'undefined') return
  router.subscribe('onBeforeNavigate', ({ fromLocation, toLocation }) => {
    const origen = origenAlEntrar(
      fromLocation
        ? { pathname: fromLocation.pathname, href: fromLocation.href, indice: indiceDe(fromLocation.state) }
        : undefined,
      { pathname: toLocation.pathname, href: toLocation.href, indice: indiceDe(toLocation.state) },
      leerOrigenes(),
      tituloDeLaPantalla(),
      enLaMismaCola,
    )
    if (origen !== undefined) guardarOrigen(toLocation.pathname, origen)
  })
}

/** El origen apuntado para esta ficha, o `null` si no hay. */
export function useOrigenDeFicha(pathname: string): Origen | null {
  const crudo = useSyncExternalStore(
    suscribirOrigenes,
    () => leerOrigenCrudo(pathname),
    () => null,
  )
  if (!crudo) return null
  const o = comoFila(JSON.parse(crudo))
  return {
    href: String(o.href),
    titulo: String(o.titulo),
    indice: typeof o.indice === 'number' ? o.indice : null,
  }
}

/**
 * Vuelve al origen. Por el historial si se puede: la lista reaparece tal como
 * se dejó, con su scroll; si no, navegando a su dirección, que conserva sus
 * filtros y su pestaña.
 */
export function volverAlOrigen(router: AnyRouter, origen: Origen): void {
  const pasos = pasosHaciaAtras(origen, indiceDe(router.history.location.state))
  if (pasos !== null) router.history.go(-pasos)
  else void router.navigate({ href: origen.href })
}

/**
 * El origen de la ficha que se está viendo y la función que vuelve a él, o
 * `null` si no hay: para las barras de cola, que ponen su propio «volver».
 */
export function useVolverDeFicha(): { origen: Origen | null; volver: (() => void) | null } {
  const router = useRouter()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const origen = useOrigenDeFicha(pathname)
  return { origen, volver: origen ? () => volverAlOrigen(router, origen) : null }
}
