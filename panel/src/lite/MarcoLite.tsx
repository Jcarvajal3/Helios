import { useCallback, useEffect, useRef, useState } from 'react'
import type { CSSProperties, ReactNode } from 'react'
import { Link, useNavigate, useRouterState } from '@tanstack/react-router'
import { LogOut, Menu } from 'lucide-react'

import { abrirPaleta, useAtajoDePaleta } from '@/components/admin/paleta'
import { useConnectionStatus } from '@/components/ConnectionIndicator'
import { HeliosIsotipo } from '@/components/HeliosLogo'
import { MaintenanceBanner } from '@/components/MaintenanceBanner'
import { ToastProvider } from '@/components/Toast'
import { PageActionProvider, PageTitleProvider } from '@/components/layouts/PageAction'
import { useTituloDeLaPestana } from '@/components/layouts/PanelShell'
import { sumarContadores } from '@/components/layouts/contadores'
import type { Contador } from '@/components/layouts/contadores'
import { CuentaProvider, iniciales } from '@/components/layouts/cuenta'
import type { Account } from '@/components/layouts/cuenta'
import { useMarcoDeLaRuta } from '@/components/layouts/staticData'
import { tonoDeRuta } from '@/features/admin/areas'
import { ES_CAJON, useMediaQuery } from '@/lib/media'
import { cerrarSesion } from '@/lib/supabase'
import { InterruptorDeVersion } from './InterruptorDeVersion'
import { HERRAMIENTAS, PRINCIPALES, esDeLaPestana, ubicar } from './menu'
import type { SeccionLite } from './menu'
import './estilos/maqueta.css'
import './estilos/vestido.css'

type Contadores = Partial<Record<string, Contador>>

/**
 * El marco de Helios Lite, como la maqueta: la app es una tarjeta blanca
 * sobre el lienzo celeste, con una barra de iconos redondos a la izquierda,
 * arriba la cápsula de Helios Intelligence (el buscador, Ctrl K) y, en cada
 * sección, su título y sus vistas en píldoras. Lo de dentro es la pantalla
 * de Pro de esa ruta, tal cual.
 *
 * Mientras está montado pone `data-helios-lite` en `<html>`: de ese atributo
 * cuelga todo el estilo de `estilos/`. Y pone el tema claro (la maqueta no
 * tiene oscuro); al salir devuelve el que había.
 *
 * Comparte con Pro las piezas, no el dibujo: la cuenta, los avisos, la
 * acción de la pantalla, el título de la pestaña y el aviso de
 * mantenimiento.
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
  const [barraAbierta, setBarraAbierta] = useState(false)
  const [slot, setSlot] = useState<HTMLDivElement | null>(null)
  const [titulo, setTitulo] = useState<string | null>(null)
  const cerrarBarra = useCallback(() => setBarraAbierta(false), [])

  const { title, width } = useMarcoDeLaRuta()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const vista = useRouterState({ select: (s) => vistaDe(s.location.search) })
  const lugar = ubicar(pathname, vista)

  useEstiloDeLite()
  useTituloDeLaPestana(titulo ?? (lugar?.pestana.rotulo || title), 'Helios Lite')

  // La barra (cajón en el teléfono) se cierra al cambiar de pantalla y con Escape.
  useEffect(() => cerrarBarra(), [pathname, cerrarBarra])
  useEffect(() => {
    if (!barraAbierta) return
    const alTeclear = (e: KeyboardEvent) => e.key === 'Escape' && !e.defaultPrevented && cerrarBarra()
    document.addEventListener('keydown', alTeclear)
    return () => document.removeEventListener('keydown', alTeclear)
  }, [barraAbierta, cerrarBarra])

  return (
    <CuentaProvider account={account}>
      <div className="lt-raiz" style={lateral?.abierto ? ({ paddingRight: 'min(26rem, 100vw)' }) : undefined}>
        <div className="lt-app">
          {barraAbierta && <button type="button" className="lt-velo" aria-label="Cerrar el menú" onClick={cerrarBarra} />}

          <BarraDeIconos account={account} contadores={contadores} pathname={pathname} abierta={barraAbierta} />

          <div className="lt-principal">
            <ToastProvider>
              <PageActionProvider nodo={slot}>
                <PageTitleProvider onChange={setTitulo}>
                  <Arriba asistente={asistente} onAbrirBarra={() => setBarraAbierta(true)} slotRef={setSlot} />

                  <main data-area={tonoDeRuta(pathname)} className="lt-contenido">
                    <div className="lt-medida" style={{ maxWidth: `var(--panel-measure-${width})` }}>
                      <MaintenanceBanner />
                      {lugar && !lugar.seccion.cabeceraPropia && (
                        <Cabecera
                          seccion={lugar.seccion}
                          ruta={titulo}
                          pathname={pathname}
                          vista={vista}
                          contadores={contadores}
                        />
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
          <div className="fixed inset-0 z-35 flex flex-col bg-panel-bar md:left-auto md:w-(--lateral-ancho) md:border-l md:border-panel-hairline" style={{ '--lateral-ancho': '26rem' } as CSSProperties}>
            {lateral.contenido}
          </div>
        )}
      </div>
    </CuentaProvider>
  )
}

/** La `vista` de la búsqueda de la ruta, si es un texto. */
function vistaDe(search: unknown): string | undefined {
  const v = (search as Record<string, unknown> | undefined)?.vista
  return typeof v === 'string' ? v : undefined
}

