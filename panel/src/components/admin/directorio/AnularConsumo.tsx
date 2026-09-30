import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import { Button, ConfirmDialog, formatUsd } from '@/components/ui'
import { voidCharge } from '@/features/admin/ops'
import { describeError } from '@/lib/supabase'

type Consumo = {
  chargeId: string
  /** El consumo sin el service fee: es lo que el local tecleó. */
  financedUsd: number
  merchantName: string
}

/**
 * Anular un cobro pendiente: un QR que el local generó y nadie ha confirmado.
 *
 * Lo usan la fila de la lista y la ficha del consumo, con el mismo diálogo.
 * No mueve dinero, pero borra un cobro que alguien del local generó, así que
 * pide el motivo (`sensible`). Cualquier admin puede hacerlo.
 */
export function AnularConsumo({
  chargeId,
  financedUsd,
  merchantName,
  size = 'sm',
  variant = 'text',
  onDone,
}: Consumo & {
  size?: 'sm' | 'md'
  variant?: 'text' | 'tonal' | 'danger'
  onDone?: () => void
}) {
  const [abierto, setAbierto] = useState(false)

  return (
    <>
      <Button
        size={size}
        variant={variant}
        onClick={(e) => {
          e.stopPropagation()
          setAbierto(true)
        }}
      >
        Anular
      </Button>

      {abierto && (
        <DialogoAnularConsumo
          chargeId={chargeId}
          financedUsd={financedUsd}
          merchantName={merchantName}
          onDone={onDone}
          onClose={() => setAbierto(false)}
        />
      )}
    </>
  )
}

/**
 * El diálogo de anular, sin su botón: la ficha del consumo lo abre desde su
 * menú «⋯».
 */
export function DialogoAnularConsumo({
  chargeId,
  financedUsd,
  merchantName,
  onDone,
  onClose,
}: Consumo & { onDone?: () => void; onClose: () => void }) {
  const client = useQueryClient()
  const avisar = useToast()

  const mutation = useMutation({
    mutationFn: (reason: string) => voidCharge(chargeId, reason),
    onSuccess: () => {
      onClose()
      avisar(`Anulado: ${formatUsd(financedUsd)} (sin fee) en ${merchantName}`)
      void client.invalidateQueries({ queryKey: ['admin-charges'] })
      void client.invalidateQueries({ queryKey: ['charge-detail', chargeId] })
      // Un pendiente puede salir ya en la ficha de quien lo iba a pagar.
      void client.invalidateQueries({ queryKey: ['admin-user'] })
      onDone?.()
    },
  })

  // La ventana no usa portal: puede vivir dentro de la fila de la tabla, y un
  // clic en su texto subiría hasta la fila y abriría la ficha.
  return (
    <span className="contents" onClick={(e) => e.stopPropagation()}>
      <ConfirmDialog
        title="Anular el cobro"
        summary={`Vas a anular un cobro pendiente de ${formatUsd(financedUsd)} (sin fee) en ${merchantName}. No mueve dinero: nadie lo ha confirmado.`}
        nivel="sensible"
        reasonPlaceholder="El mesonero se equivocó de mesa"
        confirmLabel="Anular el cobro"
        danger
        busy={mutation.isPending}
        error={mutation.isError ? describeError(mutation.error) : undefined}
        onConfirm={(reason) => mutation.mutate(reason)}
        onClose={() => {
          mutation.reset()
          onClose()
        }}
      />
    </span>
  )
}
