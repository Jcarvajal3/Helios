import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { SegundoFactor } from '@/components/admin/SegundoFactor'
import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Callout,
  ConfirmDialog,
  ErrorBox,
  Seccion,
  SkeletonList,
  Table,
  Td,
  Tr,
} from '@/components/ui'
import { fetchSecurityStatus, setRequireMfa } from '@/features/admin/ajustes'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/**
 * El segundo factor: primero el de quien mira y después la exigencia para
 * todo el equipo. Es el orden en que hay que hacerlo: la exigencia no se puede
 * encender hasta que todos lo tengan.
 */
export function Seguridad() {
  return (
    <div className="flex flex-col gap-shell-gap-block">
      <SegundoFactor />
      <ExigirSegundoFactor />
    </div>
  )
}

function ExigirSegundoFactor() {
  const avisar = useToast()
  const queryClient = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()
  const [cambiando, setCambiando] = useState(false)

  const query = useQuery({ queryKey: ['admin-security'], queryFn: fetchSecurityStatus })

  const mutation = useMutation({
    mutationFn: (exigir: boolean) => setRequireMfa(exigir),
    onSuccess: (_data, exigido) => {
      avisar(
        exigido
          ? 'El panel ya exige el segundo factor.'
          : 'El panel vuelve a aceptar sesiones de un solo factor.',
      )
      setCambiando(false)
      void queryClient.invalidateQueries({ queryKey: ['admin-security'] })
    },
  })

  if (query.isPending) return <SkeletonList rows={3} />
  if (query.isError) {
    return <ErrorBox title="No se pudo leer la seguridad" detail={describeError(query.error)} />
  }

  const d = query.data
  const faltan = d.teamTotal - d.teamWithMfa

  const motivoApagado = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : !d.requireMfa && !d.canRequire
      ? `Faltan ${faltan} de ${d.teamTotal} personas por activarlo.`
      : undefined

  return (
    <Seccion
      titulo="Exigir el segundo factor"
      info="Exigido, una sesión de un solo factor no puede hacer nada en el panel: se la trata igual que a alguien ajeno al equipo. Opcional, basta con la contraseña para entrar a un panel que aprueba pagos y registra transferencias."
      controles={
        <>
          <Badge tone={d.requireMfa ? 'success' : 'warning'} icono>
            {d.requireMfa ? 'Exigido' : 'Opcional'}
          </Badge>
          <Button
            size="sm"
            variant={d.requireMfa ? 'tonal' : 'filled'}
            disabled={motivoApagado !== undefined}
            motivoApagado={motivoApagado}
            onClick={() => setCambiando(true)}
          >
            {d.requireMfa ? 'Dejar de exigirlo' : 'Exigirlo'}
          </Button>
        </>
      }
    >
      {/* Escrito y no en el tooltip: encenderlo a destiempo deja gente fuera
          y no se arregla desde dentro. */}
      {!d.requireMfa && faltan > 0 && (
        <Callout tone="warning" titulo={`Faltan ${faltan} de ${d.teamTotal} personas por activarlo`}>
          Encenderlo antes las dejaría fuera del panel, sin forma de arreglarlo desde dentro.
        </Callout>
      )}

      <Table headers={['Persona', 'Correo', 'Rol', 'Segundo factor']}>
        {d.members.map((m) => (
          <Tr key={m.userId}>
            <Td className="font-medium">{m.fullName ?? 'Sin nombre'}</Td>
            <Td className="text-on-surface-variant">{m.email ?? '—'}</Td>
            <Td>
              <Badge>{m.role === 'super_admin' ? 'Super admin' : 'Operador'}</Badge>
            </Td>
            <Td>
              <Badge tone={m.hasMfa ? 'success' : 'warning'} icono>
                {m.hasMfa ? 'Activo' : 'Sin activar'}
              </Badge>
            </Td>
          </Tr>
        ))}
      </Table>

      {cambiando && (
        <ConfirmDialog
          title={d.requireMfa ? 'Dejar de exigir el segundo factor' : 'Exigir el segundo factor'}
          summary={
            d.requireMfa
              ? 'El panel volverá a aceptar sesiones de un solo factor.'
              : `Desde este momento, entrar al panel exigirá el código además de la contraseña. Las ${d.teamTotal} personas del equipo lo tienen activado.`
          }
          detail={
            d.requireMfa ? undefined : (
              <div className="flex flex-col gap-3 type-panel-body text-on-surface-variant">
                <p>Si tu sesión no es de dos factores, el servidor no lo enciende.</p>
                <p>Cada sesión abierta cuenta como de un factor hasta volver a entrar.</p>
              </div>
            )
          }
          confirmLabel={d.requireMfa ? 'Dejar de exigirlo' : 'Exigirlo'}
          danger={d.requireMfa}
          busy={mutation.isPending}
          error={mutation.isError ? describeError(mutation.error) : undefined}
          onConfirm={() => mutation.mutate(!d.requireMfa)}
          onClose={() => setCambiando(false)}
        />
      )}
    </Seccion>
  )
}
