import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import {
  Button,
  Callout,
  Checkbox,
  ConfirmDialog,
  ErrorBox,
  SectionTitle,
  SkeletonList,
  formatDay,
  formatUsd,
  formatVes,
} from '@/components/ui'
import {
  TOLERANCIA_EUR,
  cargosQueViajan,
  cuotasPendientes,
  cuotasPorConsumo,
  montoDeLaSeleccion,
  repartirCargos,
  sugerirCuotas,
} from '@/features/admin/asignarAbono'
import { assignDeposit } from '@/features/admin/deposits'
import type { UnmatchedDeposit } from '@/features/admin/deposits'
import { fetchUserLateFees } from '@/features/admin/lateFees'
import { fetchUserDetail } from '@/features/admin/users'
import type { UserRow } from '@/features/admin/users'
import { describeError } from '@/lib/supabase'

/**
 * El segundo paso de asignar un abono: qué cuotas salda.
 *
 * Llega con las cuotas que cuadran con el monto ya marcadas, de la más
 * antigua a la más nueva, que es lo que paga casi todo el mundo. Si lo
 * marcado no cuadra, el aviso cuenta los cargos por atraso que el servidor va
 * a cobrar con esas cuotas y los enseña: sin ellos, un abono correcto parece
 * de la persona equivocada.
 */
