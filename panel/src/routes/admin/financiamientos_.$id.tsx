import { createFileRoute, useCanGoBack, useNavigate, useRouter } from '@tanstack/react-router'

import { PaginaConsumo } from '@/components/admin/ficha-consumo'

/**
 * La página de un consumo: su factura, sus cuotas y, si fue en grupo, quiénes
 * se la repartieron.
 *
 * Aquí se anula un pendiente y se revierte un confirmado, mirándolo entero.
 * Después de revertir se vuelve a donde se estaba (la ficha de una persona,
 * la lista filtrada), y solo si se entró por un enlace directo, a Consumos.
 */
export const Route = createFileRoute('/admin/financiamientos_/$id')({
  staticData: { title: 'Financiamiento', width: 'ficha' },
  component: ConsumoPage,
})

function ConsumoPage() {
  const { id } = Route.useParams()
  const navigate = useNavigate()
  const router = useRouter()
  const puedeVolver = useCanGoBack()

  return (
    <PaginaConsumo
      chargeId={id}
      onVolver={() => {
        if (puedeVolver) router.history.back()
        else void navigate({ to: '/admin/financiamientos' })
      }}
    />
  )
}
