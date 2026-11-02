import { useCallback, useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { Link, useNavigate, useRouterState } from '@tanstack/react-router'
import { Menu, Search } from 'lucide-react'

import { InterruptorDeVersion } from '@/components/admin/InterruptorDeVersion'
import { abrirPaleta, useAtajoDePaleta } from '@/components/admin/paleta'
import { useConnectionStatus } from '@/components/ConnectionIndicator'
import { HeliosIsotipo } from '@/components/HeliosLogo'
import { MaintenanceBanner } from '@/components/MaintenanceBanner'
import { ToastProvider } from '@/components/Toast'
import { ContadorDelMenu } from '@/components/layouts/EnlaceDelMenu'
import { PageActionProvider, PageTitleProvider } from '@/components/layouts/PageAction'
import { useTituloDeLaPestana } from '@/components/layouts/PanelShell'
import { PieDelMenu } from '@/components/layouts/PieDelMenu'
import { sumarContadores } from '@/components/layouts/contadores'
import type { Contador } from '@/components/layouts/contadores'
import { CuentaProvider } from '@/components/layouts/cuenta'
import type { Account } from '@/components/layouts/cuenta'
import { useMarcoDeLaRuta } from '@/components/layouts/staticData'
import type { PageWidth } from '@/components/layouts/staticData'
import { tonoDeRuta } from '@/features/admin/areas'
import { ES_CAJON, useMediaQuery } from '@/lib/media'
import { cerrarSesion } from '@/lib/supabase'
import { HERRAMIENTAS, PRINCIPALES, esDeLaPestana, ubicar } from './menuLite'
import type { SeccionLite } from './menuLite'
import './lite.css'

type Contadores = Partial<Record<string, Contador>>

const TOPE: Record<PageWidth, string> = {
  wide: 'max-w-(--panel-measure-wide)',
  ficha: 'max-w-(--panel-measure-ficha)',
  normal: 'max-w-(--panel-measure-normal)',
}

/**
 * El marco de Helios Lite: una barra de iconos a la izquierda, arriba la ruta
 * y el buscador, y debajo de la cabecera de cada sección sus pestañas. Lo de
 * dentro es la pantalla de Pro de esa ruta, tal cual.
 *
 * Es un marco aparte y no una variante de `PanelShell` para no tocar Pro:
 * comparte con él las piezas (la cuenta, los avisos, la acción de la
 * pantalla, el título de la pestaña, el aviso de mantenimiento), no el
 * dibujo.
 *
 * Por debajo de 1024 px la barra es un cajón con los nombres, como en Pro.
 */
export function MarcoLite({
  account,
  contadores = {},
  asistente,
  lateral,
  children,
}: {
  account: Account
  contadores?: Contadores
  /** El botón del asistente, si está encendido. */
  asistente?: ReactNode
  /** El cajón de la conversación con el asistente, si está encendido. */
  lateral?: { abierto: boolean; contenido: ReactNode }
  children: ReactNode
}) {
  const [cajonAbierto, setCajonAbierto] = useState(false)
  const [slot, setSlot] = useState<HTMLDivElement | null>(null)
  const [titulo, setTitulo] = useState<string | null>(null)
  const cerrarCajon = useCallback(() => setCajonAbierto(false), [])

  const { title, width } = useMarcoDeLaRuta()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const lugar = ubicar(pathname)
  // El Resumen es su propia cabecera; el resto lleva la de su sección.
  const conCabecera = lugar !== null && lugar.seccion.id !== 'resumen'

  useTituloDeLaPestana(titulo ?? (lugar?.pestana.rotulo || title), 'Helios Lite')

  return (
    <CuentaProvider account={account}>
      <div className="helios-lite min-h-dvh lg:p-4" style={{ '--lateral-ancho': '26rem' } as React.CSSProperties}>
        <div
          className={`lite-app mx-auto flex min-h-dvh max-w-[1680px] lg:min-h-[calc(100dvh-2rem)] ${
            lateral?.abierto ? 'xl:mr-(--lateral-ancho)' : ''
          }`}
        >
          <RielLite
            account={account}
            contadores={contadores}
            abierto={cajonAbierto}
            onCerrar={cerrarCajon}
          />

          <div className="flex min-w-0 flex-1 flex-col">
            <ToastProvider>
              <PageActionProvider nodo={slot}>
                <PageTitleProvider onChange={setTitulo}>
                  <BarraSuperiorLite
                    seccion={lugar?.seccion.titulo ?? title}
                    pagina={titulo ?? (lugar && lugar.pestana.rotulo !== lugar.seccion.titulo ? lugar.pestana.rotulo : null)}
                    asistente={asistente}
                    onAbrirCajon={() => setCajonAbierto(true)}
                    slotRef={setSlot}
                  />

                  <main
                    data-area={tonoDeRuta(pathname)}
                    className="flex-1 px-4 pt-5 pb-8 lg:px-9 lg:pt-7"
                  >
                    <div className={`mx-auto w-full ${TOPE[width]}`}>
                      <MaintenanceBanner />
                      {conCabecera && (
                        <CabeceraDeSeccion seccion={lugar.seccion} pathname={pathname} contadores={contadores} />
                      )}
                      {children}
                    </div>
                  </main>
                </PageTitleProvider>
              </PageActionProvider>
            </ToastProvider>
          </div>
        </div>

        {lateral?.abierto && (
          <div className="fixed inset-0 z-35 flex flex-col bg-panel-bar md:left-auto md:w-(--lateral-ancho) md:border-l md:border-panel-hairline md:shadow-2xl xl:shadow-none">
            {lateral.contenido}
          </div>
        )}
      </div>
    </CuentaProvider>
  )
}

/** Cuánto espera en las pestañas de una sección: el punto de su icono. */
function contadorDeSeccion(seccion: SeccionLite, contadores: Contadores): Contador | undefined {
  return sumarContadores(seccion.pestanas.map((p) => contadores[p.to]))
}

/**
 * La barra de la izquierda. De lg para arriba, 82 px de iconos con su nombre
 * al pasar el ratón; por debajo, un cajón ancho con los nombres escritos.
 */
function RielLite({
  account,
  contadores,
  abierto,
  onCerrar,
}: {
  account: Account
  contadores: Contadores
  abierto: boolean
  onCerrar: () => void
}) {
  const navigate = useNavigate()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const conexion = useConnectionStatus()
  const esCajon = useMediaQuery(ES_CAJON)
  const apagado = esCajon && !abierto
  const activa = ubicar(pathname)?.seccion.id

  useEffect(() => {
    onCerrar()
  }, [pathname, onCerrar])

  useEffect(() => {
    if (!abierto) return
    function onKey(event: KeyboardEvent) {
      if (event.key === 'Escape' && !event.defaultPrevented) onCerrar()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [abierto, onCerrar])

  async function salir() {
    await cerrarSesion()
    void navigate({ to: '/login' })
  }

  return (
    <>
      {abierto && (
        <button
          type="button"
          aria-label="Cerrar el menú"
          onClick={onCerrar}
          className="anim-velo fixed inset-0 z-30 bg-scrim/60 lg:hidden"
        />
      )}

      <aside
        inert={apagado}
        aria-hidden={apagado || undefined}
        className={`lite-riel fixed inset-y-0 left-0 z-40 flex w-62 flex-col pt-5 pb-3 transition-transform duration-200 lg:sticky lg:top-4 lg:h-[calc(100dvh-2rem)] lg:w-[82px] lg:translate-x-0 ${
          abierto ? 'translate-x-0' : '-translate-x-full'
        }`}
      >
        <div className="mx-4 flex shrink-0 flex-col gap-4 lg:mx-auto lg:items-center">
          <Link
            to="/admin"
            aria-label="Helios, Resumen"
            className="lite-marca flex size-11 items-center justify-center rounded-[14px]"
          >
            <HeliosIsotipo size={26} />
          </Link>
          <div className="lg:hidden">
            <InterruptorDeVersion />
          </div>
          <div className="hidden lg:block">
            <InterruptorDeVersion compacto />
          </div>
        </div>

        <nav aria-label="Menú" className="mt-6 flex flex-1 flex-col gap-1.5 overflow-y-auto px-3 lg:items-center">
          {PRINCIPALES.map((s) => (
            <EnlaceDeSeccion key={s.id} seccion={s} activa={activa === s.id} contador={contadorDeSeccion(s, contadores)} />
          ))}
          <hr className="mx-2 my-3 border-0 border-t border-panel-hairline lg:w-8" />
          <p className="px-3 pb-1 type-panel-overline text-panel-muted lg:hidden">Herramientas</p>
          {HERRAMIENTAS.map((s) => (
            <EnlaceDeSeccion key={s.id} seccion={s} activa={activa === s.id} contador={contadorDeSeccion(s, contadores)} />
          ))}
        </nav>

        {/* El pie de Pro, plegado: conexión, la cuenta, el tema y salir. */}
        <PieDelMenu account={account} estaActivo={() => false} conexion={conexion} plegado onSignOut={() => void salir()} />
      </aside>
    </>
  )
}

function EnlaceDeSeccion({
  seccion,
  activa,
  contador,
}: {
  seccion: SeccionLite
  activa: boolean
  contador?: Contador
}) {
  const Icono = seccion.icono
  return (
    <Link
      to={seccion.pestanas[0].to}
      title={seccion.titulo}
      aria-current={activa ? 'page' : undefined}
      className={`lite-enlace relative flex h-11 items-center gap-3 rounded-[14px] px-3 text-[0.9rem] font-medium lg:size-11 lg:justify-center lg:px-0 ${
        activa ? 'lite-enlace-activo' : ''
      }`}
    >
      <Icono size={19} strokeWidth={1.8} aria-hidden className="shrink-0" />
      <span className="min-w-0 flex-1 truncate lg:sr-only">{seccion.titulo}</span>
      {contador && <ContadorDelMenu contador={contador} plegado />}
    </Link>
  )
}

/**
 * Arriba: dónde se está («Operaciones › Pagos reportados»), el buscador del
 * panel (Ctrl K) en una cápsula al centro, el asistente si está encendido y
 * la acción de la pantalla.
 */
function BarraSuperiorLite({
  seccion,
  pagina,
  asistente,
  onAbrirCajon,
  slotRef,
}: {
  seccion: string
  pagina: string | null
  asistente?: ReactNode
  onAbrirCajon: () => void
  slotRef: (nodo: HTMLDivElement | null) => void
}) {
  const atajo = useAtajoDePaleta()

  return (
    <header className="lite-barra sticky top-0 z-20 flex min-h-17 shrink-0 flex-wrap items-center gap-3 px-4 py-2 lg:top-4 lg:px-9">
      <button
        type="button"
        onClick={onAbrirCajon}
        aria-label="Abrir el menú"
        className="inline-flex size-10 shrink-0 items-center justify-center rounded-panel-control text-on-surface-variant hover:bg-panel-raised lg:hidden"
      >
        <Menu size={18} aria-hidden />
      </button>

      <p className="min-w-0 flex-1 truncate text-[0.82rem] text-panel-muted lg:flex-none lg:basis-56">
        <strong className="font-semibold text-on-surface">{seccion}</strong>
        {pagina && <span> › {pagina}</span>}
      </p>

      <div className="flex min-w-0 flex-1 justify-center max-md:flex-none">
        <button
          type="button"
          onClick={() => abrirPaleta()}
          aria-haspopup="dialog"
          aria-label="Buscar en Helios"
          className="lite-capsula inline-flex h-10 min-w-0 items-center gap-2.5 rounded-full px-4 text-[0.84rem] md:w-full md:max-w-90"
        >
          <HeliosIsotipo size={18} className="lite-simbolo shrink-0" aria-hidden />
          <span className="min-w-0 flex-1 truncate text-left max-md:sr-only">Buscar en Helios…</span>
          <kbd className="hidden rounded-md border border-panel-hairline px-1.5 text-[0.7rem] text-panel-muted md:inline">
            {atajo}
          </kbd>
          <Search size={15} aria-hidden className="shrink-0 md:hidden" />
        </button>
      </div>

      <div className="flex shrink-0 items-center gap-2 lg:basis-56 lg:justify-end">
        {asistente}
        <div ref={slotRef} className="flex shrink-0 items-center gap-2 empty:hidden" />
      </div>
    </header>
  )
}

/** El título de la sección, lo que hay en ella y, si tiene varias, sus pestañas. */
function CabeceraDeSeccion({
  seccion,
  pathname,
  contadores,
}: {
  seccion: SeccionLite
  pathname: string
  contadores: Contadores
}) {
  return (
    <div className="mb-6">
      <h1 className="text-[1.75rem] font-semibold tracking-[-0.03em] text-on-surface">{seccion.titulo}</h1>
      <p className="mt-1 text-[0.86rem] text-panel-muted">{seccion.descripcion}</p>

      {seccion.pestanas.length > 1 && (
        <nav aria-label={`Vistas de ${seccion.titulo}`} className="lite-pestanas mt-5 flex gap-6 overflow-x-auto">
          {seccion.pestanas.map((p) => {
            const activa = esDeLaPestana(pathname, p)
            const contador = contadores[p.to]
            return (
              <Link
                key={p.to}
                to={p.to}
                aria-current={activa ? 'page' : undefined}
                className={`lite-pestana flex shrink-0 items-center gap-2 pb-3 text-[0.86rem] ${activa ? 'lite-pestana-activa' : ''}`}
              >
                {p.rotulo}
                {contador && <ContadorDelMenu contador={contador} />}
              </Link>
            )
          })}
        </nav>
      )}
    </div>
  )
}
