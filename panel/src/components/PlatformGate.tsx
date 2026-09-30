import { useEffect } from 'react'
import type { ReactNode } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { Button, Card, SkeletonScreen } from '@/components/ui'
import { useSession } from '@/features/auth/session'
import { fetchPlatformAdmin  } from '@/features/admin/api'
import type {PlatformAdmin} from '@/features/admin/api';
import { cerrarSesion } from '@/lib/supabase'

/**
 * Envuelve las pantallas de super admin.
 *
 * Igual que StaffGate para los comercios: la guardia real vive en la base
 * (`is_platform_admin()` la comprueban las RLS y cada RPC). Esto solo evita
 * enseñar un panel que fallaría al primer clic.
 */
export function PlatformGate({
  children,
}: {
  children: (admin: PlatformAdmin) => ReactNode
}) {
  const session = useSession()
  const navigate = useNavigate()

  const { data: admin, isLoading } = useQuery({
    queryKey: ['platform-admin', session?.user.id],
    queryFn: fetchPlatformAdmin,
    enabled: !!session,
  })

  useEffect(() => {
    if (session === null) void navigate({ to: '/login' })
  }, [session, navigate])

  if (session === undefined || (session && isLoading)) return <SkeletonScreen />
  if (session === null) return null

  if (!admin) {
    return (
      <div className="mx-auto max-w-md p-6 pt-24">
        <Card>
          <h1 className="type-title-large-emphasized">Esta cuenta no es de Helios</h1>
          <p className="mt-2 text-on-surface-variant">
            Este panel es solo para el equipo de Helios. Si trabajas en una clínica,
            entra por el panel de clínicas.
          </p>
          <div className="mt-6 flex gap-3">
            <Button
              variant="tonal"
              onClick={() => void navigate({ to: '/registrar' })}
            >
              Ir al panel de clínicas
            </Button>
            <Button
              variant="text"
              onClick={() => {
                void cerrarSesion()
              }}
            >
              Salir
            </Button>
          </div>
        </Card>
      </div>
    )
  }

  return <>{children(admin)}</>
}
