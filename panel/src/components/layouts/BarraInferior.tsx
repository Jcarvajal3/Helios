import { Link, useRouterState } from '@tanstack/react-router'
import { Menu } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'
import type { ReactNode } from 'react'

import type { NavItem } from '@/config/navigation'

/**
 * La barra de abajo del teléfono: lo que más se usa, a un toque del pulgar.
 *
 * Por debajo de 768 px el menú es un cajón que se abre desde la hamburguesa
 * de arriba a la izquierda, que es la esquina más lejos del pulgar de quien
 * sujeta el teléfono con la derecha. Registrar un pago en cuotas —lo que se
 * hace veinte veces al día— costaba dos toques y un estirón. Aquí cuesta uno.
 *
 * Tres pantallas y «Menú», que abre el mismo cajón de siempre con el resto,
 * la cuenta y el tema. Si la pantalla en la que se está no tiene sitio en la
 * barra (Métricas, Personal), se marca «Menú»: el «estás aquí» nunca queda
 * sin marcar.
 *
 * Se esconde mientras se escribe (`.barra-inferior` en styles.css): en
 * Android el teclado sube la barra con él y se come el campo.
 */
export function BarraInferior({
  items,
  menuAbierto,
  onMenu,
}: {
  items: ReadonlyArray<NavItem>
  menuAbierto: boolean
  onMenu: () => void
}) {
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const activo = (item: NavItem) =>
    pathname === item.path || pathname.startsWith(`${item.path}/`)
  const algunoActivo = items.some(activo)

  return (
    <nav
      aria-label="Accesos rápidos"
      className="barra-inferior fixed inset-x-0 bottom-0 z-30 border-t border-panel-hairline bg-panel-bar/95 pb-[env(safe-area-inset-bottom)] backdrop-blur md:hidden"
    >
      <ul className="flex h-16">
        {items.map((item) => (
          <li key={item.path} className="flex min-w-0 flex-1">
            <Link
              to={item.path}
              aria-current={activo(item) ? 'page' : undefined}
              className="flex min-w-0 flex-1 flex-col items-center justify-center gap-1"
            >
              <Hueco icon={item.icon} activo={activo(item)} destacado={item.destacado}>
                {item.corto ?? item.label}
              </Hueco>
            </Link>
          </li>
        ))}
        <li className="flex min-w-0 flex-1">
          <button
            type="button"
            onClick={onMenu}
            aria-expanded={menuAbierto}
            className="flex min-w-0 flex-1 flex-col items-center justify-center gap-1"
          >
            <Hueco icon={Menu} activo={menuAbierto || !algunoActivo}>
              Menú
            </Hueco>
          </button>
        </li>
      </ul>
    </nav>
  )
}

/** El icono en su pastilla y el nombre debajo, como en la barra de la app. */
function Hueco({
  icon: Icon,
  activo,
  destacado = false,
  children,
}: {
  icon: LucideIcon
  activo: boolean
  /** La acción principal: la pastilla va siempre en el color de la marca. */
  destacado?: boolean
  children: ReactNode
}) {
  return (
    <>
      <span
        aria-hidden
        className={`flex h-8 w-14 items-center justify-center rounded-full transition-colors duration-(--transition-fast) ${
          destacado
            ? 'bg-primary text-on-primary'
            : activo
              ? 'bg-panel-control text-on-surface'
              : 'text-panel-muted'
        }`}
      >
        <Icon size={20} strokeWidth={activo || destacado ? 2 : 1.75} />
      </span>
      <span
        className={`max-w-full truncate px-1 text-[0.6875rem] leading-4 ${
          activo ? 'font-semibold text-on-surface' : 'font-medium text-panel-muted'
        }`}
      >
        {children}
      </span>
    </>
  )
}
