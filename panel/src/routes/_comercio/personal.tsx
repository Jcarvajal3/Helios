import { createFileRoute } from '@tanstack/react-router'
import { Lock } from 'lucide-react'

import { PersonalDelLocal } from '@/components/PersonalDelLocal'
import { EmptyState } from '@/components/ui'
import { canSee } from '@/features/auth/permissions'
import { useStaff } from '@/features/auth/session'

export const Route = createFileRoute('/_comercio/personal')({
  staticData: { title: 'Personal', width: 'wide' },
  component: PersonalRoute,
})

/**
 * Quién entra al panel de este local.
 *
 * Solo el **gerente**. Es el único rol que contrata, y es el único al que
 * darle esto no abre una puerta: un cajero que pudiera gestionar personal
 * podría ascenderse a gerente él solo, y entonces el rol no separaría nada.
 *
 * La guardia de verdad está en la base —`can_manage_merchant_staff`, que
 * comprueba que seas gerente ACTIVO de ese comercio— y no aquí. Esto solo
 * evita enseñar una pantalla que fallaría al usarse.
 */
function PersonalRoute() {
  const staff = useStaff()

  if (!staff) return null

  if (!canSee(staff, 'personal')) {
    return (
      <EmptyState
        icon={<Lock size={48} />}
        title="Esto lo lleva el administrador"
        description="Quién puede entrar al panel de la clínica y con qué rol lo decide el administrador. Si necesitas un cambio, pídeselo."
      />
    )
  }

  return <PersonalDelLocal merchantId={staff.merchantId} />
}
