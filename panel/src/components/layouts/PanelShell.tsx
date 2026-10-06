import { useCallback, useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { useRouterState } from '@tanstack/react-router'

import { MaintenanceBanner } from '@/components/MaintenanceBanner'
import { BarraInferior } from '@/components/layouts/BarraInferior'
import { ToastProvider } from '@/components/Toast'
import { PageActionProvider, PageTitleProvider } from '@/components/layouts/PageAction'
import { Sidebar } from '@/components/layouts/Sidebar'
import { Topbar } from '@/components/layouts/Topbar'
import type { NavGroup, NavItem } from '@/config/navigation'
import { tonoDeRuta } from '@/features/admin/areas'
import type { Contador } from '@/components/layouts/contadores'
import { CuentaProvider } from '@/components/layouts/cuenta'
import type { Account } from '@/components/layouts/cuenta'
import { useMarcoDeLaRuta } from '@/components/layouts/staticData'
import type { PageWidth } from '@/components/layouts/staticData'

export type { PageWidth } from '@/components/layouts/staticData'

/** Dónde se recuerda si la barra quedó plegada. */
const CLAVE_PLEGADO = 'helios-panel:sidebar-plegado'

/** El ancho del cajón de la derecha: una columna de conversación cómoda. */
const ANCHO_LATERAL = '26rem'

/** El tope del contenido según lo que declare la ruta (`staticData.width`). */
const TOPE: Record<PageWidth, string> = {
  wide: 'max-w-(--panel-measure-wide)',
  ficha: 'max-w-(--panel-measure-ficha)',
  normal: 'max-w-(--panel-measure-normal)',
}

/**
 * El marco de los dos paneles.
 *
 * Antes eran dos: `AdminLayout` para el local y un shell escrito a mano
 * dentro de `admin.tsx` para el equipo. Se copiaron el uno del otro y ya
 * habían empezado a separarse solos. Ahora es uno y la diferencia viaja en
 * las props, que es donde se puede leer.
 *
 * Pone `data-area` en `<main>` con el tono del área de la ruta: todo lo que
 * lee `bg-area` o `var(--area)` dentro de la pantalla sale en su color sin
 * pasar props. Y reparte la cuenta que ha entrado (`useCuentaDelPanel`).
 */
export function PanelShell({
  groups,
  pie,
  logo,
  account,
  sitio = 'Helios',
  contadores,
  search,
  asistente,
  lateral,
  barraInferior,
  children,
  className = '',
}: {
  groups: NavGroup[]
  /** Lo que va al pie del menú, junto a la cuenta. Solo lo pasa el super admin. */
  pie?: ReadonlyArray<NavItem>
  /**
   * La identidad de la cabecera de la barra: el logo del local, o el de Ronda.
   * Recibe si la barra está plegada porque a 64 px no cabe un nombre y hay que
   * enseñar una marca, no un nombre recortado a tres letras.
   */
  logo: (plegado: boolean) => ReactNode
  account: Account
  /** Lo que acompaña al título en la pestaña del navegador. */
  sitio?: string
  /** Cuántos esperan en cada cola, por `path`. Solo lo pasa el super admin. */
  contadores?: Partial<Record<string, Contador>>
  /** El buscador global. Solo lo pasa el super admin. */
  search?: ReactNode
  /** El botón del asistente en la barra de arriba. Solo lo pasa el super admin. */
  asistente?: ReactNode
  /**
   * Un cajón a la derecha, de todo el alto: hoy, la conversación con el
   * asistente. No es modal: desde 1280 px aparta el contenido en vez de
   * taparlo, para leer la respuesta con la pantalla al lado; entre 768 y
   * 1280 px se pone encima, y por debajo ocupa la pantalla entera.
   */
  lateral?: { abierto: boolean; contenido: ReactNode }
  /**
   * Las pantallas de la barra de abajo del teléfono (por debajo de 768 px).
   * Solo la pasa la clínica: con ella la hamburguesa de arriba sobra en el
   * teléfono, porque «Menú» abre el mismo cajón desde abajo.
   */
  barraInferior?: ReadonlyArray<NavItem>
  children: ReactNode
  /**
   * Del marco entero hacia abajo. Va aquí y no en cada pantalla porque las
   * variables se heredan, así que puesta en la raíz alcanza a todo el kit de
   * una vez.
   */
  className?: string
}) {
  const [plegado, setPlegado] = useState(false)
  const [cajonAbierto, setCajonAbierto] = useState(false)
  const [slot, setSlot] = useState<HTMLDivElement | null>(null)

  // El estado plegado se lee DESPUÉS de montar y no al construir el estado
  // inicial: esto se renderiza también en el servidor, donde no hay
  // localStorage, y sembrar el estado desde allí revienta la hidratación.
  useEffect(() => {
    try {
      setPlegado(window.localStorage.getItem(CLAVE_PLEGADO) === '1')
    } catch {
      // Modo privado o almacenamiento bloqueado: la barra sale ancha, que es
      // el valor por defecto de todas formas.
    }
  }, [])

  // Estable, como `cerrarCajon`: el Sidebar lo pasa a un botón y nada más,
  // pero así no se repinta la cabecera del menú en cada render del marco.
  const alternarPlegado = useCallback(() => {
    setPlegado((previo) => {
      const siguiente = !previo
      try {
        window.localStorage.setItem(CLAVE_PLEGADO, siguiente ? '1' : '0')
      } catch {
        // Se pierde entre recargas y no pasa nada.
      }
      return siguiente
    })
  }, [])

  // Estable, porque el Sidebar lo tiene en las dependencias de dos efectos:
  // uno que cierra el cajón al cambiar de pantalla y otro que escucha Escape.
  const cerrarCajon = useCallback(() => setCajonAbierto(false), [])

  const { title, width, inmersiva } = useMarcoDeLaRuta()
  const pathname = useRouterState({ select: (s) => s.location.pathname })

  // Lo que una página de detalle dice cuando ya sabe cómo se llama lo que
  // enseña. `null` es "lo que diga la ruta".
  const [titulo, setTitulo] = useState<string | null>(null)

  useTituloDeLaPestana(titulo ?? title, sitio)

  return (
    <CuentaProvider account={account}>
      <div
        // `--hueco-inferior`: lo que tapa la barra de abajo en el teléfono.
        // Lo leen el contenido, para que lo último no quede debajo, y los
        // avisos, para salir por encima de ella.
        className={`min-h-dvh ${
          barraInferior ? 'max-md:[--hueco-inferior:calc(4rem+env(safe-area-inset-bottom))]' : ''
        } ${className}`}
        style={
          {
            '--sidebar-actual': plegado
              ? 'var(--sidebar-width-plegado)'
              : 'var(--sidebar-width)',
            '--lateral-ancho': ANCHO_LATERAL,
          } as React.CSSProperties
        }
      >
        <Sidebar
          groups={groups}
          pie={pie}
          logoSlot={logo(plegado)}
          account={account}
          contadores={contadores}
          plegado={plegado}
          abierto={cajonAbierto}
          onCerrar={cerrarCajon}
          onPlegar={alternarPlegado}
        />

        <div
          className={`flex min-h-dvh flex-col transition-[margin] duration-200 lg:ml-(--sidebar-actual) ${
            lateral?.abierto ? 'xl:mr-(--lateral-ancho)' : ''
          }`}
        >
          <ToastProvider>
            <PageActionProvider nodo={slot}>
              <PageTitleProvider onChange={setTitulo}>
                <Topbar
                  title={titulo ?? title}
                  search={search}
                  asistente={asistente}
                  inmersiva={inmersiva}
                  conBarraInferior={!!barraInferior}
                  onAbrirCajon={() => setCajonAbierto(true)}
                  slotRef={setSlot}
                />

                <main
                  data-area={tonoDeRuta(pathname)}
                  className={`flex-1 px-4 pt-5 pb-[calc(1.25rem+var(--hueco-inferior,0px))] lg:px-8 lg:py-6 ${inmersiva ? 'flex flex-col' : ''}`}
                >
                  {/* En una pantalla inmersiva el contenido es una columna que
                      ocupa todo el alto: Inicio centra su barra en lo que
                      sobra debajo de lo pendiente. */}
                  <div
                    className={`mx-auto w-full ${TOPE[width]} ${inmersiva ? 'flex flex-1 flex-col' : ''}`}
                  >
                    {/* Antes que el contenido: el cajero tiene que saber que
                        los cobros están parados ANTES de teclear la orden, no
                        al sacar el QR; y para el equipo no es un aviso sino un
                        recordatorio, porque un mantenimiento olvidado
                        encendido es una noche sin ventas. */}
                    <MaintenanceBanner />
                    {children}
                  </div>
                </main>
              </PageTitleProvider>
            </PageActionProvider>
          </ToastProvider>
        </div>

        {barraInferior && (
          <BarraInferior
            items={barraInferior}
            menuAbierto={cajonAbierto}
            onMenu={() => setCajonAbierto(true)}
          />
        )}

        {/* Por encima de la barra de arriba (z-20) y por debajo del menú en
            cajón (z-40) y de las ventanas (z-50). */}
        {lateral?.abierto && (
          <div className="fixed inset-0 z-35 flex flex-col bg-panel-bar md:left-auto md:w-(--lateral-ancho) md:border-l md:border-panel-hairline md:shadow-2xl xl:shadow-none">
            {lateral.contenido}
          </div>
        )}
      </div>
    </CuentaProvider>
  )
}

/**
 * El título de la pestaña del navegador: «Riesgo de crédito · Ronda Admin».
 *
 * Era siempre «Ronda Comercios», la del `<head>` de la raíz, y con cuatro
 * pestañas del panel abiertas no había forma de saber cuál era cuál. Se pone
 * aquí y no en el `head` de cada ruta porque el título de una ficha (el nombre
 * de la persona) solo se sabe al llegar la consulta.
 *
 * Al salir del panel se devuelve el que había: el `<head>` de la raíz no
 * vuelve a escribirlo, porque para React no ha cambiado. Solo si nadie lo ha
 * cambiado entretanto: si la ruta de destino trae el suyo (la portada), ya
 * está puesto cuando esto se limpia, y no hay que pisarlo.
 */
function useTituloDeLaPestana(titulo: string, sitio: string) {
  useEffect(() => {
    const anterior = document.title
    const puesto = titulo ? `${titulo} · ${sitio}` : sitio
    document.title = puesto
    return () => {
      if (document.title === puesto) document.title = anterior
    }
  }, [titulo, sitio])
}