export function CuotasDelAbono({
  deposit,
  persona,
  onCambiarPersona,
  onHecho,
}: {
  deposit: UnmatchedDeposit
  persona: UserRow
  onCambiarPersona: () => void
  onHecho: (aviso: string) => void
}) {
  const queryClient = useQueryClient()
  const [tocado, setTocado] = useState<Set<string> | null>(null)
  const [confirmando, setConfirmando] = useState(false)

  const detalle = useQuery({
    queryKey: ['admin-user', persona.userId],
    queryFn: () => fetchUserDetail(persona.userId),
  })

  // Misma clave que la ficha de la persona, que también los enseña.
  const cargos = useQuery({
    queryKey: ['admin-late-fees', persona.userId],
    queryFn: () => fetchUserLateFees(persona.userId),
  })

  const todas = useMemo(() => detalle.data?.installments ?? [], [detalle.data])
  const pendientes = useMemo(() => cuotasPendientes(todas), [todas])
  const deN = useMemo(() => cuotasPorConsumo(todas), [todas])
  const reparto = useMemo(
    () => repartirCargos(pendientes, cargos.data ?? []),
    [pendientes, cargos.data],
  )

  // La sugerencia solo con los cargos leídos: sin ellos, la suma no es la
  // que va a hacer el servidor y se marcarían cuotas de más.
  const sugerencia = useMemo(
    () =>
      deposit.amountUsd !== null && cargos.isSuccess
        ? sugerirCuotas(deposit.amountUsd, pendientes, reparto)
        : null,
    [deposit.amountUsd, cargos.isSuccess, pendientes, reparto],
  )

  const marcadas = tocado ?? new Set(sugerencia ?? [])
  const { cuotasUsd, cargosUsd } = montoDeLaSeleccion(pendientes, marcadas, reparto)
  const viajan = cargosQueViajan(marcadas, reparto)
  const diferencia = deposit.amountUsd === null ? null : deposit.amountUsd - cuotasUsd - cargosUsd

  const mutation = useMutation({
    mutationFn: (nota: string) =>
      assignDeposit({
        lineId: deposit.id,
        userId: persona.userId,
        installmentIds: [...marcadas],
        note: nota || undefined,
      }),
    onSuccess: () => {
      setConfirmando(false)
      void queryClient.invalidateQueries({ queryKey: ['unmatched-deposits'] })
      void queryClient.invalidateQueries({ queryKey: ['payment-queue'] })
      void queryClient.invalidateQueries({ queryKey: ['admin-overview'] })
      void queryClient.invalidateQueries({ queryKey: ['admin-collections'] })
      void queryClient.invalidateQueries({ queryKey: ['admin-user', persona.userId] })
      void queryClient.invalidateQueries({ queryKey: ['admin-late-fees', persona.userId] })
      onHecho(
        `Abono asignado a ${persona.fullName ?? 'el paciente'}: ${marcadas.size} ${
          marcadas.size === 1 ? 'cuota' : 'cuotas'
        }`,
      )
    },
  })

  function alternar(id: string) {
    const siguiente = new Set(marcadas)
    if (siguiente.has(id)) siguiente.delete(id)
    else siguiente.add(id)
    setTocado(siguiente)
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between gap-3">
        <SectionTitle>Cuotas de {persona.fullName ?? 'este paciente'}</SectionTitle>
        <Button size="sm" variant="text" onClick={onCambiarPersona}>
          Cambiar de paciente
        </Button>
      </div>

      {detalle.isPending && <SkeletonList rows={3} />}

      {detalle.isError && (
        <ErrorBox title="No se pudieron leer sus cuotas" detail={describeError(detalle.error)} />
      )}

      {detalle.data && pendientes.length === 0 && (
        <Callout tone="info" titulo="Este paciente no tiene ninguna cuota pendiente">
          El saldo a favor todavía no se puede dejar desde el panel.
        </Callout>
      )}

      {sugerencia && tocado === null && (
        <p className="type-panel-caption text-on-surface-variant">
          Vienen marcadas las que cuadran con el abono, desde la más antigua.
        </p>
      )}

      <div className="flex max-h-72 flex-col gap-2 overflow-y-auto">
        {pendientes.map((c) => (
          <div
            key={c.id}
            className="flex items-center gap-3 rounded-panel-control bg-panel-raised p-3 transition-colors duration-[var(--transition-fast)] hover:bg-panel-control"
          >
            <div className="flex-1">
              <Checkbox
                id={`cuota-del-abono-${c.id}`}
                checked={marcadas.has(c.id)}
                onChange={() => alternar(c.id)}
                label={
                  <>
                    <span className="block">
                      Cuota {c.sequence} de {deN.get(c.chargeId) ?? c.sequence} · {c.merchantName}
                      {c.orderNumber !== null && ` · orden #${c.orderNumber}`}
                    </span>
                    <span className="block type-panel-caption text-on-surface-variant">
                      Vence el {formatDay(c.dueDate)}
                      {c.daysOverdue > 0 && `, con ${c.daysOverdue} días de atraso`}
                      {(reparto.porCuota.get(c.id)?.length ?? 0) > 0 && ', con cargo por atraso'}
                    </span>
                  </>
                }
              />
            </div>
            {/* La cuota, con el service fee dentro: lo que se salda. */}
            <span className="font-semibold tabular-nums text-on-surface">
              {formatUsd(c.amountUsd)}
            </span>
          </div>
        ))}
      </div>

      {cargos.isError && (
        <Callout
          tone="warning"
          titulo="No se pudieron leer sus cargos por atraso"
          accion={
            <Button size="sm" variant="tonal" onClick={() => void cargos.refetch()}>
              Reintentar
            </Button>
          }
        >
          La suma de abajo no los incluye.
        </Callout>
      )}

      {marcadas.size > 0 && (
        <div className="flex flex-col gap-1 rounded-panel-control border border-panel-hairline p-4">
          <div className="flex items-baseline justify-between gap-3">
            <span className="type-panel-body text-on-surface-variant">
              {marcadas.size} {marcadas.size === 1 ? 'cuota marcada' : 'cuotas marcadas'}, con fee
            </span>
            <span className="type-panel-section tabular-nums text-on-surface">
              {formatUsd(cuotasUsd)}
            </span>
          </div>
          {viajan.length > 0 && (
            <div className="flex items-baseline justify-between gap-3">
              <span className="type-panel-body text-on-surface-variant">
                {viajan.length === 1 ? 'Un cargo por atraso' : `${viajan.length} cargos por atraso`}{' '}
                que se cobran con ellas
              </span>
              <span className="type-panel-body font-semibold tabular-nums text-on-surface">
                {formatUsd(cargosUsd)}
              </span>
            </div>
          )}
        </div>
      )}

      {/* Una diferencia grande casi siempre es la persona equivocada. */}
      {diferencia !== null && marcadas.size > 0 && Math.abs(diferencia) > TOLERANCIA_EUR && (
        <Callout
          tone="warning"
          titulo={`La diferencia es de ${formatUsd(Math.abs(diferencia))} ${
            diferencia > 0 ? 'a favor del abono' : 'en contra del abono'
          }`}
          detalles={
            viajan.length > 0 ? (
              <ul className="flex flex-col gap-0.5 type-panel-caption">
                {viajan.map((f) => (
                  <li key={f.id}>
                    {formatUsd(f.amountUsd)} por{' '}
                    {f.sequence !== null
                      ? `la cuota ${f.sequence} de ${f.merchantName ?? 'una clínica'}, con vencimiento el ${formatDay(f.dueDate)}`
                      : 'un atraso anterior sin cuota'}
                  </li>
                ))}
              </ul>
            ) : undefined
          }
        >
          {/* Cuotas y cargos por atraso: lo que el servidor va a cobrar con
              ellas. No hay ningún fee sumado aparte: va dentro de cada cuota. */}
          El abono es de {formatUsd(deposit.amountUsd ?? 0)} y lo marcado suma{' '}
          {formatUsd(cuotasUsd + cargosUsd)}
          {viajan.length > 0 && `, con ${formatUsd(cargosUsd)} de cargos por atraso`}.
        </Callout>
      )}

      {mutation.isError && (
        <ErrorBox title="No se pudo asignar" detail={describeError(mutation.error)} />
      )}

      <Button
        size="md"
        disabled={marcadas.size === 0}
        motivoApagado="Marca al menos una cuota."
        onClick={() => setConfirmando(true)}
      >
        Asignar el abono
      </Button>

      {confirmando && (
        <ConfirmDialog
          title="Asignar el abono"
          summary={`Vas a aplicar ${
            deposit.amountUsd === null ? formatVes(deposit.amountVes) : formatUsd(deposit.amountUsd)
          } (referencia ${deposit.reference}) a ${marcadas.size} ${
            marcadas.size === 1 ? 'cuota' : 'cuotas'
          } de ${persona.fullName ?? 'este paciente'}.`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              Igual que un pago reportado: se salda lo marcado, se escribe el asiento y le llega
              el aviso.
            </p>
          }
          nivel="sensible"
          reasonLabel="Por qué se asigna a este paciente"
          reasonPlaceholder="Avisó por WhatsApp que transfirió y el pago no estaba registrado"
          confirmLabel="Asignar"
          busy={mutation.isPending}
          error={mutation.isError ? describeError(mutation.error) : undefined}
          onConfirm={(razon) => mutation.mutate(razon)}
          onClose={() => setConfirmando(false)}
        />
      )}
    </div>
  )
}
