import { useEffect } from 'react'
import type { ReactNode } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { Button, Card, SkeletonScreen } from '@/components/ui'
import { fetchStaffContext, useSession  } from '@/features/auth/session'
import type {StaffContext} from '@/features/auth/session';
import { cerrarSesion } from '@/lib/supabase'

/**
 * Envuelve las pantallas que exigen ser personal de un comercio.
 *
 * La guardia real está en la base: RLS y `request_charge` comprueban la
 * pertenencia por su cuenta. Esto es solo para no enseñarle a alguien una
 * pantalla que va a fallar al usarla.
 */
export function StaffGate({ children }: { children: (staff: StaffContext) => ReactNode }) {
  const session = useSession()
  const navigate = useNavigate()

  const { data: staff, isLoading } = useQuery({
    queryKey: ['staff', session?.user.id],
    queryFn: () => fetchStaffContext(session!.user.id),
    enabled: !!session,
  })

  useEffect(() => {
    if (session === null) void navigate({ to: '/login' })
  }, [session, navigate])

  if (session === undefined || (session && isLoading)) return <SkeletonScreen />
  if (session === null) return null

  if (!staff) {
    return (
      <div className="mx-auto max-w-md p-6 pt-24">
        <Card>
          <h1 className="type-title-large-emphasized">Esta cuenta no es de una clínica</h1>
          <p className="mt-2 text-on-surface-variant">
            Este panel es solo para clínicas afiliadas. Si eres paciente, escríbele a Helios por WhatsApp.
          </p>
          {/* La puerta de enfrente hace lo mismo al revés. Hace falta porque
              la app instalada abre siempre en `/registrar`: sin esto, el
              equipo de Ronda que la instale aterriza en un cartel cuyo único
              botón es cerrar sesión. */}
          <div className="mt-6 flex gap-3">
            <Button variant="tonal" onClick={() => void navigate({ to: '/admin' })}>
              Ir al panel de Helios
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

  return <>{children(staff)}</>
}
