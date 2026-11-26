import { createFileRoute, useNavigate } from '@tanstack/react-router'

import { ExamenesYPrecios } from '@/components/lab/admin/catalogo/Examenes'
import { Laboratorios } from '@/components/lab/admin/catalogo/Laboratorios'
import { Callout, Tabs } from '@/components/ui'
import { useIsSuperAdmin } from '@/features/admin/role'
import { unoDe } from '@/lib/busqueda'

const TABS = ['laboratorios', 'examenes'] as const
type TabCatalogo = (typeof TABS)[number]

export const Route = createFileRoute('/lab/catalogo')({
  staticData: { title: 'Catálogo', width: 'wide' },
  component: CatalogoPage,
  validateSearch: (s: Record<string, unknown>): { tab?: TabCatalogo } => ({ tab: unoDe(TABS, s.tab) }),
})

function CatalogoPage() {
  const navigate = useNavigate({ from: '/lab/catalogo' })
  const tab: TabCatalogo = Route.useSearch().tab ?? 'laboratorios'
  const esSuper = useIsSuperAdmin()

  return (
    <>
      <Tabs
        options={[
          { value: 'laboratorios', label: 'Laboratorios' },
          { value: 'examenes', label: 'Exámenes y precios' },
        ]}
        value={tab}
        onChange={(v) => void navigate({ search: { tab: v === 'laboratorios' ? undefined : v } })}
      />
      {!esSuper && (
        <Callout tone="info" titulo="Solo lectura" className="mb-4">
          Solo el super admin puede cambiar el catálogo y los precios.
        </Callout>
      )}
      {tab === 'laboratorios' ? <Laboratorios /> : <ExamenesYPrecios />}
    </>
  )
}