/** Pone `data-helios-lite` y el tema claro en `<html>` mientras Lite está en pantalla. */
function useEstiloDeLite() {
  useEffect(() => {
    const raiz = document.documentElement
    const temaDeAntes = raiz.dataset.theme
    raiz.dataset.heliosLite = ''
    raiz.dataset.theme = 'light'
    return () => {
      delete raiz.dataset.heliosLite
      if (temaDeAntes === undefined) delete raiz.dataset.theme
      else raiz.dataset.theme = temaDeAntes
    }
  }, [])
}

/** Cuánto espera en las pestañas de una sección: el punto de su icono. */
function contadorDeSeccion(seccion: SeccionLite, contadores: Contadores): Contador | undefined {
  return sumarContadores(seccion.pestanas.map((p) => contadores[p.to]))
}

/**
 * Los iconos redondos de la maqueta: arriba la marca y Pro/Lite, después las
 * cuatro áreas y, tras una raya, las herramientas. El nombre sale al pasar el
 * ratón. Abajo, el avatar con la cuenta.
 */
function BarraDeIconos({
  account,
  contadores,
  pathname,
  abierta,
}: {
  account: Account
  contadores: Contadores
  pathname: string
  abierta: boolean
}) {
  const activa = ubicar(pathname)?.seccion.id
  // En el teléfono, cerrada, la barra está fuera de la pantalla: que no reciba el tabulador.
  const apagada = useMediaQuery(ES_CAJON) && !abierta

  return (
    <aside className="lt-barra" data-abierta={abierta || undefined} inert={apagada} aria-label="Menú">
      <div className="lt-marca">
        <Link to="/admin" aria-label="Helios, Resumen">
          <HeliosIsotipo size={24} style={{ filter: 'brightness(0) invert(1)' }} aria-hidden />
        </Link>
      </div>

      <InterruptorDeVersion estilo="lite" />

      {[PRINCIPALES, HERRAMIENTAS].map((grupo, i) => (
        <nav key={i} className="lt-nav" aria-label={i === 0 ? 'Áreas' : 'Herramientas'}>
          {grupo.map((s) => {
            const Icono = s.icono
            const contador = contadorDeSeccion(s, contadores)
            return (
              <Link
                key={s.id}
                to={s.pestanas[0].to}
                aria-label={s.titulo}
                aria-current={activa === s.id ? 'page' : undefined}
                className="lt-boton-nav"
              >
                <Icono strokeWidth={1.8} aria-hidden />
                {contador && contador.n > 0 && <span className="lt-punto" data-urgente={contador.urgente || undefined} />}
                <span className="lt-nombre" aria-hidden>
                  {s.titulo}
                </span>
              </Link>
            )
          })}
        </nav>
      ))}

      <div className="lt-pie-barra">
        <Cuenta account={account} />
      </div>
    </aside>
  )
}

