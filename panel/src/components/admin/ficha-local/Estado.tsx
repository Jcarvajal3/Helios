import { useState } from 'react'
import type { ReactNode } from 'react'
import { useMutation } from '@tanstack/react-query'
import { OctagonX } from 'lucide-react'

import type { HuecoDeMenu } from '@/components/admin/ficha'
import { useToast } from '@/components/Toast'
import { ConfirmDialog, formatUsd } from '@/components/ui'
import type { NivelConfirmacion } from '@/components/ui'
import { setMerchantStatus } from '@/features/admin/api'
import type { MerchantRow } from '@/features/admin/api'
import type { EstadoLocal } from '@/features/admin/estados'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { setTestAccount } from '@/features/admin/testAccounts'
import { describeError } from '@/lib/supabase'

/** Qué le pasó al local, en pasado. El aviso cuenta un hecho, no un estado. */
const ESTADO_VERBO: Record<EstadoLocal, string> = {
  active: 'activado, ya puede cobrar',
  paused: 'pausado, deja de poder cobrar',
  terminated: 'terminado',
}

const DIALOGO: Record<
  EstadoLocal,
  { title: string; confirmLabel: string; placeholder: string; nivel: NivelConfirmacion; word?: string }
> = {
  active: { title: 'Reactivar la clínica', confirmLabel: 'Reactivar', placeholder: 'Vuelve a abrir', nivel: 'sensible' },
  paused: { title: 'Pausar la clínica', confirmLabel: 'Pausar', placeholder: 'Cierra por temporada', nivel: 'sensible' },
  terminated: {
    title: 'Terminar la clínica',
    confirmLabel: 'Terminar',
    placeholder: 'Fin del acuerdo',
    nivel: 'critico',
    word: 'TERMINAR',
  },
}

function resumenDe(nombre: string, destino: EstadoLocal): string {
  if (destino === 'active') {
    return `${nombre} puede volver a registrar financiamientos.`
  }
  if (destino === 'paused') {
    return `${nombre} no puede registrar financiamientos nuevos. Sus cuotas y liquidaciones siguen su curso.`
  }
  return `${nombre} deja de poder registrar financiamientos, como fin del acuerdo. Sus cuotas y liquidaciones siguen su curso, y si hiciera falta se puede reactivar.`
}

/** Lo que la ficha necesita del estado del local: qué abrir, el «⋯» y el diálogo. */
export type EstadoDelLocal = {
  abrir: (destino: EstadoLocal) => void
  marcarPrueba: () => void
  /** Por qué no se puede, si no se puede: sin permiso. */
  sinPermiso: string | undefined
  /** «Terminar» en el «⋯», en rojo y apagado con su motivo si se le debe algo. */
  menu: Array<HuecoDeMenu>
  dialogo: ReactNode
}

/**
 * Pausar, terminar o reactivar el local, y marcarlo de prueba.
 *
 * Es un hook porque los botones viven en dos sitios: pausar, reactivar y la
 * marca de prueba en el carril; terminar, que es el fin del acuerdo, en el
 * «⋯» de la cabecera.
 *
 * Todo lo exige el servidor a un super admin. Terminar exige además que no se
 * le deba nada: el mismo cálculo que enseña «Pendiente de transferir al local» en el carril.
 */
export function useEstadoDelLocal({
  merchant,
  pendingUsd,
  onDone,
}: {
  merchant: MerchantRow
  pendingUsd: number
  onDone: () => void
}): EstadoDelLocal {
  const avisar = useToast()
  const isSuperAdmin = useIsSuperAdmin()
  const [accion, setAccion] = useState<EstadoLocal | null>(null)
  const [prueba, setPrueba] = useState(false)

  const mutation = useMutation({
    mutationFn: (params: { status: EstadoLocal; note: string }) =>
      setMerchantStatus({ merchantId: merchant.id, status: params.status, note: params.note || undefined }),
    onSuccess: (_data, params) => {
      setAccion(null)
      avisar(`${merchant.name}: ${ESTADO_VERBO[params.status]}`)
      onDone()
    },
  })

  const marcarPrueba = useMutation({
    mutationFn: (note: string) =>
      setTestAccount({ kind: 'merchant', id: merchant.id, flag: !merchant.isTest, note }),
    onSuccess: () => {
      setPrueba(false)
      avisar(
        merchant.isTest
          ? `${merchant.name} deja de ser clínica de prueba y vuelve a contar en las cifras`
          : `${merchant.name} pasa a clínica de prueba y deja de contar en las cifras`,
      )
      onDone()
    },
  })

  const sinPermiso = isSuperAdmin ? undefined : SOLO_SUPER_ADMIN
  const motivoTerminar =
    sinPermiso ??
    (pendingUsd > 0 ? `Tiene ${formatUsd(pendingUsd)} pendientes de transferir: págale antes de terminarlo.` : undefined)

  const menu: Array<HuecoDeMenu> = [
    merchant.status !== 'terminated' && {
      label: 'Terminar la clínica',
      icon: OctagonX,
      peligro: true,
      disabled: !!motivoTerminar,
      motivoApagado: motivoTerminar,
      onSelect: () => setAccion('terminated'),
    },
  ]

  let dialogo: ReactNode = null

  if (accion) {
    dialogo = (
      <ConfirmDialog
        title={DIALOGO[accion].title}
        summary={resumenDe(merchant.name, accion)}
        nivel={DIALOGO[accion].nivel}
        confirmWord={DIALOGO[accion].word}
        reasonPlaceholder={DIALOGO[accion].placeholder}
        confirmLabel={DIALOGO[accion].confirmLabel}
        busy={mutation.isPending}
        error={mutation.isError ? describeError(mutation.error) : undefined}
        onConfirm={(note) => mutation.mutate({ status: accion, note })}
        onClose={() => {
          setAccion(null)
          mutation.reset()
        }}
      />
    )
  }

  if (prueba) {
    dialogo = (
      <ConfirmDialog
        title={merchant.isTest ? 'Quitar la marca de prueba' : 'Marcar como clínica de prueba'}
        summary={
          merchant.isTest
            ? `${merchant.name} vuelve a contar en el volumen, en el cierre del lunes y en los rankings. Lo que se vendió mientras estaba marcado vuelve a sumar.`
            : `${merchant.name} deja de contar en el volumen, en el cierre del lunes, en la mora y en los rankings. Lo que ya se vendió deja de sumar también.`
        }
        detail={
          <p className="type-panel-body text-on-surface-variant">
            Sus financiamientos se siguen escribiendo en el libro, marcados como prueba: una prueba deja
            rastro, pero no entra en la contabilidad.
          </p>
        }
        nivel="sensible"
        reasonPlaceholder="Clínica de demostración para enseñar el panel"
        confirmLabel={merchant.isTest ? 'Quitar la marca' : 'Marcar como prueba'}
        busy={marcarPrueba.isPending}
        error={marcarPrueba.isError ? describeError(marcarPrueba.error) : undefined}
        onConfirm={(note) => marcarPrueba.mutate(note)}
        onClose={() => {
          setPrueba(false)
          marcarPrueba.reset()
        }}
      />
    )
  }

  return {
    abrir: (destino) => {
      if (isSuperAdmin) setAccion(destino)
    },
    marcarPrueba: () => {
      if (isSuperAdmin) setPrueba(true)
    },
    sinPermiso,
    menu,
    dialogo,
  }
}
