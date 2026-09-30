import type { MouseEvent, ReactNode } from 'react'
import { Link, useRouter, useRouterState } from '@tanstack/react-router'
import type { RegisteredRouter, ValidateLinkOptions } from '@tanstack/react-router'
import { ArrowLeft } from 'lucide-react'

import { useOrigenDeFicha, volverAlOrigen } from './origen'

const CLASE =
  'mb-4 inline-flex items-center gap-1 self-start type-panel-control text-on-surface-variant transition-colors duration-(--transition-fast) hover:text-on-surface'

/**
 * «← Por cobrar › Morosos»: la vuelta de una ficha a la pantalla desde la que
 * se abrió, con sus filtros, su pestaña y, si se puede, su scroll.
 *
 * `link` y `children` son la lista fija de la ficha («← Usuarios»): solo se
 * usan si no hay un origen apuntado, como al llegar por un enlace pegado.
 */
export function VolverA<TRouter extends RegisteredRouter, TOptions>(props: {
  link: ValidateLinkOptions<TRouter, TOptions>
  children: ReactNode
}): ReactNode
export function VolverA({ link, children }: { link: ValidateLinkOptions; children: ReactNode }) {
  const router = useRouter()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const origen = useOrigenDeFicha(pathname)

  if (origen) {
    return (
      <a
        href={origen.href}
        className={CLASE}
        onClick={(e: MouseEvent<HTMLAnchorElement>) => {
          // Con Ctrl, Cmd o la rueda se abre en otra pestaña, como un enlace.
          if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return
          e.preventDefault()
          volverAlOrigen(router, origen)
        }}
      >
        <ArrowLeft size={14} aria-hidden /> {origen.titulo}
      </a>
    )
  }

  return (
    <Link {...link} className={CLASE}>
      <ArrowLeft size={14} aria-hidden /> {children}
    </Link>
  )
}
