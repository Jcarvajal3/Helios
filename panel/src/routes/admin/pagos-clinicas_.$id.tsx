import { createFileRoute } from '@tanstack/react-router'

import { PaginaPagosComercio } from '@/components/admin/PagosComercio'
import { comoDia } from '@/lib/busqueda'

type PagosLocalSearch = {
  /** El día de pago del que se viene. Acota la lista a ese día. */
  cierre?: string
}

/**
 * Lo que se le debe a un local y lo que se le ha pagado.
 *
 * `cierre` (el día de pago) viaja en la URL y no en memoria: quien llega aquí
 * desde el pago del 14 quiere ver ESE día, y así el enlace acotado se puede
 * mandar tal cual.
 */
export const Route = createFileRoute('/admin/pagos-clinicas_/$id')({
  staticData: { title: 'Pagos a la clínica', width: 'ficha' },
  component: PagosComercioPage,
  validateSearch: (search: Record<string, unknown>): PagosLocalSearch => ({
    cierre: comoDia(search.cierre),
  }),
})

function PagosComercioPage() {
  const { id } = Route.useParams()
  const { cierre } = Route.useSearch()

  return <PaginaPagosComercio merchantId={id} cierre={cierre ?? null} />
}
