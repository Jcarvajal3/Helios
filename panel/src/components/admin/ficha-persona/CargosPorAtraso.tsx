import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  ConfirmDialog,
  Seccion,
  SkeletonList,
  Table,
  Td,
  Tr,
  formatDay,
  formatUsd,
} from '@/components/ui'
import { fetchUserLateFees, waiveLateFee } from '@/features/admin/lateFees'
import type { LateFee } from '@/features/admin/lateFees'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'

/**
 * Los cargos por atraso que pone el estado automático, y la palanca para
 * quitarlos.
 *
 * Van pegados a las cuotas porque es de donde salen, y porque la pregunta
 * llega junta: «me cobraron dos euros de más» es siempre una cuota concreta
 * que se pagó tarde, o que no. Condonar lo exige el servidor a un super admin.
 */
export function CargosPorAtraso({ userId, onDone }: { userId: string; onDone: () => void }) {
  const queryClient = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()
  const avisar = useToast()
  const [condonando, setCondonando] = useState<LateFee | null>(null)

  const query = useQuery({
    queryKey: ['admin-late-fees', userId],
    queryFn: () => fetchUserLateFees(userId),
  })

  const mutation = useMutation({
    mutationFn: (params: { id: string; reason: string }) => waiveLateFee(params.id, params.reason),
    onSuccess: () => {
      setCondonando(null)
      avisar('Cargo por atraso condonado')
      void queryClient.invalidateQueries({ queryKey: ['admin-late-fees', userId] })
      void queryClient.invalidateQueries({ queryKey: ['admin-overview'] })
      onDone()
    },
  })

  function cerrar() {
    setCondonando(null)
    mutation.reset()
  }

  // Sin cargos, la sección no dice nada que no diga ya la tabla de cuotas.
  // Un fallo, en cambio, sí se dice: «no tiene cargos» sería una afirmación.
  if (query.isSuccess && query.data.length === 0) return null

  const hayPendientes = query.data?.some((f) => f.status === 'pending') ?? false

  return (
    <Seccion
      titulo="Cargos por atraso"
      info="Uno por cada cuota que sigue sin pagarse pasados los días de gracia; lo pone el estado automático. Condonar escribe el asiento contrario y lo exige el servidor a un super admin."
    >
      {query.isPending && <SkeletonList rows={1} />}

      {query.isError && (
        <SeccionSinLeer
          titulo="No se pudieron leer los cargos por atraso"
          error={query.error}
          onReintentar={() => void query.refetch()}
        />
      )}

      {query.isSuccess && (
        <>
          {hayPendientes && !isSuperAdmin && (
            <p className="type-panel-caption text-panel-muted">
              Solo el super admin puede condonar un cargo por atraso.
            </p>
          )}

          <Table headers={['Cuándo', 'Por qué', 'Monto', 'Estado', '']}>
            {query.data.map((f) => (
              <Tr key={f.id}>
                <Td className="whitespace-nowrap">{formatDay(f.businessDate)}</Td>
                <Td className="text-on-surface-variant">
                  {f.sequence
                    ? `Cuota ${f.sequence} · puesto a los ${f.daysLate} ${f.daysLate === 1 ? 'día' : 'días'} de atraso`
                    : `Puesto a los ${f.daysLate} ${f.daysLate === 1 ? 'día' : 'días'} de atraso`}
                  {f.merchantName && (
                    <span className="mt-0.5 block type-panel-caption">{f.merchantName}</span>
                  )}
                </Td>
                <Td className="tabular-nums">{formatUsd(f.amountUsd)}</Td>
                <Td>
                  <EstadoDelCargo cargo={f} />
                </Td>
                <Td>
                  {f.status === 'pending' && (
                    <Button
                      size="sm"
                      variant="text"
                      disabled={!isSuperAdmin}
                      title={isSuperAdmin ? undefined : SOLO_SUPER_ADMIN}
                      onClick={() => setCondonando(f)}
                    >
                      Condonar
                    </Button>
                  )}
                </Td>
              </Tr>
            ))}
          </Table>
        </>
      )}

      {condonando && (
        <ConfirmDialog
          title="Condonar el cargo"
          summary={`Vas a quitar ${formatUsd(condonando.amountUsd)} de cargo por atraso a este paciente.`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              Se escribe el asiento contrario y el original se queda. Baja del bloque de crédito
              para que el cupo vuelva cuando toque, y al paciente le llega el aviso de que su
              deuda bajó.
            </p>
          }
          nivel="sensible"
          reasonLabel="Por qué se condona"
          reasonPlaceholder="Pagó a tiempo y la aprobación del pago tardó tres días"
          confirmLabel={`Condonar ${formatUsd(condonando.amountUsd)}`}
          busy={mutation.isPending}
          error={mutation.isError ? describeError(mutation.error) : undefined}
          onConfirm={(reason) => mutation.mutate({ id: condonando.id, reason })}
          onClose={cerrar}
        />
      )}
    </Seccion>
  )
}

function EstadoDelCargo({ cargo: f }: { cargo: LateFee }) {
  if (f.status === 'paid') {
    return (
      <Badge tone="success" icono>
        Cobrado
      </Badge>
    )
  }

  if (f.waivedAt) {
    return (
      <>
        <Badge tone="neutral">Condonado</Badge>
        {f.waiveReason && (
          <span className="mt-1 block max-w-48 type-panel-caption italic text-on-surface-variant">
            «{f.waiveReason}»
          </span>
        )}
      </>
    )
  }

  if (f.status === 'written_off') {
    return (
      <Badge tone="error" icono>
        Perdido
      </Badge>
    )
  }
  return (
    <Badge tone="warning" icono>
      Pendiente
    </Badge>
  )
}
