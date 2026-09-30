import { useRouter } from '@tanstack/react-router'
import { ArrowRight } from 'lucide-react'
import type { MouseEvent } from 'react'

import { tonoDeRuta } from '@/features/admin/areas'
import { enlaceValido } from '@/features/admin/asistente/enlaces'
import type { Enlace } from '@/features/admin/asistente/protocolo'

/**
 * Un enlace que propone el asistente: un botón que lleva a esa pantalla sin
 * cerrar el cajón, para seguir la conversación con la pantalla al lado.
 *
 * Lleva el punto del tono del área a la que lleva (Cobranza en azul, Riesgo
 * en violeta…), junto a su nombre: se sabe adónde va antes de leerlo entero.
 *
 * La ruta se comprueba antes de pintarla (`enlaceValido`): una que no existe
 * no sale. El `search` lo escribe el propio router y lo vuelve a validar la
 * ruta de destino. Es un `<a>` de verdad: con Ctrl, ⌘ o la rueda se abre en
 * otra pestaña.
 */
export function EnlaceAsistente({ enlace, alNavegar }: { enlace: Enlace; alNavegar?: () => void }) {
  const router = useRouter()
  const valido = enlaceValido(enlace)
  if (!valido) return null

  const href = `${valido.ruta}${router.options.stringifySearch(valido.search ?? {})}`

  function alPulsar(evento: MouseEvent<HTMLAnchorElement>) {
    if (evento.button !== 0 || evento.ctrlKey || evento.metaKey || evento.shiftKey || evento.altKey) return
    evento.preventDefault()
    void router.navigate({ href })
    alNavegar?.()
  }

  return (
    <a
      href={href}
      onClick={alPulsar}
      className="inline-flex h-panel-control-sm max-w-full items-center gap-2 rounded-panel-control bg-panel-raised px-3 type-panel-label text-on-surface transition-colors duration-[var(--transition-fast)] hover:bg-panel-control"
    >
      <span aria-hidden data-area={tonoDeRuta(valido.ruta)} className="size-1.5 shrink-0 rounded-full bg-area" />
      <span className="truncate">{valido.titulo}</span>
      <ArrowRight size={14} aria-hidden className="shrink-0 text-panel-muted" />
    </a>
  )
}
