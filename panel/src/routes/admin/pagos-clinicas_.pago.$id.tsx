import { createFileRoute } from '@tanstack/react-router'

import { PaginaTransferencia } from '@/components/admin/PaginaTransferencia'
import { unoDe } from '@/lib/busqueda'

/**
 * `origen` dice de dónde se vino, para que «← volver» regrese ahí: desde la
 * página de un local (`local`) o, sin él, desde el histórico de transferencias.
 */
type TransferenciaSearch = { origen?: 'local' }

/**
 * Una transferencia a un local: qué cubrió, con qué papel y quién la registró.
 */
export const Route = createFileRoute('/admin/pagos-clinicas_/pago/$id')({
  staticData: { title: 'Transferencia', width: 'ficha' },
  component: TransferenciaPage,
  validateSearch: (search: Record<string, unknown>): TransferenciaSearch => ({
    origen: unoDe(['local'], search.origen),
  }),
})

function TransferenciaPage() {
  const { id } = Route.useParams()
  const { origen } = Route.useSearch()

  return <PaginaTransferencia payoutId={id} desdeElLocal={origen === 'local'} />
}
