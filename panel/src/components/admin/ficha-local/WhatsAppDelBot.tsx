import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  ConfirmDialog,
  ErrorBox,
  Input,
  NoSePudoLeer,
  SOLO_SUPER_ADMIN,
  Seccion,
  Select,
  SkeletonList,
  formatDateTime,
} from '@/components/ui'
import {
  claveNumerosDelBot,
  consultaNumerosDelBot,
  estadoDelPin,
  registrarNumeroDelBot,
  resetearPinDelBot,
  revocarNumeroDelBot,
  telefonoLegible,
} from '@/features/admin/clinicas/bot'
import type { NumeroDelBot } from '@/features/admin/clinicas/bot'
import { useIsSuperAdmin } from '@/features/admin/role'
import { fetchStaff } from '@/features/merchant/staff'
import { describeError } from '@/lib/supabase'

/**
 * WHATSAPP DEL BOT (docs/00 §15.4, contrato §2.7).
 *
 * El número de WhatsApp con el que cada persona del personal usa el bot del
 * médico. Escribir desde ese número la identifica; el PIN (que crea ella la
 * primera vez) protege lo que crea deuda. Aquí el equipo de Helios:
 *
 *   · registra el número (si la persona ya tenía otro, se revoca: «cambio de
 *     número»);
 *   · ve si ya creó su PIN o si se le bloqueó, y lo resetea;
 *   · revoca un número (teléfono perdido, la persona se fue…).
 *
 * Todo lo exige el servidor a un super admin y queda en la bitácora.
 */
