import { useState } from 'react'
import { createFileRoute, Outlet } from '@tanstack/react-router'

import { StaffGate } from '@/components/StaffGate'
import { PanelShell } from '@/components/layouts/PanelShell'
import { merchantNavGroupsFor } from '@/config/navigation'
import { ROLE_LABEL } from '@/features/auth/permissions'
import { useSession } from '@/features/auth/session'
import type { StaffContext } from '@/features/auth/session'

export const Route = createFileRoute('/_comercio')({
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
      logo={(plegado) => (
        <MerchantLogo
          name={staff.merchantName}
          logoUrl={staff.merchantLogoUrl}
          plegado={plegado}
        />
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
 * El logo del local en la cabecera de la barra, con el nombre como respaldo.
 *
 * El respaldo no es un detalle: el logo es opcional en la ficha del comercio
 * y la imagen puede fallar al cargar. Un hueco vacío donde debería estar la
 * identidad del local hace dudar de en qué cuenta se ha entrado.
 *
 * Plegada la barra no caben ni el logo ni el nombre, así que queda la
 * inicial: sigue diciendo de qué local es el panel, que es lo único que esta
 * caja tiene que contestar.
 */
function MerchantLogo({
  name,
  logoUrl,
  plegado,
}: {
  name: string
  logoUrl: string | null
  plegado: boolean
}) {
  const [broken, setBroken] = useState(false)

  return (
    <div
      title={plegado ? name : undefined}
      className={`flex h-11 items-center justify-center overflow-hidden rounded-[var(--radius-panel-card)] bg-shell-card px-3 ${
        plegado ? 'lg:px-0' : ''
      }`}
    >
      {logoUrl && !broken ? (
        <img
          src={logoUrl}
          alt={name}
          onError={() => setBroken(true)}
          className="max-h-full max-w-full object-contain"
        />
      ) : (
        <span className="type-panel-section truncate tracking-wide text-on-surface">
          <span className={plegado ? 'lg:hidden' : undefined}>{name.toUpperCase()}</span>
          {plegado && <span className="hidden lg:inline">{name.slice(0, 1).toUpperCase()}</span>}
        </span>
      )}
    </div>
  )
}
