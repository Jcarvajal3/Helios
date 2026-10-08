import { createFileRoute, Outlet } from '@tanstack/react-router'

import { HeliosIsotipo, HeliosLogo } from '@/components/HeliosLogo'
import { StaffGate } from '@/components/StaffGate'
import { PanelShell } from '@/components/layouts/PanelShell'
import { merchantBarraInferiorFor, merchantNavGroupsFor } from '@/config/navigation'
import { ROLE_LABEL } from '@/features/auth/permissions'
import { useSession } from '@/features/auth/session'
import type { StaffContext } from '@/features/auth/session'
import { NO_INDEXAR } from '@/config/sitio'

export const Route = createFileRoute('/_comercio')({
  head: () => NO_INDEXAR,
  component: ComercioLayoutRoute,
})

/**
 * Layout route de todas las pantallas del panel de la clínica.
 * Envuelve con StaffGate (auth) y con el marco común.
 */
function ComercioLayoutRoute() {
  return (
    <StaffGate>
      {(staff) => (
        <ComercioShell staff={staff}>
          <Outlet />
        </ComercioShell>
      )}
    </StaffGate>
  )
}

/**
 * Componente propio y no una función suelta dentro del render prop de
 * `StaffGate`: ahí dentro los hooks se llamarían un número distinto de veces
 * según el estado del guarda —esqueleto, "esta cuenta no es de un comercio",
 * shell— y eso rompe las reglas de hooks.
 */
function ComercioShell({
  staff,
  children,
}: {
  staff: StaffContext
  children: React.ReactNode
}) {
  const session = useSession()

  return (
    <PanelShell
      groups={merchantNavGroupsFor(staff.role)}
      barraInferior={merchantBarraInferiorFor(staff.role)}
      logo={(plegado) => (
        <LogoDeHelios clinica={staff.merchantName} plegado={plegado} />
      )}
      account={{
        // El correo es lo que distingue a una secretaria de otra: la base no
        // guarda el nombre del personal, solo su rol dentro de la clínica.
        name: session?.user.email ?? staff.branchName,
        detail: ROLE_LABEL[staff.role],
      }}
    >
      {children}
    </PanelShell>
  )
}

/**
 * El logo de Helios en la cabecera del menú, suelto y sin tarjeta, como en el
 * panel de admin: el panel es de Helios, la clínica lo usa.
 *
 * El nombre de la clínica queda en el `title`, para quien dude de en qué
 * cuenta ha entrado. Plegada la barra, a 64 px no cabe el logotipo entero y
 * queda el isotipo.
 */
function LogoDeHelios({ clinica, plegado }: { clinica: string; plegado: boolean }) {
  return (
    <div title={`Helios · ${clinica}`} className="flex items-center">
      {/* Envueltos: el SVG del logo trae `display` en línea y una clase no
          podría esconderlo. */}
      <span className={`flex ${plegado ? 'lg:hidden' : ''}`}>
        <HeliosLogo height={22} />
      </span>
      {plegado && (
        <span className="hidden lg:flex">
          <HeliosIsotipo size={26} />
        </span>
      )}
    </div>
  )
}
