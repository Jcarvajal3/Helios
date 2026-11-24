import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { AjustesCompras } from '@/components/admin/compras/AjustesCompras'
import { ColaPagosCompras } from '@/components/admin/compras/ColaPagosCompras'
import { ListaDeCompras } from '@/components/admin/compras/ListaDeCompras'
import { SimuladorWhatsAppCompras } from '@/components/admin/compras/SimuladorWhatsAppCompras'
import { Tabs } from '@/components/ui'
import { consultaConteosCompras } from '@/features/admin/compras/consultas'
import { VALORES_CANAL_COMPRA, VALORES_ESTADO_SOLICITUD } from '@/features/admin/compras/estados'
import type { CanalCompra, EstadoSolicitudCompra } from '@/features/admin/compras/tipos'
import { comoTexto, unoDe } from '@/lib/busqueda'

const TABS_COMPRAS = ['solicitudes', 'pagos', 'simulador', 'ajustes'] as const
type TabCompras = (typeof TABS_COMPRAS)[number]

type ComprasSearch = {
  tab?: TabCompras
  q?: string
  estado?: EstadoSolicitudCompra
  canal?: CanalCompra
}

export const Route = createFileRoute('/admin/compras')({
  staticData: { title: 'Compras Amazon', width: 'wide' },
  component: ComprasPage,
  validateSearch: (search: Record<string, unknown>): ComprasSearch => ({
    tab: unoDe(TABS_COMPRAS, search.tab),
    q: comoTexto(search.q),
    estado: unoDe(VALORES_ESTADO_SOLICITUD, search.estado),
    canal: unoDe(VALORES_CANAL_COMPRA, search.canal),
  }),
})

function ComprasPage() {
  const navigate = useNavigate({ from: '/admin/compras' })
  const search = Route.useSearch()
  const tab: TabCompras = search.tab ?? 'solicitudes'
  const conteos = useQuery(consultaConteosCompras())

  function cambiar(patch: Partial<ComprasSearch>, reemplazar = false) {
    void navigate({ search: (prev) => ({ ...prev, ...patch }), replace: reemplazar })
  }

  return (
    <>
      <Tabs
        options={[
          {
            value: 'solicitudes',
            label: 'Solicitudes',
            insignia: conteos.data?.revisionAduanal,
          },
          {
            value: 'pagos',
            label: 'Pagos por aprobar',
            insignia: conteos.data?.pagosPendientes,
          },
          {
            value: 'simulador',
            label: 'Simulador WhatsApp',
          },
          {
            value: 'ajustes',
            label: 'Ajustes y tarifas',
          },
        ]}
        value={tab}
        onChange={(v) => cambiar({ tab: v === 'solicitudes' ? undefined : v })}
      />

      {tab === 'solicitudes' && (
        <ListaDeCompras
          filtros={{ q: search.q, estado: search.estado, canal: search.canal }}
          onCambiar={(patch, reemplazar) => cambiar(patch, reemplazar)}
        />
      )}

      {tab === 'pagos' && <ColaPagosCompras />}

      {tab === 'simulador' && <SimuladorWhatsAppCompras />}

      {tab === 'ajustes' && <AjustesCompras />}
    </>
  )
}
