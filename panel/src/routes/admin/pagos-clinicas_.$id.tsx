import { createFileRoute } from '@tanstack/react-router'

import { PaginaPagosComercio } from '@/components/admin/PagosComercio'
import { comoDia } from '@/lib/busqueda'

type PagosLocalSearch = {
  /** El cierre del que se viene. Acota la lista a esa semana de caja. */
  cierre?: string
}

/**
 * Lo que se le debe a un local y lo que se le ha pagado.
 *
 * `cierre` viaja en la URL y no en memoria: quien llega aquí desde el cierre
 * del 14 quiere ver ESE cierre, y así el enlace acotado se puede mandar tal
 * cual.
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
