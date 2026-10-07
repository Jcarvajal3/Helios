import { useEffect, useState } from 'react'
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
 * Se esconde solo con el teclado en pantalla abierto (`useTecladoAbierto`):
 * en Android el teclado sube la barra con él y se come el campo.
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
  const teclado = useTecladoAbierto()

  if (teclado) return null

  return (
    <nav
      aria-label="Accesos rápidos"
      className="fixed inset-x-0 bottom-0 z-30 border-t border-panel-hairline bg-panel-bar/95 pb-[env(safe-area-inset-bottom)] backdrop-blur md:hidden"
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

/**
 * Si el teclado del teléfono está abierto ahora mismo.
 *
 * No basta con mirar si hay un campo con el foco: el alta lleva el cursor a
 * la cédula al abrirse, para quien teclea en el escritorio, y con esa regla
 * la barra desaparecía justo en la pantalla con la que arranca el panel, sin
 * otra manera de ir a ninguna parte. Un foco puesto desde el código no abre
 * el teclado del teléfono; lo abre el toque.
 *
 * Lo que se mira es lo que el teclado hace: encoger la ventana visible. Se
 * compara con lo más alto que se ha visto, porque según el navegador el
 * teclado encoge solo `visualViewport` o también `innerHeight`. Un cuarto
 * menos es teclado: la barra de direcciones que se esconde al desplazarse
 * no llega a tanto.
 */
function useTecladoAbierto(): boolean {
  const [abierto, setAbierto] = useState(false)

  useEffect(() => {
    const vista = window.visualViewport
    if (!vista) return
    let maximo = Math.max(vista.height, window.innerHeight)

    function medir() {
      if (!vista) return
      maximo = Math.max(maximo, vista.height)
      const escribiendo = document.activeElement?.matches('input, select, textarea') ?? false
      setAbierto(escribiendo && vista.height < maximo * 0.75)
    }

    // Girar el teléfono cambia el alto de verdad: lo de antes ya no sirve.
    function girar() {
      maximo = 0
      medir()
    }

    vista.addEventListener('resize', medir)
    window.addEventListener('orientationchange', girar)
    document.addEventListener('focusout', medir)
    return () => {
      vista.removeEventListener('resize', medir)
      window.removeEventListener('orientationchange', girar)
      document.removeEventListener('focusout', medir)
    }
  }, [])

  return abierto
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
