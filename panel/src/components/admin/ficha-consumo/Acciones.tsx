import { useState } from 'react'
import type { ReactNode } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Ban, Undo2 } from 'lucide-react'

import type { HuecoDeMenu } from '@/components/admin/ficha'
import { DialogoAnularConsumo } from '@/components/admin/directorio/AnularConsumo'
import { useToast } from '@/components/Toast'
import { Button, Callout, ConfirmDialog, formatUsd } from '@/components/ui'
import { canReverseCharge, reverseCharge } from '@/features/admin/consumos'
import type { ChargeDetail } from '@/features/admin/consumos'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/**
 * Lo que se le puede hacer a un consumo desde su ficha, según su estado: un
 * pendiente se anula y un confirmado se revierte. Los demás ya no admiten
 * nada.
 *
 * Las dos son destructivas y van en el «⋯» de la cabecera, en rojo y con su
 * confirmación de siempre. Cuando el servidor dice que no se puede revertir,
 * el ítem sale apagado con su frase: el motivo se lee sin intentarlo.
 */
export function useAccionesDelConsumo(
  detail: ChargeDetail,
  onRevertido: () => void,
): { menu: Array<HuecoDeMenu>; dialogo: ReactNode; aviso: ReactNode } {
  const queryClient = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()
  const avisar = useToast()
  const [abierto, setAbierto] = useState<'anular' | 'revertir' | null>(null)
  const confirmado = detail.status === 'confirmed'

  const puede = useQuery({
    queryKey: ['can-reverse', detail.chargeId],
    queryFn: () => canReverseCharge(detail.chargeId),
    enabled: confirmado,
  })

  const revertir = useMutation({
    mutationFn: (reason: string) => reverseCharge(detail.chargeId, reason),
    onSuccess: () => {
      setAbierto(null)
      avisar(`Revertido: ${formatUsd(detail.financedUsd)} (sin comisión) en ${detail.merchant.name}. Las cuotas se borraron y el cupo volvió`)
      for (const clave of [
        ['admin-charges'],
        ['charge-detail', detail.chargeId],
        ['can-reverse', detail.chargeId],
        // Las fichas de todas las personas del reparto, no solo la de quien
        // puso el consumo: a todas se les borraron cuotas.
        ['admin-user'],
        ['admin-users'],
        ['admin-late-fees'],
        ['admin-overview'],
        ['admin-cash'],
        ['merchant-payables'],
      ]) {
        void queryClient.invalidateQueries({ queryKey: clave })
      }
      onRevertido()
    },
  })

  // La frase viene entera del servidor («No se puede revertir: al local ya se
  // le transfirió su parte.»), la misma con la que se negaría al revertir.
  const motivoRevertir = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : puede.isPending
      ? 'Comprobando si se puede revertir…'
      : puede.isError
        ? 'No se pudo comprobar si se puede revertir.'
        : !puede.data.canReverse
          ? (puede.data.reason ?? 'No se puede revertir: el servidor no lo permite.')
          : undefined

  const menu: Array<HuecoDeMenu> = [
    detail.status === 'pending' && {
      label: 'Anular el cobro',
      icon: Ban,
      peligro: true,
      onSelect: () => setAbierto('anular'),
    },
    confirmado && {
      label: 'Revertir el financiamiento',
      icon: Undo2,
      peligro: true,
      disabled: !!motivoRevertir,
      motivoApagado: motivoRevertir,
      onSelect: () => setAbierto('revertir'),
    },
  ]

  let dialogo: ReactNode = null

  if (abierto === 'anular') {
    dialogo = (
      <DialogoAnularConsumo
        chargeId={detail.chargeId}
        financedUsd={detail.financedUsd}
        merchantName={detail.merchant.name}
        onClose={() => setAbierto(null)}
      />
    )
  }

  // Revierte el CARGO ENTERO. Es irreversible y toca dinero, así que pide el
  // motivo y la palabra (`critico`).
  if (abierto === 'revertir') {
    dialogo = (
      <ConfirmDialog
        title="Revertir el financiamiento"
        summary={`Vas a deshacer un financiamiento de ${formatUsd(detail.financedUsd)} (sin comisión) en ${detail.merchant.name}.`}
        detail={
          <p className="type-panel-body text-on-surface-variant">
            Se escribe el asiento contrario y el original se queda en el libro. Se borran sus{' '}
            {detail.installments.length} {detail.installments.length === 1 ? 'cuota' : 'cuotas'},
            se cancela lo que la clínica todavía no haya cobrado de este financiamiento, vuelve el cupo y
            le llega un aviso con el motivo que escribas.
          </p>
        }
        nivel="critico"
        confirmWord="REVERTIR"
        reasonLabel="Por qué (lo ve el paciente)"
        reasonPlaceholder="El mesonero tecleó $500 en vez de $50"
        confirmLabel="Revertir el financiamiento"
        busy={revertir.isPending}
        error={revertir.isError ? describeError(revertir.error) : undefined}
        onConfirm={(reason) => revertir.mutate(reason)}
        onClose={() => {
          setAbierto(null)
          revertir.reset()
        }}
      />
    )
  }

  // Sin saber si se puede, el ítem sale apagado; esto deja reintentar.
  const aviso =
    confirmado && puede.isError ? (
      <Callout
        tone="warning"
        titulo="No se pudo comprobar si se puede revertir"
        accion={
          <Button size="sm" variant="tonal" onClick={() => void puede.refetch()}>
            Reintentar
          </Button>
        }
      />
    ) : null

  return { menu, dialogo, aviso }
}