/** El avatar de la maqueta; al pulsarlo, quién eres, la conexión y salir. */
function Cuenta({ account }: { account: Account }) {
  const [abierta, setAbierta] = useState(false)
  const caja = useRef<HTMLDivElement>(null)
  const navigate = useNavigate()
  const conexion = useConnectionStatus()

  useEffect(() => {
    if (!abierta) return
    const fuera = (e: PointerEvent) => {
      if (!caja.current?.contains(e.target as Node)) setAbierta(false)
    }
    const alTeclear = (e: KeyboardEvent) => e.key === 'Escape' && setAbierta(false)
    document.addEventListener('pointerdown', fuera)
    document.addEventListener('keydown', alTeclear)
    return () => {
      document.removeEventListener('pointerdown', fuera)
      document.removeEventListener('keydown', alTeclear)
    }
  }, [abierta])

  async function salir() {
    await cerrarSesion()
    void navigate({ to: '/login' })
  }

  const estado = { online: 'conectado', degraded: 'conexión lenta', offline: 'sin conexión' }[conexion]

  return (
    <div ref={caja} style={{ position: 'relative' }}>
      <button
        type="button"
        className="lt-avatar"
        aria-haspopup="menu"
        aria-expanded={abierta}
        aria-label={`${account.name} · ${account.detail}`}
        title={`${account.name} · ${account.detail}`}
        onClick={() => setAbierta((a) => !a)}
      >
        {iniciales(account.name)}
      </button>
      {abierta && (
        <div className="lt-menu" role="menu">
          <p>
            <strong>{account.name}</strong>
            {account.detail} · {estado}
          </p>
          <button type="button" role="menuitem" onClick={() => void salir()}>
            <LogOut size={14} aria-hidden /> Cerrar sesión
          </button>
        </div>
      )}
    </div>
  )
}

/**
 * La barra de arriba de la maqueta: al centro la cápsula de Helios
 * Intelligence, que abre la paleta del panel (buscar o ir a, y preguntar si
 * el asistente está encendido); a la derecha el asistente y la acción de la
 * pantalla.
 */
function Arriba({
  asistente,
  onAbrirBarra,
  slotRef,
}: {
  asistente?: ReactNode
  onAbrirBarra: () => void
  slotRef: (nodo: HTMLDivElement | null) => void
}) {
  const atajo = useAtajoDePaleta()

  return (
    <header className="lt-arriba">
      <div className="lt-arriba-lado">
        <button type="button" className="lt-abrir-menu" aria-label="Abrir el menú" onClick={onAbrirBarra}>
          <Menu size={18} aria-hidden />
        </button>
      </div>

      <button
        type="button"
        className="lt-capsula"
        aria-haspopup="dialog"
        aria-label="Helios Intelligence: buscar en el panel"
        onClick={() => abrirPaleta()}
      >
        <HeliosIsotipo size={22} aria-hidden />
        <span>Helios Intelligence</span>
        <kbd>{atajo}</kbd>
      </button>

      <div className="lt-arriba-lado">
        {asistente}
        <div ref={slotRef} style={{ display: 'flex', alignItems: 'center', gap: 8 }} />
      </div>
    </header>
  )
}

/**
 * La cabecera de una sección, como la de la maqueta: el título, lo que hay
 * en ella y, si tiene varias vistas, las píldoras. En una ficha, encima del
 * título, dónde se está («Pacientes › Ana Pérez»).
 */
function Cabecera({
  seccion,
  ruta,
  pathname,
  vista,
  contadores,
}: {
  seccion: SeccionLite
  ruta: string | null
  pathname: string
  /** La `?vista=` de la dirección: elige entre las pestañas que comparten ruta. */
  vista: string | undefined
  contadores: Contadores
}) {
  const pestana = seccion.pestanas.find((p) => esDeLaPestana(pathname, vista, p, seccion.pestanas))
  const enFicha = pestana !== undefined && pathname !== pestana.to

  return (
    <>
      <div className="lt-cabecera">
        <div>
          {enFicha && (
            <p className="lt-ruta">
              {pestana.rotulo}
              {ruta ? ` › ${ruta}` : ''}
            </p>
          )}
          <h1>{seccion.titulo}</h1>
          <p>{seccion.descripcion}</p>
        </div>
      </div>

      {seccion.pestanas.length > 1 && (
        <nav className="lt-pestanas" aria-label={`Vistas de ${seccion.titulo}`}>
          {seccion.pestanas.map((p) => {
            // El contador de una ruta va en su primera pestaña, no en las de sus vistas.
            const contador = p.vista ? undefined : contadores[p.to]
            return (
              <Link
                key={`${p.to}?${p.vista ?? ''}`}
                to={p.to}
                search={(p.vista ? { vista: p.vista } : {}) as never}
                className="lt-pestana"
                aria-current={esDeLaPestana(pathname, vista, p, seccion.pestanas) ? 'page' : undefined}
              >
                {p.rotulo}
                {contador && contador.n > 0 && (
                  <span className="lt-cuenta" data-urgente={contador.urgente || undefined}>
                    {contador.n > 99 ? '99+' : contador.n}
                  </span>
                )}
              </Link>
            )
          })}
        </nav>
      )}
    </>
  )
}
