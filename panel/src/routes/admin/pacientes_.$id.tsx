import { createFileRoute, useNavigate } from '@tanstack/react-router'

import { PESTANAS_PERSONA, PaginaPersona } from '@/components/admin/ficha-persona'
import type { PestanaPersona } from '@/components/admin/ficha-persona'
import { unoDe } from '@/lib/busqueda'

type PersonaSearch = { tab?: PestanaPersona }

/**
 * La página de una persona.
 *
 * Como página tiene URL —se enlaza desde cualquier sitio, se guarda, se pega
 * en un chat— y la pestaña va en ella: `?tab=identidad` abre la ficha donde
 * están las cuentas relacionadas.
 */
export const Route = createFileRoute('/admin/pacientes_/$id')({
  staticData: { title: 'Paciente', width: 'ficha' },
  component: PersonaPage,
  validateSearch: (search: Record<string, unknown>): PersonaSearch => ({
    tab: unoDe(PESTANAS_PERSONA, search.tab),
  }),
})

function PersonaPage() {
  const { id } = Route.useParams()
  const { tab = 'resumen' } = Route.useSearch()
  const navigate = useNavigate({ from: '/admin/pacientes/$id' })

  return (
    <PaginaPersona
      userId={id}
      tab={tab}
      onTab={(siguiente) =>
        void navigate({
          search: { tab: siguiente === 'resumen' ? undefined : siguiente },
          replace: true,
        })
      }
    />
  )
}
