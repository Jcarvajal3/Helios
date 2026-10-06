import { useState } from 'react'
import type { ReactNode } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import {
  Button,
  Callout,
  ConfirmDialog,
  Seccion,
  Textarea,
  formatDateTime,
} from '@/components/ui'
import { useToast } from '@/components/Toast'
import type { EstadoDelBloqueo } from '@/components/admin/ficha-persona/accionesDeCuenta'
import { useIsSuperAdmin } from '@/features/admin/role'
import { blockUser, fetchUserBlocks, unblockUser } from '@/features/admin/users'
import type { UserBlock } from '@/features/admin/users'
import { describeError } from '@/lib/supabase'

/** Lo mínimo que exige el servidor para el mensaje que lee la persona. */
const MENSAJE_MINIMO = 10

/** Lo que la ficha sabe del bloqueo manual y cómo abrir sus diálogos. */
export type BloqueoDeCuenta = {
  estado: EstadoDelBloqueo
  /** El bloqueo abierto, si lo hay. */
  abierto: UserBlock | null
  anteriores: Array<UserBlock>
  reintentar: () => void
  bloquear: () => void
  levantar: () => void
  /** El diálogo abierto, para montarlo donde se quiera. */
  dialogo: ReactNode
}

/**
 * Bloquear la cuenta: el freno manual y permanente.
 *
 * No toca `profiles.status`: el estado lo gobierna el estado automático, que
 * cada mañana devuelve a activa a quien no tiene una cuota vencida, así que un
 * castigo puesto ahí se deshacía solo. Este vive aparte y solo lo levanta una
 * persona (migración 20260909160000).
 *
 * Es un hook porque el bloqueo se ve en tres sitios: la insignia de la
 * cabecera, «Bloquear la cuenta» en el «⋯» y «Levantar el bloqueo» en el
 * carril. Bloquear y levantar los exige el servidor a un super admin
 * (`helios_assert_super_admin`); quien lo monta apaga los botones con el
 * motivo.
 *
 * Dos textos, los dos obligatorios: el motivo va a la bitácora y el mensaje se
 * le enseña a la persona en Inicio y le llega como aviso.
 */
export function useBloqueoDeCuenta(userId: string): BloqueoDeCuenta {
  const client = useQueryClient()
  const avisar = useToast()
  const isSuperAdmin = useIsSuperAdmin()
  const [dialogo, setDialogo] = useState<'bloquear' | 'levantar' | null>(null)
  const [mensaje, setMensaje] = useState('')

  // Cuelga de la ficha: al refrescar la persona se refresca también esto.
  const blocks = useQuery({
    queryKey: ['admin-user', userId, 'bloqueos'],
    queryFn: () => fetchUserBlocks(userId),
  })

  function cerrar() {
    setDialogo(null)
    setMensaje('')
    block.reset()
    unblock.reset()
  }

  function refrescar() {
    void client.invalidateQueries({ queryKey: ['admin-user', userId] })
    void client.invalidateQueries({ queryKey: ['admin-users'] })
    void client.invalidateQueries({ queryKey: ['admin-audit'] })
  }

  const block = useMutation({
    mutationFn: (reason: string) => blockUser({ userId, reason, message: mensaje }),
    onSuccess: () => {
      cerrar()
      avisar('Cuenta bloqueada: el estado automático ya no la reactiva por la mañana')
      refrescar()
    },
  })

  const unblock = useMutation({
    mutationFn: (note: string) => unblockUser({ userId, note }),
    onSuccess: () => {
      cerrar()
      avisar('Bloqueo levantado: la cuenta vuelve a lo que diga el estado automático')
      refrescar()
    },
  })

  const abierto = blocks.data?.find((b) => !b.liftedAt) ?? null
  const estado: EstadoDelBloqueo = blocks.isError
    ? 'error'
    : blocks.isPending
      ? 'cargando'
      : abierto
        ? 'abierto'
        : 'sin_bloqueo'

  // Un diálogo abierto sin permiso no se podría confirmar: el servidor lo
  // rechazaría después de escribir el mensaje entero.
  function abrir(cual: 'bloquear' | 'levantar') {
    if (isSuperAdmin) setDialogo(cual)
  }

  return {
    estado,
    abierto,
    anteriores: blocks.data?.filter((b) => b.liftedAt) ?? [],
    reintentar: () => void blocks.refetch(),
    bloquear: () => abrir('bloquear'),
    levantar: () => abrir('levantar'),
    dialogo:
      dialogo === 'bloquear' ? (
        <ConfirmDialog
          title="Bloquear la cuenta"
          summary="No podrá pagar en cuotas en ninguna clínica hasta que alguien levante el bloqueo. Puede seguir pagando sus cuotas."
          detail={
            <Textarea
              id="bloqueo-mensaje"
              label="Lo que verá el paciente"
              value={mensaje}
              onChange={setMensaje}
              rows={3}
              placeholder="Detectamos un problema con tu cuenta. Escríbenos a soporte para resolverlo."
              hint="Se le enseña en Inicio y le llega como aviso: dile qué hacer para resolverlo."
            />
          }
          nivel="sensible"
          reasonLabel="Motivo interno (va a la bitácora)"
          reasonPlaceholder="Reporte de suplantación del 09/09"
          bloqueo={
            mensaje.trim().length < MENSAJE_MINIMO
              ? `Escribe lo que verá el paciente, con al menos ${MENSAJE_MINIMO} caracteres.`
              : undefined
          }
          confirmLabel="Bloquear la cuenta"
          danger
          busy={block.isPending}
          error={block.isError ? describeError(block.error) : undefined}
          onConfirm={(reason) => block.mutate(reason)}
          onClose={cerrar}
        />
      ) : dialogo === 'levantar' ? (
        <ConfirmDialog
          title="Levantar el bloqueo"
          summary="La cuenta vuelve a lo que diga el estado automático, y al paciente le llega un aviso de que puede volver a usar Helios."
          nivel="sensible"
          reasonLabel="Motivo para levantarlo"
          reasonPlaceholder="Aclarado con el paciente por WhatsApp"
          confirmLabel="Levantar el bloqueo"
          busy={unblock.isPending}
          error={unblock.isError ? describeError(unblock.error) : undefined}
          onConfirm={(note) => unblock.mutate(note)}
          onClose={cerrar}
        />
      ) : null,
  }
}

