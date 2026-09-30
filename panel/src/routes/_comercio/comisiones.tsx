import { createFileRoute } from '@tanstack/react-router'
import { Construction } from 'lucide-react'

import { EmptyState } from '@/components/ui'
import { canSee } from '@/features/auth/permissions'
import { useStaff } from '@/features/auth/session'

export const Route = createFileRoute('/_comercio/comisiones')({
  staticData: { title: 'Comisiones', width: 'wide' },
  component: ComisionesPage,
})

/**
 * Comisiones del personal (plan §6): por cada financiamiento confirmado, quien
 * lo registró gana una comisión que Helios paga dentro de la transferencia de
 * los lunes a la clínica.
 *
 * El administrador ve las de todo el personal, por persona y por semana, para
 * repartirlas; la secretaria ve solo las suyas. Ese corte lo hará la RPC en la
 * base, no esta pantalla (igual que las ventas por cajero en Ronda).
 *
 * FASE 2: se construye sobre `staff_commissions` (base: `merchant_sales_by_staff`).
 */
function ComisionesPage() {
  const staff = useStaff()
  if (!staff) return null

  const todas = canSee(staff.role, 'comisiones-de-todos')

  return (
    <EmptyState
      icon={<Construction size={48} />}
      title="Comisiones — en construcción"
      description={
        todas
          ? 'Aquí vas a ver las comisiones de todo el personal, por persona y por semana, pagadas y por pagar.'
          : 'Aquí vas a ver tus comisiones por cada financiamiento que registres, pagadas y por pagar.'
      }
    />
  )
}
