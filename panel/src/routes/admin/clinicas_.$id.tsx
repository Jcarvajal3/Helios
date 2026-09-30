import { createFileRoute, useNavigate } from '@tanstack/react-router'

import { PESTANAS_LOCAL, PaginaLocal, VENTANAS_LOCAL } from '@/components/admin/ficha-local'
import type { PestanaLocal, VentanaLocal } from '@/components/admin/ficha-local'
import { unoDe } from '@/lib/busqueda'

type LocalSearch = { tab?: PestanaLocal; dias?: VentanaLocal }

/** La ventana de lo vendido cuando la URL no dice otra. */
const DIAS_POR_DEFECTO: VentanaLocal = '30'

/**
 * La página de un local. La pestaña y la ventana de las cifras van en la URL:
 * `?tab=condiciones` o `?dias=90` se pueden mandar tal cual.
 */
export const Route = createFileRoute('/admin/clinicas_/$id')({
  staticData: { title: 'Clínica', width: 'ficha' },
  component: LocalPage,
  validateSearch: (search: Record<string, unknown>): LocalSearch => ({
    tab: unoDe(PESTANAS_LOCAL, search.tab),
    dias: unoDe(VENTANAS_LOCAL, search.dias),
  }),
})

function LocalPage() {
  const { id } = Route.useParams()
  const { tab = 'resumen', dias = DIAS_POR_DEFECTO } = Route.useSearch()
  const navigate = useNavigate({ from: '/admin/clinicas/$id' })

  return (
    <PaginaLocal
      merchantId={id}
      tab={tab}
      dias={dias}
      onTab={(siguiente) =>
        void navigate({
          search: (prev) => ({ ...prev, tab: siguiente === 'resumen' ? undefined : siguiente }),
          replace: true,
        })
      }
      onDias={(siguiente) =>
        void navigate({
          search: (prev) => ({ ...prev, dias: siguiente === DIAS_POR_DEFECTO ? undefined : siguiente }),
          replace: true,
        })
      }
    />
  )
}
