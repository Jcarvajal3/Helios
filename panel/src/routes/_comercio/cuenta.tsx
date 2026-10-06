import { createFileRoute } from '@tanstack/react-router'
import { UserCircle } from 'lucide-react'

import { Button, Card, SectionTitle } from '@/components/ui'
import { ROLE_LABEL } from '@/features/auth/permissions'
import { useStaff } from '@/features/auth/session'
import { cerrarSesion } from '@/lib/supabase'

export const Route = createFileRoute('/_comercio/cuenta')({
  staticData: { title: 'Cuenta' },
  component: CuentaPage,
})

function CuentaPage() {
  const staff = useStaff()

  if (!staff) return null

  return (
    <>
      <div className="max-w-md">
        <Card>
          <div className="flex items-center gap-4">
            <div className="flex size-12 items-center justify-center rounded-full bg-shell-control">
              <UserCircle size={28} className="text-on-surface-variant" />
            </div>
            <div>
              <p className="font-semibold">{staff.merchantName}</p>
              {/* El RIF y no el nombre de la sucursal: era siempre "Principal"
                  —la base crea una por comercio y no hay segundas— y el RIF es
                  lo que se comprueba. Mismo cambio que en la app. */}
              <p className="type-body-medium text-on-surface-variant">
                {staff.merchantTaxId ?? ''}
              </p>
            </div>
          </div>

          <div className="mt-6 border-t border-outline-variant pt-4">
            <SectionTitle>Tu rol</SectionTitle>
            {/* El rol explica el sidebar. Sin esto, quien no ve Liquidaciones
                no tiene forma de saber si es que no le toca o si está roto. */}
            <p className="mt-1 type-body-medium text-on-surface-variant">
              {ROLE_LABEL[staff.role]} — {ROLE_DESCRIPTION[staff.role]}
            </p>
          </div>

          <div className="mt-6">
            <Button
              variant="tonal"
              size="md"
              onClick={() => void cerrarSesion()}
            >
              Cerrar sesión
            </Button>
          </div>
        </Card>
      </div>
    </>
  )
}

const ROLE_DESCRIPTION = {
  gerente: 'ves toda la clínica: pagos en cuotas, comisiones, métricas, pagos y personal.',
  cajero: 'registras pagos en cuotas y consultas los tuyos y tus comisiones.',
} as const
