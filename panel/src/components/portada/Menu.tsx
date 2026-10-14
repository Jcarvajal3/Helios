import { Link, useLocation } from '@tanstack/react-router'
import { Menu as IconoMenu, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import type { ReactNode } from 'react'

import { MENU } from './datos'
import { BotonAfiliarme } from './piezas'
import { HeliosLogo } from '@/components/HeliosLogo'

/**
 * Una ruta va con `Link` (navega sin recargar y precarga); una sección de
 * la portada (`/#…`), con `<a>`: en la portada solo desplaza.
 */
function Enlace({
  href,
  ...resto
}: {
  href: string
  className: string
  onClick?: () => void
  children: ReactNode
}) {
  return href.startsWith('/#') ? (
    <a href={href} {...resto} />
  ) : (
    <Link to={href} {...resto} />
  )
}

/**
 * El menú: transparente sobre la primera pantalla y, al bajar, una píldora
 * de vidrio. En el móvil, los enlaces van en una hoja que cae desde arriba.
 */
export function Menu() {
  const [bajo, setBajo] = useState(false)
  const [abierto, setAbierto] = useState(false)
  const enPortada = useLocation({ select: (l) => l.pathname === '/' })

  useEffect(() => {
    const alDesplazar = () => setBajo(window.scrollY > 24)
    alDesplazar()
    window.addEventListener('scroll', alDesplazar, { passive: true })
    return () => window.removeEventListener('scroll', alDesplazar)
  }, [])

  useEffect(() => {
    if (!abierto) return
    const alTeclear = (e: KeyboardEvent) =>
      e.key === 'Escape' && setAbierto(false)
    window.addEventListener('keydown', alTeclear)
    return () => window.removeEventListener('keydown', alTeclear)
  }, [abierto])

  return (
    <header className="portada-menu fixed inset-x-0 top-0 z-50 px-3 pt-3 sm:px-5 sm:pt-4">
      <nav
        data-bajo={bajo || abierto ? '' : undefined}
        className="portada-menu-barra mx-auto flex w-full max-w-[calc(var(--portada-ancho)+1.5rem)] items-center justify-between gap-6 rounded-full py-2 pl-5 pr-2"
      >
        <a
          href={enPortada ? '#arriba' : '/'}
          aria-label={
            enPortada ? 'Helios, volver arriba' : 'Helios, ir a la portada'
          }
          className="flex shrink-0 items-center"
        >
          <HeliosLogo height={26} color="#002770" />
        </a>

        <ul className="hidden items-center gap-1 lg:flex">
          {MENU.map((item) => (
            <li key={item.href}>
              <Enlace
                href={item.href}
                className="rounded-full px-4 py-2 text-[0.92rem] tracking-[-0.01em] text-portada-tinta-2 transition-colors duration-300 hover:bg-portada-tinta/[0.05] hover:text-portada-tinta"
              >
                {item.texto}
              </Enlace>
            </li>
          ))}
        </ul>

        <div className="flex items-center gap-2">
          {/* "Entrar" es de los médicos y del personal de los centros. */}
          <Link
            to="/login"
            className="hidden h-10 items-center rounded-full px-4 text-[0.92rem] font-medium tracking-[-0.01em] text-portada-tinta transition-colors duration-300 hover:bg-portada-tinta/[0.05] sm:inline-flex"
          >
            Entrar
          </Link>
          <Link
            to="/login"
            className="inline-flex h-10 items-center rounded-full bg-portada-tinta px-5 text-[0.92rem] font-medium tracking-[-0.01em] text-white transition-colors duration-300 hover:bg-portada-marino sm:hidden"
          >
            Entrar
          </Link>
          <span className="hidden sm:block">
            <BotonAfiliarme className="!h-10 !pl-5" />
          </span>
          <button
            type="button"
            aria-label={abierto ? 'Cerrar el menú' : 'Abrir el menú'}
            aria-expanded={abierto}
            aria-controls="portada-menu-movil"
            onClick={() => setAbierto((a) => !a)}
            className="grid size-10 place-items-center rounded-full text-portada-tinta transition-colors hover:bg-portada-tinta/[0.06] lg:hidden"
          >
            {abierto ? (
              <X className="size-5" />
            ) : (
              <IconoMenu className="size-5" />
            )}
          </button>
        </div>
      </nav>

      <div
        id="portada-menu-movil"
        data-abierto={abierto ? '' : undefined}
        className="portada-menu-hoja mx-auto mt-2 w-full max-w-[calc(var(--portada-ancho)+1.5rem)] overflow-hidden rounded-[28px] lg:hidden"
      >
        <ul className="flex flex-col p-3">
          {MENU.map((item, i) => (
            <li
              key={item.href}
              style={{ transitionDelay: `${abierto ? 60 + i * 40 : 0}ms` }}
            >
              <Enlace
                href={item.href}
                onClick={() => setAbierto(false)}
                className="flex items-center justify-between rounded-2xl px-4 py-3.5 text-[1.35rem] font-medium tracking-[-0.03em] text-portada-tinta hover:bg-portada-niebla"
              >
                {item.texto}
                <span className="portada-etiqueta text-portada-tinta-3">
                  0{i + 1}
                </span>
              </Enlace>
            </li>
          ))}
          <li className="mt-2 px-1 pb-1 sm:hidden">
            <BotonAfiliarme className="w-full" />
          </li>
        </ul>
      </div>
    </header>
  )
}
