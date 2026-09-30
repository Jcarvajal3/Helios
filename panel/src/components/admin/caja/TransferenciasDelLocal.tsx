import { useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Landmark } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import { EmptyState, Seccion, SkeletonList, formatUsd } from '@/components/ui'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { columnasDeTransferencias, totalTransferido } from '@/components/admin/caja/columnasTransferencias'
import { fetchMerchantPayouts } from '@/features/admin/api'

/** El tope que pide la consulta; la tabla avisa si se alcanza. */
const LIMITE = 200

const COLUMNAS = columnasDeTransferencias({ conLocal: false })

/**
 * Lo que se le ha transferido a un local, de lo último a lo primero. Cada fila
 * abre la transferencia, con lo que cubrió; al volver de ella se vuelve aquí.
 */
export function TransferenciasDelLocal({
  merchantId,
  merchantName,
}: {
  merchantId: string
  merchantName: string
}) {
  const navigate = useNavigate()

  const payouts = useQuery({
    queryKey: ['merchant-payouts', merchantId, LIMITE],
    queryFn: () => fetchMerchantPayouts({ merchantId, limit: LIMITE }),
  })

  return (
    <Seccion titulo="Transferencias hechas" info="Lo que se le ha transferido, de lo último a lo primero. Cada fila abre la transferencia con lo que cubrió.">
      {payouts.isPending && <SkeletonList rows={3} />}

      {payouts.isError && (
        <SeccionSinLeer
          titulo="No se pudo cargar el histórico"
          error={payouts.error}
          onReintentar={() => void payouts.refetch()}
        />
      )}

      {payouts.data?.length === 0 && (
        <EmptyState
          icon={<Landmark size={40} />}
          title="Todavía no se le ha transferido nada"
          description="Cada pago que se registre aquí aparece en esta lista."
        />
      )}

      {payouts.data && payouts.data.length > 0 && (
        <DataTable
          rows={payouts.data}
          rowKey={(p) => p.id}
          columns={COLUMNAS}
          noun={['transferencia', 'transferencias']}
          limit={LIMITE}
          summary={`${formatUsd(totalTransferido(payouts.data))} transferidos`}
          exportar={{ archivo: `transferencias-${merchantName}` }}
          onRowClick={(p) =>
            void navigate({
              to: '/admin/pagos-clinicas/pago/$id',
              params: { id: p.id },
              search: { origen: 'local' },
            })
          }
        />
      )}
    </Seccion>
  )
}
