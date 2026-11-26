import { createFileRoute, useNavigate } from '@tanstack/react-router'

import { Ganancia } from '@/components/lab/admin/ganancia/Ganancia'
import { PorPagar } from '@/components/lab/admin/ganancia/PorPagar'
import { hoyCaracas, primeroDelMes } from '@/components/ui'
import { comoDia } from '@/lib/busqueda'

type GananciaSearch = { desde?: string; hasta?: string }

export const Route = createFileRoute('/lab/ganancia')({
  staticData: { title: 'Ganancia', width: 'wide' },
  component: GananciaPage,
  validateSearch: (s: Record<string, unknown>): GananciaSearch => {
    const desde = comoDia(s.desde)
    const hasta = comoDia(s.hasta)
    const ok = desde !== undefined && hasta !== undefined && desde <= hasta
    return { desde: ok ? desde : undefined, hasta: ok ? hasta : undefined }
  },
})

function GananciaPage() {
  const navigate = useNavigate({ from: '/lab/ganancia' })
  const search = Route.useSearch()
  const hoy = hoyCaracas()
  // Sin fechas en la URL, lo que va del mes.
  const rango = { from: search.desde ?? primeroDelMes(hoy), to: search.hasta ?? hoy }

  return (
    <div className="flex flex-col gap-10">
      <Ganancia
        rango={rango}
        onRango={(r) => void navigate({ search: { desde: r.from, hasta: r.to }, replace: true })}
      />
      <PorPagar />
    </div>
  )
}
