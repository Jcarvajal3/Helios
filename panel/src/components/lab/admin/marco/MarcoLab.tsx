import { Navigate, Outlet, useLocation } from '@tanstack/react-router'

import { PanelShell } from '@/components/layouts/PanelShell'
import { HeliosIsotipo, HeliosLogo } from '@/components/HeliosLogo'
import { Badge } from '@/components/ui'
import { menuDelDriver, menuDelEquipoLab, pieDelEquipoLab } from '@/components/lab/admin/marco/menu'
import { accesoDeLab, rutaPermitidaAlDriver, RUTA_DEL_DRIVER } from '@/features/lab/operacion'
import { useSession } from '@/features/auth/session'
import type { PlatformAdmin } from '@/features/admin/api'
import { entorno } from '@/lib/entorno'

const ROTULO_DE_ROL: Record<string, string> = {
  super_admin: 'Super admin',
  operador: 'Operador',
  driver: 'Driver',
}

/**
 * El marco de Helios Lab: el mismo `PanelShell` del panel con otro menú y otra
 * identidad. Decide quién ve qué:
 *
 *   super_admin y operador → todas las secciones, y un enlace de vuelta al panel
 *   driver                 → solo `/lab/ruta` (cualquier otra dirección lo lleva ahí)
 *   agenda, capacitador y cobranza → no entran; vuelven a su panel
 *
 * Es solo la pantalla: las RPC `admin_lab_*` comprueban el rol en la base.
 */
export function MarcoLab({ admin }: { admin: PlatformAdmin }) {
  const session = useSession()
  const { pathname } = useLocation()
  const acceso = accesoDeLab(admin.role)

  if (acceso === 'ninguno') return <Navigate to="/admin" replace />
  if (acceso === 'solo_ruta' && !rutaPermitidaAlDriver(pathname)) {
    return <Navigate to={RUTA_DEL_DRIVER} replace />
  }

  const esDriver = acceso === 'solo_ruta'
  const rol = ROTULO_DE_ROL[admin.role] ?? 'Equipo'

  return (
    <PanelShell
      groups={esDriver ? menuDelDriver : menuDelEquipoLab}
      pie={esDriver ? undefined : pieDelEquipoLab}
      sitio="Helios Lab"
      logo={(plegado) => <LogoDeLab plegado={plegado} />}
      account={{
        name: admin.fullName ?? session?.user.email ?? 'Equipo de Helios',
        detail: rol,
        nombreCompleto: admin.fullName,
      }}
    >
      <Outlet />
    </PanelShell>
  )
}

/** El logo de Helios con el rótulo «Lab»; plegada la barra, solo el isotipo. */
function LogoDeLab({ plegado }: { plegado: boolean }) {
  return (
    <div
      title={plegado ? 'Helios Lab' : undefined}
      className={`flex items-center gap-2 ${plegado ? 'lg:flex-col lg:gap-1.5' : ''}`}
    >
      <span className={`flex ${plegado ? 'lg:hidden' : ''}`}>
        <HeliosLogo height={22} />
      </span>
      {plegado && (
        <span className="hidden lg:flex">
          <HeliosIsotipo size={26} />
        </span>
      )}
      <Badge tone="brand" className={plegado ? 'lg:hidden' : ''}>
        Lab
      </Badge>
      {entorno() === 'desarrollo' && <Badge tone="warning">DEV</Badge>}
    </div>
  )
}
