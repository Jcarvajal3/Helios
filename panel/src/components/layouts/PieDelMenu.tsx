import { Link } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import { LogOut, Monitor, Moon, Sun } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'
import type { ReactNode } from 'react'

import { ConnectionIndicator, PuntoDeConexion } from '@/components/ConnectionIndicator'
import type { ConnectionStatus } from '@/components/ConnectionIndicator'
import type { NavItem } from '@/config/navigation'
import { aplicarTema, siguienteTema, temaGuardado } from '@/lib/tema'
import type { Tema } from '@/lib/tema'
import { iniciales } from './cuenta'
import type { Account } from './cuenta'
import { RayaDelActivo, areaDelItem } from './EnlaceDelMenu'

/**
 * El pie del menú: lo que se ponga suelto, la conexión, quién ha entrado y el
 * tema (claro, oscuro o el del sistema).
 *
 * Todo lo de aquí va un paso más apagado que los enlaces de arriba: se usa
 * poco, y no puede competir con las pantallas de trabajo.
 */
export function PieDelMenu({
  items = [],
  estaActivo,
  account,
  conexion,
  plegado,
  onSignOut,
}: {
  items?: ReadonlyArray<NavItem>
  estaActivo: (item: NavItem) => boolean
  account: Account
  conexion: ConnectionStatus
  plegado: boolean
  onSignOut: () => void
}) {
  return (
    <div className="mx-3 mt-2 flex shrink-0 flex-col gap-2 border-t border-panel-hairline pt-2.5">
      {items.map((item) => {
        const activo = estaActivo(item)
        return (
          <Link
            key={item.path}
            to={item.path}
            data-area={areaDelItem(item)}
            title={plegado ? item.label : undefined}
            className={`${claseDeFila(plegado)} ${
              activo
                ? 'bg-panel-raised text-on-surface'
                : 'text-panel-muted hover:bg-panel-card hover:text-on-surface'
            }`}
          >
            {activo && <RayaDelActivo />}
            <Contenido icon={item.icon} plegado={plegado}>
              {item.label}
            </Contenido>
          </Link>
        )
      })}

      <ConnectionIndicator estado={conexion} plegado={plegado} />

      <Cuenta account={account} conexion={conexion} plegado={plegado} onSignOut={onSignOut} />
    </div>
  )
}

/** Una fila del pie: más baja, más pequeña y más apagada que un enlace de arriba. */
function claseDeFila(plegado: boolean): string {
  return `relative flex h-7.5 items-center gap-2.5 rounded-panel-control px-2.5 type-panel-label transition-colors duration-(--transition-fast) ${
    plegado ? 'lg:justify-center lg:px-0' : ''
  }`
}

function Contenido({
  icon: Icon,
  plegado,
  children,
}: {
  icon: LucideIcon
  plegado: boolean
  children: ReactNode
}) {
  return (
    <>
      <Icon size={16} strokeWidth={1.75} aria-hidden className="shrink-0" />
      <span className={`min-w-0 truncate ${plegado ? 'lg:hidden' : ''}`}>{children}</span>
    </>
  )
}

/**
 * El bloque de identidad: iniciales, nombre y rol, con la conexión como un
 * punto sobre el avatar.
 *
 * Cerrar sesión es un icono al lado y no un menú desplegable porque hay
 * exactamente una acción: un menú de un solo ítem es un clic de más para
 * esconder algo que cabía a la vista.
 */
function Cuenta({
  account,
  conexion,
  plegado,
  onSignOut,
}: {
  account: Account
  conexion: ConnectionStatus
  plegado: boolean
  onSignOut: () => void
}) {
  // «Conectado» se escribe solo cuando lo está: sin conexión ya lo dice, en
  // rojo, la fila de encima.
  const detalle = conexion === 'online' ? `${account.detail} · conectado` : account.detail

  return (
    <div
      className={`flex items-center gap-2.5 pt-1 pr-1.5 pl-2 ${
        plegado ? 'lg:flex-col lg:gap-1.5 lg:px-0' : ''
      }`}
    >
      <span
        aria-hidden
        title={plegado ? `${account.name} · ${detalle}` : undefined}
        className="relative flex size-8 shrink-0 items-center justify-center rounded-full bg-panel-control type-panel-caption font-bold text-on-surface"
      >
        {iniciales(account.name)}
        <PuntoDeConexion estado={conexion} />
      </span>

      <div className={`min-w-0 flex-1 ${plegado ? 'lg:hidden' : ''}`}>
        <p className="truncate type-panel-body font-semibold text-on-surface">{account.name}</p>
        <p className="truncate type-panel-caption text-panel-muted">{detalle}</p>
      </div>

      <BotonDeTema />

      <button
        type="button"
        onClick={onSignOut}
        aria-label="Cerrar sesión"
        title="Cerrar sesión"
        className="inline-flex size-8 shrink-0 items-center justify-center rounded-panel-control text-panel-muted transition-colors duration-(--transition-fast) hover:bg-panel-card hover:text-on-surface"
      >
        <LogOut size={16} strokeWidth={1.75} aria-hidden />
      </button>
    </div>
  )
}

const ICONO_DEL_TEMA: Record<Tema, LucideIcon> = { claro: Sun, oscuro: Moon, sistema: Monitor }
const NOMBRE_DEL_TEMA: Record<Tema, string> = {
  claro: 'Tema claro',
  oscuro: 'Tema oscuro',
  sistema: 'Tema del sistema',
}

/**
 * Claro → oscuro → el del sistema. Un solo botón y no un menú: son tres
 * estados y se recorren con dos clics como mucho. El tema se lee después de
 * montar: en el servidor no hay localStorage.
 */
function BotonDeTema() {
  const [tema, setTema] = useState<Tema>('claro')
  useEffect(() => setTema(temaGuardado()), [])

  const Icono = ICONO_DEL_TEMA[tema]
  const siguiente = siguienteTema(tema)

  return (
    <button
      type="button"
      onClick={() => {
        aplicarTema(siguiente)
        setTema(siguiente)
      }}
      aria-label={`${NOMBRE_DEL_TEMA[tema]}. Cambiar a ${NOMBRE_DEL_TEMA[siguiente].toLowerCase()}`}
      title={`${NOMBRE_DEL_TEMA[tema]} · pulsa para ${NOMBRE_DEL_TEMA[siguiente].toLowerCase()}`}
      className="inline-flex size-8 shrink-0 items-center justify-center rounded-panel-control text-panel-muted transition-colors duration-(--transition-fast) hover:bg-panel-card hover:text-on-surface"
    >
      <Icono size={16} strokeWidth={1.75} aria-hidden />
    </button>
  )
}
