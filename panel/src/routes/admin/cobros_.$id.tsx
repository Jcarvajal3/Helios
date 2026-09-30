import { createFileRoute } from '@tanstack/react-router'

import { PaginaCobro } from '@/components/admin/FichaCobro'
import { leerFiltrosPagos } from '@/features/admin/colaDePagos'
import type { FiltrosPagos } from '@/features/admin/colaDePagos'
import { comoBooleano } from '@/lib/busqueda'

/**
 * La ficha lleva en su URL los filtros de la lista de la que viene: así
 * «← Pagos reportados» la devuelve tal como estaba, y un enlace a la ficha
 * copiado a medio recorrido sigue sabiendo de qué lista era.
 */
type CobroSearch = FiltrosPagos & { importar?: true }

/**
 * La página de un pago reportado: qué dijo la persona, qué debería haber
 * pagado, si el extracto lo confirma y qué cuotas salda. Y los botones que
 * cierran el asunto.
 */
export const Route = createFileRoute('/admin/cobros_/$id')({
  staticData: { title: 'Pago reportado', width: 'ficha' },
  component: CobroPage,
  validateSearch: (search: Record<string, unknown>): CobroSearch => ({
    ...leerFiltrosPagos(search),
    importar: comoBooleano(search.importar),
  }),
})

function CobroPage() {
  const { id } = Route.useParams()
  const { importar, ...filtros } = Route.useSearch()
  return <PaginaCobro reportId={id} filtros={filtros} importar={importar === true} />
}
