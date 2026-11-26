import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { ColaDeCobros, HistorialDeCobros } from '@/components/lab/admin/cobros/Cobros'
import { Tabs } from '@/components/ui'
import { consultaCola } from '@/features/lab/admin'
import { comoEntero, unoDe } from '@/lib/busqueda'

const TABS = ['cola', 'verificados', 'rechazados'] as const
type TabCobros = (typeof TABS)[number]

type CobrosSearch = { tab?: TabCobros; pagina?: number }

export const Route = createFileRoute('/lab/cobros')({
  staticData: { title: 'Cobros', width: 'wide' },
  component: CobrosPage,
  validateSearch: (s: Record<string, unknown>): CobrosSearch => ({
    tab: unoDe(TABS, s.tab),
    pagina: comoEntero(s.pagina, { min: 2, max: 10_000 }),
  }),
})

function CobrosPage() {
  const navigate = useNavigate({ from: '/lab/cobros' })
  const search = Route.useSearch()
  const tab: TabCobros = search.tab ?? 'cola'
  // La misma clave que la cola: no cuesta otra llamada.
  const cola = useQuery(consultaCola())

  return (
    <>
      <Tabs
        options={[
          { value: 'cola', label: 'Por revisar', insignia: cola.data?.length },
          { value: 'verificados', label: 'Verificados' },
          { value: 'rechazados', label: 'Rechazados' },
        ]}
        value={tab}
        onChange={(v) => void navigate({ search: { tab: v === 'cola' ? undefined : v } })}
      />
      {tab === 'cola' && <ColaDeCobros />}
      {tab === 'verificados' && (
        <HistorialDeCobros
          pago="verificado"
          pagina={search.pagina ?? 1}
          onPagina={(p) => void navigate({ search: (s) => ({ ...s, pagina: p <= 1 ? undefined : p }) })}
        />
      )}
      {tab === 'rechazados' && (
        <HistorialDeCobros
          pago="rechazado"
          pagina={search.pagina ?? 1}
          onPagina={(p) => void navigate({ search: (s) => ({ ...s, pagina: p <= 1 ? undefined : p }) })}
        />
      )}
    </>
  )
}
