import { useCallback } from 'react'
import { useRouter } from '@tanstack/react-router'

import type { Destinatario } from './opciones'

type Router = ReturnType<typeof useRouter>

/**
 * La dirección de un destino, construida por el router: con sus parámetros y
 * su `search` ya validados contra la ruta, igual que la haría un `<Link>`.
 */
function hrefDe(router: Router, d: Destinatario): string {
  switch (d.clase) {
    case 'ruta':
      return router.buildLocation(d.destino).href
    case 'persona':
      return router.buildLocation({ to: '/admin/pacientes/$id', params: { id: d.id } }).href
    case 'local':
      return router.buildLocation({ to: '/admin/clinicas/$id', params: { id: d.id } }).href
    case 'consumo':
      return router.buildLocation({ to: '/admin/financiamientos/$id', params: { id: d.id } }).href
    case 'pago':
      return router.buildLocation({ to: '/admin/cobros/$id', params: { id: d.id } }).href
  }
}

/**
 * Lleva a un destino de la paleta, en esta pestaña o en una nueva (Ctrl o ⌘
 * con Enter, o con el clic).
 */
export function useIrA(): (d: Destinatario, nuevaPestana: boolean) => void {
  const router = useRouter()
  return useCallback(
    (d: Destinatario, nuevaPestana: boolean) => {
      const href = hrefDe(router, d)
      if (nuevaPestana) {
        window.open(href, '_blank', 'noopener')
        return
      }
      void router.navigate({ href })
    },
    [router],
  )
}
