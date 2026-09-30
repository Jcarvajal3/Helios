import { useEffect } from 'react'
import { useMatchRoute, useNavigate, useRouterState } from '@tanstack/react-router'
import { ChevronRight, PanelLeft } from 'lucide-react'

import { useConnectionStatus } from '@/components/ConnectionIndicator'
import type { NavGroup, NavItem } from '@/config/navigation'
import { tonoDeAmbito } from '@/features/admin/areas'
import { ES_CAJON, useMediaQuery } from '@/lib/media'
import { cerrarSesion } from '@/lib/supabase'
import { sumarContadores } from './contadores'
import type { Contador } from './contadores'
import type { Account } from './cuenta'
import { ContadorDelMenu, EnlaceDelMenu } from './EnlaceDelMenu'
import { PieDelMenu } from './PieDelMenu'
import { claveDeGrupo, useGruposPlegados } from './useGruposPlegados'

/**
 * Barra lateral de navegación.
 *
 * Tres estados, y el tercero no es un ancho:
 *
 *   ancho    240 px, el de siempre.
 *   plegado  64 px, solo iconos. Lo pide quien mira una tabla de siete
 *            columnas y quiere el ancho para la tabla. Se pliega desde el
 *            botón de la cabecera, al lado del logo.
 *   cajón    por debajo de 1024 px sale del flujo y se abre ENCIMA del
 *            contenido. Antes era `fixed` a 240 siempre, con el contenido
 *            empujado 240 siempre, así que en la tablet del cajero se comía
 *            el 27% de la pantalla sin manera de esconderla.
 *
 * Recibe los grupos como prop para servir a los dos paneles: el del local es
 * un grupo sin título y el del equipo es un bloque por espacio de trabajo,
 * porque veinte ítems planos son una lista que hay que leer entera cada vez.
 * Todo grupo con título se pliega desde su rótulo; por defecto, todos salen
 * desplegados.
 */
