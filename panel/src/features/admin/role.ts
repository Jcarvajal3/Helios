import { useQuery } from '@tanstack/react-query'

import { fetchPlatformAdmin } from '@/features/admin/api'
import type { PlatformRole } from '@/features/admin/api'
import { useSession } from '@/features/auth/session'

/**
 * Si quien mira es super admin.
 *
 * Las ocho pestañas las ven los dos roles; lo que cambia es qué botones se
 * pueden pulsar (§2.4 de la especificación: registrar pagos a locales,
 * condonar, revertir, bloquear, cambiar niveles, tocar la configuración).
 *
 * Esto es **solo la pantalla**. La barrera de verdad está en la base: cada
 * RPC comprueba `is_platform_admin()` con el rol. Apagar el botón aquí evita
 * que el operador descubra el límite con un error rojo después de rellenar un
 * formulario entero.
 *
 * Misma clave que `PlatformGate`, así que sale de la caché y no repite la
 * consulta.
 */
export function useIsSuperAdmin(): boolean {
  const session = useSession()

  const admin = useQuery({
    queryKey: ['platform-admin', session?.user.id],
    queryFn: fetchPlatformAdmin,
    enabled: !!session,
  })

  return admin.data?.role === 'super_admin'
}

/** El rol de quien mira, o `null` mientras se lee (o si no es del equipo). */
export function useRolDelEquipo(): PlatformRole | null {
  const session = useSession()

  const admin = useQuery({
    queryKey: ['platform-admin', session?.user.id],
    queryFn: fetchPlatformAdmin,
    enabled: !!session,
  })

  return admin.data?.role ?? null
}

/**
 * Si quien mira es capacitador: entra a la Agenda y a Clínicas, ve el perfil
 * de cada médico sin su dinero y afilia (20261102130100).
 */
export function useEsCapacitador(): boolean {
  return useRolDelEquipo() === 'capacitador'
}

/**
 * Si quien mira puede afiliar médicos: darlos de alta, aprobar o rechazar
 * solicitudes y darle al titular su primer acceso. El super admin y el
 * capacitador (`helios_assert_puede_afiliar`).
 */
export function usePuedeAfiliar(): boolean {
  const rol = useRolDelEquipo()
  return rol === 'super_admin' || rol === 'capacitador'
}

/**
 * Si quien mira puede corregir el perfil de un médico: el titular, los datos
 * del consultorio y el logo. Los mismos que afilian (20261102230000).
 */
export function usePuedeEditarElPerfil(): boolean {
  return usePuedeAfiliar()
}

/** El globo de un botón de guardar el perfil apagado. */
export const SOLO_QUIEN_EDITA_EL_PERFIL = 'Solo un super admin o un capacitador puede editar el perfil del médico'

/** El globo de un botón de afiliar apagado (alta, aprobar, rechazar). */
export const SOLO_QUIEN_AFILIA = 'Solo un super admin o un capacitador puede afiliar médicos'

/** El texto que explica un botón apagado por falta de permiso. Vive en el
 *  kit (`ui.tsx`) para que `Button motivoApagado` no dependa de la sesión. */
export { SOLO_SUPER_ADMIN } from '@/components/ui'
