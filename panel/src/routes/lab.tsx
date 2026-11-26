import { createFileRoute } from '@tanstack/react-router'

import { MarcoLab } from '@/components/lab/admin/marco/MarcoLab'
import { PlatformGate } from '@/components/PlatformGate'
import { NO_INDEXAR } from '@/config/sitio'

/**
 * Helios Lab — marco del admin (docs/09-HELIOS-LAB.md §6.2). Se abre en otra
 * pestaña desde el menú del super admin. `PlatformGate` deja pasar a quien es
 * del equipo; `MarcoLab` decide qué ve cada rol (el driver, solo la ruta).
 */
export const Route = createFileRoute('/lab')({
  head: () => NO_INDEXAR,
  component: LabLayoutRoute,
})

function LabLayoutRoute() {
  return <PlatformGate>{(admin) => <MarcoLab admin={admin} />}</PlatformGate>
}
