import { useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Landmark } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import {
  EmptyState,
  ErrorBox,
  FilterBar,
  Select,
  SkeletonList,
  formatUsd,
  hoyCaracas,
} from '@/components/ui'
import { FiltroFechas } from '@/components/FiltrosDeLista'
import { columnasDeTransferencias, totalTransferido } from '@/components/admin/caja/columnasTransferencias'
import { fetchMerchantPayouts, fetchMerchants } from '@/features/admin/api'
import { METODOS_DE_PAGO } from '@/features/admin/liquidaciones'
import type { PayoutMethod } from '@/features/admin/liquidaciones'
import { describeError } from '@/lib/supabase'

/** El tope que pide la consulta; la tabla avisa si se alcanza. */
const LIMITE = 200

const COLUMNAS = columnasDeTransferencias({ conLocal: true })

export type FiltrosHistorico = {
  local?: string
  desde?: string
  hasta?: string
  medio?: PayoutMethod
}

/**
 * Todo lo que se les ha transferido a los locales, filtrable por local, por
 * la fecha en que salió del banco y por medio. Los filtros viven en la URL.
 */
export function HistoricoTransferencias({
  filtros,
  onCambiar,
}: {
  filtros: FiltrosHistorico
  onCambiar: (patch: FiltrosHistorico) => void
}) {
  const navigate = useNavigate()

  const merchants = useQuery({ queryKey: ['merchants'], queryFn: fetchMerchants })

  const payouts = useQuery({
    queryKey: ['merchant-payouts', filtros.local, filtros.desde, filtros.hasta, filtros.medio, LIMITE],
    queryFn: () =>
      fetchMerchantPayouts({
        merchantId: filtros.local ?? null,
        from: filtros.desde ?? null,
        to: filtros.hasta ?? null,
        method: filtros.medio ?? null,
        limit: LIMITE,
      }),
  })

  const opcionesLocal = [
    { value: '', label: 'Todas las clínicas' },
    ...(merchants.data ?? []).map((m) => ({
      value: m.id,
      label: m.isTest ? `${m.name} (prueba)` : m.name,
    })),
  ]

  const hayFiltros =
    filtros.local !== undefined ||
    filtros.desde !== undefined ||
    filtros.hasta !== undefined ||
    filtros.medio !== undefined

  return (
    <>
      <FilterBar>
        <Select
          id="filtro-local-pagos"
          label="Clínica"
          value={filtros.local ?? ''}
          options={opcionesLocal}
          onChange={(value) => onCambiar({ local: value || undefined })}
          className="w-56"
        />
        <FiltroFechas
          id="pagos-fechas"
          label="Salió del banco"
          desde={filtros.desde}
          hasta={filtros.hasta}
          max={hoyCaracas()}
          onChange={(rango) => onCambiar(rango)}
        />
        <Select
          id="filtro-medio-pagos"
          label="Medio"
          value={filtros.medio ?? ''}
          options={[{ value: '', label: 'Todos los medios' }, ...METODOS_DE_PAGO]}
          onChange={(value) => onCambiar({ medio: value || undefined })}
          className="w-48"
        />
      </FilterBar>

      {payouts.isPending && <SkeletonList rows={6} />}

      {payouts.isError && (
        <ErrorBox title="No se pudo cargar el histórico" detail={describeError(payouts.error)} />
      )}

      {payouts.data?.length === 0 && (
        <EmptyState
          icon={<Landmark size={40} />}
          title={hayFiltros ? 'Ninguna transferencia con estos filtros' : 'Todavía no se ha registrado ninguna transferencia'}
          description="Cada pago que se registra a una clínica aparece aquí."
        />
      )}

      {payouts.data && payouts.data.length > 0 && (
        <DataTable
          rows={payouts.data}
          rowKey={(p) => p.id}
          columns={COLUMNAS}
          noun={['transferencia', 'transferencias']}
          limit={LIMITE}
          // Sin los locales de prueba: es dinero que salió de verdad.
          summary={`${formatUsd(totalTransferido(payouts.data))} transferidos`}
          exportar={{ archivo: `transferencias-a-locales-${hoyCaracas()}` }}
          onRowClick={(p) =>
            void navigate({ to: '/admin/pagos-clinicas/pago/$id', params: { id: p.id }, search: {} })
          }
        />
      )}
    </>
  )
}