export function Sidebar({
  groups,
  pie,
  logoSlot,
  account,
  contadores,
  plegado,
  abierto,
  onCerrar,
  onPlegar,
}: {
  groups: NavGroup[]
  /** Lo que va al pie, junto a la cuenta: hoy, la ruta de QA del piloto. */
  pie?: ReadonlyArray<NavItem>
  logoSlot: React.ReactNode
  account: Account
  /** Cuántos esperan en cada cola, por `path`. Lo decide el panel que lo pasa. */
  contadores?: Partial<Record<string, Contador>>
  /** Solo de lg para arriba: por debajo el cajón siempre sale ancho. */
  plegado: boolean
  /** Si el cajón está abierto. Irrelevante de lg para arriba. */
  abierto: boolean
  onCerrar: () => void
  onPlegar: () => void
}) {
  const matchRoute = useMatchRoute()
  const navigate = useNavigate()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const { plegados, alternarPlegado, desplegar } = useGruposPlegados()
  // Una sola vez para toda la barra: el punto del avatar y el aviso leen lo mismo.
  const conexion = useConnectionStatus()

  /** `/admin` es prefijo de todo lo que cuelga de ella: sin el trato
   *  especial, el match difuso la dejaría siempre activa. */
  function estaActivo(item: NavItem): boolean {
    return item.path === '/admin'
      ? !!matchRoute({ to: item.path, fuzzy: false })
      : !!matchRoute({ to: item.path, fuzzy: true })
  }

  // Al llegar a una pantalla, su grupo se despliega: el «estás aquí» no puede
  // quedar escondido. Solo al navegar; después se puede volver a plegar.
  const grupoActivo = groups.findIndex((g) => g.items.some(estaActivo))
  const claveActiva = grupoActivo === -1 ? null : claveDeGrupo(groups[grupoActivo], grupoActivo)
  useEffect(() => {
    if (claveActiva) desplegar(claveActiva)
  }, [pathname, claveActiva, desplegar])

  // Si hoy la barra es un cajón. Solo hace falta para saber si lo que está
  // apartado hay que apagarlo de verdad: la barra fija nunca se apaga.
  const esCajon = useMediaQuery(ES_CAJON)
  const apagado = esCajon && !abierto

  // El cajón se cierra al llegar a otra pantalla. Sin esto hay que cerrarlo a
  // mano después de cada salto, que es exactamente el gesto que un cajón
  // existe para ahorrar.
  useEffect(() => {
    onCerrar()
  }, [pathname, onCerrar])

  // Y con Escape, como cualquier cosa que se abre encima de otra. Salvo que
  // otro ya lo haya gastado (`defaultPrevented`): ese Escape era suyo.
  useEffect(() => {
    if (!abierto) return
    function onKey(event: KeyboardEvent) {
      if (event.key === 'Escape' && !event.defaultPrevented) onCerrar()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [abierto, onCerrar])

  async function signOut() {
    await cerrarSesion()
    void navigate({ to: '/login' })
  }

  return (
    <>
      {/* El velo del cajón. Solo existe por debajo de lg. */}
      {abierto && (
        <button
          type="button"
          aria-label="Cerrar el menú"
          onClick={onCerrar}
          className="anim-velo fixed inset-0 z-30 bg-scrim/60 lg:hidden"
        />
      )}

      <aside
        // El ancho sale de --sidebar-actual, que fija PanelShell: así el
        // margen del contenido y el ancho de la barra no pueden discrepar.
        // En el cajón se ignora y sale siempre ancha: plegar a iconos sirve
        // para ganarle sitio a la tabla, y un cajón que flota no le quita
        // sitio a nadie.
        //
        // `inert` con el cajón cerrado: apartada con translate la barra no se
        // ve, pero sus enlaces seguían recibiendo el tabulador y los seguía
        // leyendo un lector de pantalla.
        inert={apagado}
        aria-hidden={apagado || undefined}
        className={`fixed inset-y-0 left-0 z-40 flex w-(--sidebar-width) flex-col border-r border-panel-hairline bg-panel-bar pt-4.5 pb-3 transition-transform duration-200 lg:w-(--sidebar-actual) lg:translate-x-0 ${
          abierto ? 'translate-x-0' : '-translate-x-full'
        }`}
      >
        <div
          className={`mx-3 flex min-h-9 shrink-0 items-center gap-2 pl-2.5 ${
            plegado ? 'lg:flex-col lg:pl-0' : ''
          }`}
        >
          <div className={`min-w-0 flex-1 ${plegado ? 'lg:flex-none' : ''}`}>{logoSlot}</div>

          {/* Por debajo de lg la barra es un cajón y no se pliega: se cierra. */}
          <button
            type="button"
            onClick={onPlegar}
            aria-label={plegado ? 'Desplegar el menú' : 'Plegar el menú'}
            aria-pressed={plegado}
            title={plegado ? 'Desplegar el menú' : 'Plegar el menú'}
            className="hidden size-8 shrink-0 items-center justify-center rounded-panel-control text-panel-muted transition-colors duration-(--transition-fast) hover:bg-panel-card hover:text-on-surface lg:inline-flex"
          >
            <PanelLeft size={18} strokeWidth={1.75} aria-hidden />
          </button>
        </div>

        <nav
          aria-label="Menú"
          className="mt-3.5 flex flex-1 flex-col gap-3.5 overflow-y-auto px-3"
        >
          {groups.map((group, index) => {
            const clave = claveDeGrupo(group, index)
            // Sin rótulo no hay nada que pulsar para plegarlo: siempre abierto.
            const desplegado = !group.title || !plegados.includes(clave)
            // Cerrado, el trabajo que espera dentro se sigue viendo.
            const pendiente = sumarContadores(group.items.map((item) => contadores?.[item.path]))

            return (
              <div
                key={clave}
                data-area={group.espacio ? tonoDeAmbito(group.espacio) : undefined}
                className="flex flex-col gap-0.5"
              >
                {/* Plegada no caben los rótulos de grupo. En su lugar, una
                    regla: los bloques se siguen distinguiendo. */}
                {group.title && plegado && (
                  <hr className="mx-2 my-1 hidden border-0 border-t border-panel-hairline lg:block" />
                )}

                {group.title && (
                  <button
                    type="button"
                    onClick={() => alternarPlegado(clave)}
                    aria-expanded={desplegado}
                    aria-controls={`menu-${clave}`}
                    className={`flex h-6.5 items-center gap-2 rounded-panel-control px-2.5 text-left type-panel-overline text-panel-muted transition-colors duration-(--transition-fast) hover:text-on-surface ${
                      plegado ? 'lg:hidden' : ''
                    }`}
                  >
                    {/* El punto del tono del área: orienta, con el nombre al lado. */}
                    <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-area" />
                    <span className="min-w-0 flex-1 truncate">{group.title}</span>
                    {!desplegado && pendiente && <ContadorDelMenu contador={pendiente} />}
                    <ChevronRight
                      size={14}
                      strokeWidth={1.75}
                      aria-hidden
                      className={`shrink-0 transition-transform duration-(--transition-fast) ${
                        desplegado ? 'rotate-90' : ''
                      }`}
                    />
                  </button>
                )}

                {/* Plegada a iconos, los grupos cerrados enseñan sus iconos
                    igual: sin rótulo no hay nada que pulsar para abrirlos. */}
                <div
                  id={`menu-${clave}`}
                  className={`flex-col gap-0.5 ${
                    desplegado ? 'flex' : plegado ? 'hidden lg:flex' : 'hidden'
                  }`}
                >
                  {group.items.map((item) => (
                    <EnlaceDelMenu
                      key={item.path}
                      item={item}
                      activo={estaActivo(item)}
                      plegado={plegado}
                      contador={contadores?.[item.path]}
                    />
                  ))}
                </div>
              </div>
            )
          })}
        </nav>

        <PieDelMenu
          items={pie}
          estaActivo={estaActivo}
          account={account}
          conexion={conexion}
          plegado={plegado}
          onSignOut={() => void signOut()}
        />
      </aside>
    </>
  )
}
