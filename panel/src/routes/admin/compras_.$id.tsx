import { createFileRoute } from '@tanstack/react-router'

import { PaginaFichaCompra } from '@/components/admin/compras/FichaCompra'

export const Route = createFileRoute('/admin/compras_/$id')({
  staticData: { title: 'Solicitud de compra', width: 'ficha' },
  component: CompraDetallePage,
})

function CompraDetallePage() {
  const { id } = Route.useParams()
  return <PaginaFichaCompra requestId={id} />
}
