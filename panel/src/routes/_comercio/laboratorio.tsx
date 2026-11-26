import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { FlaskConical } from 'lucide-react'

import { Kits } from '@/components/lab/medico/Kits'
import { Muestras } from '@/components/lab/medico/Muestras'
import { Precios } from '@/components/lab/medico/Precios'
import { Registrar } from '@/components/lab/medico/Registrar'
import { EmptyState, SkeletonList, Tabs } from '@/components/ui'
import { canSee } from '@/features/auth/permissions'
import { useStaff } from '@/features/auth/session'
import { accesoLabOptions } from '@/features/lab/medico'
import { comoId, unoDe } from '@/lib/busqueda'

type Pestana = 'precios' | 'registrar' | 'muestras' | 'kits'

const PESTANAS: Array<{ value: Pestana; label: string }> = [
  { value: 'precios', label: 'Precios' },
  { value: 'registrar', label: 'Registrar' },
  { value: 'muestras', label: 'Muestras' },
  { value: 'kits', label: 'Kits' },
]

type LaboratorioSearch = { tab?: Pestana; examen?: string; lab?: string }

export const Route = createFileRoute('/_comercio/laboratorio')({
  staticData: { title: 'Laboratorio' },
  validateSearch: (s: Record<string, unknown>): LaboratorioSearch => ({
    tab: unoDe(
      PESTANAS.map((p) => p.value),
      s.tab,
    ),
    examen: comoId(s.examen),
    lab: comoId(s.lab),
  }),
  component: LaboratorioRoute,
})

function LaboratorioRoute() {
  const staff = useStaff()
  if (!staff) return null
  if (!canSee(staff, 'laboratorio')) return <NoDisponible />
  return <Laboratorio merchantId={staff.merchantId} esAdministrador={staff.role === 'gerente'} />
}

function NoDisponible() {
  return (
    <EmptyState
      icon={<FlaskConical size={28} />}
      title="Laboratorio no está disponible"
      description="Todavía no está activo para tu consultorio. Cuando Helios lo habilite, aparecerá aquí."
    />
  )
}

function Laboratorio({ merchantId, esAdministrador }: { merchantId: string; esAdministrador: boolean }) {
  const navigate = useNavigate({ from: '/laboratorio' })
  const search = Route.useSearch()
  const tab: Pestana = search.tab ?? 'precios'

  // Si la RPC no existe todavía o falla, es lo mismo que «no disponible».
  const acceso = useQuery(accesoLabOptions(merchantId))
  if (acceso.isPending) return <SkeletonList />
  if (!acceso.data?.habilitado) return <NoDisponible />

  const ir = (parcial: LaboratorioSearch) =>
    void navigate({ search: (previo: LaboratorioSearch) => ({ ...previo, ...parcial }), replace: true })

  return (
    <div className="flex flex-col gap-4">
      <Tabs options={PESTANAS} value={tab} onChange={(t) => ir({ tab: t })} className="mb-0" />

      {tab === 'precios' && (
        <Precios
          merchantId={merchantId}
          puedeEditar={esAdministrador}
          onRegistrar={(examen, lab) => ir({ tab: 'registrar', examen, lab })}
        />
      )}
      {tab === 'registrar' && (
        <Registrar
          merchantId={merchantId}
          examenId={search.examen ?? ''}
          laboratorioId={search.lab ?? ''}
          onElegir={(examen, lab) => ir({ examen: examen || undefined, lab: lab || undefined })}
          onVerMuestras={() => ir({ tab: 'muestras', examen: undefined, lab: undefined })}
        />
      )}
      {tab === 'muestras' && <Muestras merchantId={merchantId} />}
      {tab === 'kits' && <Kits merchantId={merchantId} />}
    </div>
  )
}