/**
 * El bloqueo, dicho en la ficha: el abierto como aviso rojo con su motivo y lo
 * que ve la persona, y los anteriores debajo. Sin bloqueos, nada: el estado
 * «sin bloqueo» ya lo dice la cabecera al no llevar la insignia.
 */
export function BloqueoDeLaCuenta({ bloqueo }: { bloqueo: BloqueoDeCuenta }) {
  if (bloqueo.estado === 'error') {
    return (
      <Callout
        tone="warning"
        titulo="No se sabe si la cuenta tiene un bloqueo abierto"
        accion={
          <Button variant="tonal" size="sm" onClick={bloqueo.reintentar}>
            Reintentar
          </Button>
        }
      />
    )
  }

  if (!bloqueo.abierto && bloqueo.anteriores.length === 0) return null

  return (
    <>
      {bloqueo.abierto && <BloqueoAbierto bloqueo={bloqueo.abierto} />}

      {bloqueo.anteriores.length > 0 && (
        <Seccion titulo="Bloqueos anteriores">
          <ul className="flex flex-col gap-2">
            {bloqueo.anteriores.map((b) => (
              <li key={b.id} className="type-panel-body text-on-surface-variant">
                Bloqueada el {formatDateTime(b.blockedAt)} por «{b.reason}». Levantado el{' '}
                {formatDateTime(b.liftedAt)}
                {b.liftedByName ? ` por ${b.liftedByName}` : ''}
                {b.liftNote ? `: ${b.liftNote}` : ''}.
              </li>
            ))}
          </ul>
        </Seccion>
      )}
    </>
  )
}

function BloqueoAbierto({ bloqueo }: { bloqueo: UserBlock }) {
  return (
    <Callout
      tone="error"
      titulo="Cuenta bloqueada"
      detalles={
        <dl className="flex flex-col gap-2">
          <div>
            <dt className="type-panel-label text-on-surface-variant">Lo que ve el paciente</dt>
            <dd className="mt-0.5 text-on-surface">{bloqueo.message}</dd>
          </div>
        </dl>
      }
    >
      «{bloqueo.reason}» · desde el {formatDateTime(bloqueo.blockedAt)}
      {bloqueo.blockedByName ? `, por ${bloqueo.blockedByName}` : ''}.
    </Callout>
  )
}
