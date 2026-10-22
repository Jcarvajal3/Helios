import { useQuery } from '@tanstack/react-query'

import { fetchPlatformAdmin } from '@/features/admin/api'
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

/**
 * Si quien mira tiene el rol de la agenda: solo entra a superadmin › Agenda.
 * Las pantallas que comparte con el resto (la Agenda) esconden con esto los
 * enlaces a lo que no puede abrir (el inbox, la ficha de una clínica).
 */
export function useSoloAgenda(): boolean {
  const session = useSession()

  const admin = useQuery({
    queryKey: ['platform-admin', session?.user.id],
    queryFn: fetchPlatformAdmin,
    enabled: !!session,
  })

  return admin.data?.role === 'agenda'
}

/** El texto que explica un botón apagado por falta de permiso. Vive en el
 *  kit (`ui.tsx`) para que `Button motivoApagado` no dependa de la sesión. */
export { SOLO_SUPER_ADMIN } from '@/components/ui'