export function WhatsAppDelBot({ merchantId }: { merchantId: string }) {
  const queryClient = useQueryClient()
  const avisar = useToast()
  const isSuperAdmin = useIsSuperAdmin()
  const numeros = useQuery(consultaNumerosDelBot(merchantId))
  const personal = useQuery({ queryKey: ['merchant-staff', merchantId], queryFn: () => fetchStaff(merchantId) })

  const [persona, setPersona] = useState('')
  const [telefono, setTelefono] = useState('')
  const [accion, setAccion] = useState<{ tipo: 'revocar' | 'pin'; numero: NumeroDelBot } | null>(null)

  const refrescar = () => void queryClient.invalidateQueries({ queryKey: claveNumerosDelBot(merchantId) })

  const registrar = useMutation({
    mutationFn: () => registrarNumeroDelBot({ userId: persona, merchantId, phone: telefono }),
    onSuccess: (n) => {
      avisar(`Número registrado para ${n.staffName ?? 'la persona'}`)
      setPersona('')
      setTelefono('')
      refrescar()
    },
  })

  const confirmar = useMutation({
    mutationFn: async (motivo: string) => {
      if (!accion) return
      if (accion.tipo === 'revocar') await revocarNumeroDelBot(accion.numero.id, motivo)
      else await resetearPinDelBot(accion.numero.userId, motivo)
    },
    onSuccess: () => {
      avisar(accion?.tipo === 'revocar' ? 'Número revocado' : 'PIN reseteado: lo creará de nuevo en su próximo mensaje')
      setAccion(null)
      refrescar()
    },
  })

  const activos = (numeros.data ?? []).filter((n) => n.revokedAt === null)
  const revocados = (numeros.data ?? []).filter((n) => n.revokedAt !== null)
  const opciones = (personal.data ?? []).map((s) => ({
    value: s.userId,
    label: `${s.name ?? s.email ?? 'Sin nombre'} · ${s.role === 'gerente' ? 'Administrador' : 'Secretaria'}`,
  }))

  return (
    <Seccion
      titulo="WhatsApp del bot"
      info="El número con el que cada persona usa el bot del médico. Escribir desde ese número la identifica; para registrar un financiamiento le pide su PIN."
    >
      {numeros.isLoading && <SkeletonList rows={2} />}
      {numeros.isError && <NoSePudoLeer onReintentar={() => void numeros.refetch()} />}

      {numeros.data && (
        <div className="flex flex-col gap-4">
          {activos.length === 0 ? (
            <p className="type-panel-body text-on-surface-variant">
              Nadie de esta clínica usa el bot todavía.
            </p>
          ) : (
            <ul className="flex flex-col divide-y divide-outline-variant">
              {activos.map((n) => {
                const pin = estadoDelPin(n)
                return (
                  <li key={n.id} className="flex flex-wrap items-center gap-3 py-3">
                    <div className="min-w-0 flex-1 basis-56">
                      <p className="type-panel-body font-semibold text-on-surface">
                        {n.staffName ?? 'Sin nombre'}
                        {n.role && (
                          <span className="font-normal text-on-surface-variant">
                            {' '}· {n.role === 'gerente' ? 'Administrador' : 'Secretaria'}
                          </span>
                        )}
                      </p>
                      <p className="type-panel-caption text-panel-muted tabular-nums">
                        {telefonoLegible(n.phone)}
                        {n.lastInboundAt
                          ? ` · último mensaje ${formatDateTime(n.lastInboundAt)}`
                          : ' · todavía no ha escrito'}
                      </p>
                    </div>
                    <Badge tone={pin.tone} icono>
                      {pin.texto}
                    </Badge>
                    <Button
                      size="sm"
                      variant="text"
                      disabled={!isSuperAdmin || !n.hasPin}
                      motivoApagado={!isSuperAdmin ? SOLO_SUPER_ADMIN : 'Todavía no ha creado su PIN'}
                      onClick={() => setAccion({ tipo: 'pin', numero: n })}
                    >
                      Resetear PIN
                    </Button>
                    <Button
                      size="sm"
                      variant="text"
                      disabled={!isSuperAdmin}
                      motivoApagado={SOLO_SUPER_ADMIN}
                      onClick={() => setAccion({ tipo: 'revocar', numero: n })}
                    >
                      Revocar
                    </Button>
                  </li>
                )
              })}
            </ul>
          )}

          <form
            className="flex flex-wrap items-end gap-3"
            onSubmit={(e) => {
              e.preventDefault()
              if (persona && telefono.trim() && !registrar.isPending) registrar.mutate()
            }}
          >
            <Select
              id="bot-persona"
              label="Persona"
              value={persona}
              options={opciones}
              onChange={setPersona}
              placeholder="Elige a quién"
              className="min-w-56 flex-1"
            />
            <Input
              id="bot-telefono"
              label="Su WhatsApp"
              value={telefono}
              onChange={setTelefono}
              placeholder="0414-1234567"
              inputMode="tel"
              className="min-w-44"
            />
            <Button
              type="submit"
              size="sm"
              disabled={!isSuperAdmin || !persona || !telefono.trim() || registrar.isPending}
              motivoApagado={!isSuperAdmin ? SOLO_SUPER_ADMIN : undefined}
            >
              {registrar.isPending ? 'Registrando…' : 'Registrar número'}
            </Button>
          </form>
          {registrar.isError && (
            <ErrorBox title="No se registró el número" detail={describeError(registrar.error)} />
          )}

          {revocados.length > 0 && (
            <details>
              <summary className="cursor-pointer type-panel-caption text-panel-muted">
                Números revocados ({revocados.length})
              </summary>
              <ul className="mt-2 flex flex-col gap-1 type-panel-caption text-panel-muted">
                {revocados.map((n) => (
                  <li key={n.id}>
                    {telefonoLegible(n.phone)} · {n.staffName ?? 'Sin nombre'} · revocado{' '}
                    {n.revokedAt ? formatDateTime(n.revokedAt) : ''}
                    {n.revokeReason ? ` (${n.revokeReason})` : ''}
                  </li>
                ))}
              </ul>
            </details>
          )}
        </div>
      )}

      {accion && (
        <ConfirmDialog
          title={accion.tipo === 'revocar' ? '¿Revocar este número?' : '¿Resetear el PIN?'}
          summary={
            accion.tipo === 'revocar'
              ? `${accion.numero.staffName ?? 'Esta persona'} ya no podrá usar el bot desde el ${telefonoLegible(accion.numero.phone)}.`
              : `${accion.numero.staffName ?? 'Esta persona'} tendrá que crear un PIN nuevo en su próximo mensaje al bot.`
          }
          confirmLabel={accion.tipo === 'revocar' ? 'Revocar' : 'Resetear PIN'}
          nivel="sensible"
          reasonLabel="Motivo"
          reasonPlaceholder={accion.tipo === 'revocar' ? 'Perdió el teléfono, ya no trabaja aquí…' : 'Lo olvidó, se bloqueó…'}
          danger={accion.tipo === 'revocar'}
          busy={confirmar.isPending}
          error={confirmar.isError ? describeError(confirmar.error) : undefined}
          onConfirm={(motivo) => confirmar.mutate(motivo)}
          onClose={() => {
            setAccion(null)
            confirmar.reset()
          }}
        />
      )}
    </Seccion>
  )
}
