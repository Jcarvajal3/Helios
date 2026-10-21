import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { TriangleAlert } from 'lucide-react'

import {
  Button,
  Callout,
  Checkbox,
  ConfirmDialog,
  Input,
  Select,
  Tecla,
  formatDay,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { useAtajos } from '@/components/admin/ModoCola'
import { useToast } from '@/components/Toast'
import { flagForReview, reconcilePayment } from '@/features/admin/api'
import type { QueueItem, StatementMatch } from '@/features/admin/api'
import { explicarErrorDeAprobacion } from '@/features/admin/pagosRegistrados/registrarPago'
import { useSession } from '@/features/auth/session'
import { describeError } from '@/lib/supabase'

const MOTIVOS_RECHAZO = [
  { value: 'La referencia no existe en el extracto del banco', label: 'La referencia no existe' },
  { value: 'El monto no coincide con lo que entró al banco', label: 'El monto no coincide' },
  { value: 'Pago duplicado: ya se registró esta misma referencia', label: 'Pago duplicado' },
  { value: '', label: 'Otro motivo' },
]

type Dialogo = 'aprobar' | 'rechazar' | 'revision'

/**
 * Los tres botones que cierran un pago pendiente, con sus diálogos.
 *
 * A abre «Aprobar» y R abre «Rechazar», para despachar la cola sin ratón.
 * «Poner en revisión» no tiene tecla: aparta un pago para mirarlo con calma y
 * no es algo que se haga de corrido.
 *
 * `onResuelto` recibe el aviso ya escrito; quien lo monta decide si salta al
 * siguiente de la cola o se queda.
 *
 * Vive en el carril de la ficha, así que los botones van uno debajo de otro,
 * a lo ancho, y encima la línea que dice si el extracto respalda el pago.
 */
export function DecisionDelPago({
  item,
  movimiento,
  sinCotejo,
  motivoConAviso = null,
  onResuelto,
}: {
  item: QueueItem
  /** El movimiento del extracto que respaldará la aprobación, si hay uno. */
  movimiento: StatementMatch | null
  /**
   * Por qué el extracto no respalda el pago, o `null` si lo respalda.
   * Aprobarlo sin respaldo pide marcarlo y dar el motivo.
   */
  sinCotejo: string | null
  /**
   * Si el aviso (SMS) del BNC encaja con el pago, el motivo de aprobarlo sin
   * cotejo ya escrito: el SMS es el respaldo mientras llega el extracto.
   */
  motivoConAviso?: string | null
  onResuelto: (aviso: string) => void
}) {
  const queryClient = useQueryClient()
  const avisar = useToast()
  const session = useSession()
  const [dialogo, setDialogo] = useState<Dialogo | null>(null)
  const [aceptaSinCotejo, setAceptaSinCotejo] = useState(false)
  const [motivo, setMotivo] = useState(MOTIVOS_RECHAZO[0].value)
  const [detalle, setDetalle] = useState('')

  const quien = item.fullName ?? 'sin nombre'

  function refrescar() {
    void queryClient.invalidateQueries({ queryKey: ['payment-queue'] })
    void queryClient.invalidateQueries({ queryKey: ['payment-report', item.reportId] })
    void queryClient.invalidateQueries({ queryKey: ['admin-overview'] })
    void queryClient.invalidateQueries({ queryKey: ['reconciliation-health'] })
  }

  const aprobar = useMutation({
    mutationFn: (nota: string) =>
      reconcilePayment({
        reportId: item.reportId,
        approve: true,
        note: nota || undefined,
        // El que se ve es el que se guarda: si entre tanto otro pago lo usó,
        // la base lo dice en vez de ligar otro.
        statementLineId: sinCotejo === null ? movimiento?.id : undefined,
      }),
    onSuccess: () => {
      setDialogo(null)
      refrescar()
      onResuelto(`Aprobado: ${formatUsd(item.amountUsd)} de ${quien}`)
    },
  })

  const rechazar = useMutation({
    mutationFn: (nota: string) =>
      reconcilePayment({ reportId: item.reportId, approve: false, note: nota }),
    onSuccess: () => {
      setDialogo(null)
      refrescar()
      onResuelto(`Rechazado: ${formatUsd(item.amountUsd)} de ${quien}`)
    },
  })

  const revisar = useMutation({
    mutationFn: (nota: string) => flagForReview(item.reportId, nota),
    onSuccess: () => {
      setDialogo(null)
      refrescar()
      avisar(`El pago de ${quien} queda en revisión`)
    },
  })

  useAtajos({ a: () => setDialogo('aprobar'), r: () => setDialogo('rechazar') })

  // El servidor solo aparta un pago recién llegado.
  const sePuedeApartar = item.status === 'reported'

  return (
    <>
      <div className="flex flex-col gap-2">
        {sinCotejo !== null && (
          <p className="mb-1 flex items-start gap-1.5 type-panel-caption text-on-surface-variant">
            <TriangleAlert size={14} aria-hidden className="mt-px shrink-0 text-warning" />
            {sinCotejo}{' '}
            {motivoConAviso ? 'Lo respalda el aviso del BNC: el motivo ya va escrito.' : 'Aprobarlo pide el motivo.'}
          </p>
        )}
        <Button size="md" className="w-full" onClick={() => setDialogo('aprobar')}>
          Aprobar <Tecla enBoton>A</Tecla>
        </Button>
        <Button variant="tonal" size="md" className="w-full" onClick={() => setDialogo('rechazar')}>
          Rechazar <Tecla enBoton>R</Tecla>
        </Button>
        <Button
          variant="text"
          size="md"
          className="w-full"
          disabled={!sePuedeApartar}
          motivoApagado="Este pago ya está en revisión."
          onClick={() => setDialogo('revision')}
        >
          Poner en revisión
        </Button>
      </div>

      {dialogo === 'aprobar' && (
        <ConfirmDialog
          title="Aprobar el pago"
          summary={`Vas a aprobar el pago de ${quien}: ${formatUsd(item.amountUsd)} (${item.installmentCount} ${
            item.installmentCount === 1 ? 'cuota' : 'cuotas'
          } con comisión${
            item.lateFeeUsd > 0 ? ` y ${formatUsd(item.lateFeeUsd)} en cargos por atraso` : ''
          })${item.reference ? `, referencia ${item.reference}` : ''}.`}
          detail={
            <>
              <p className="type-panel-body text-on-surface-variant">
                Se saldan las cuotas y los cargos por atraso de «Qué salda este pago». Se
                escribe el asiento, se descongela al paciente si ya no debe nada vencido y le
                llega el aviso.
              </p>

              {sinCotejo === null && movimiento && (
                <p className="mt-2 type-panel-body text-on-surface">
                  Queda respaldado por el movimiento del {formatDay(movimiento.movedOn)}, referencia{' '}
                  <span className="font-mono">{movimiento.reference}</span>, por{' '}
                  {formatVes(movimiento.amountVes)}
                </p>
              )}

              {/* Aprobar sin cotejo es fiarse de lo que escribió la persona:
                  dentro de seis meses hay que poder saber quién lo hizo y por qué. */}
              {sinCotejo !== null && (
                <div className="mt-3 flex flex-col gap-3">
                  <Callout tone="warning" titulo="El extracto no respalda este pago">
                    {sinCotejo} El motivo queda en la bitácora.
                  </Callout>
                  <Checkbox
                    id={`sin-cotejo-${item.reportId}`}
                    label="Aprobar sin cotejo bancario"
                    checked={aceptaSinCotejo}
                    onChange={setAceptaSinCotejo}
                  />
                </div>
              )}
            </>
          }
          reasonLabel={sinCotejo !== null ? 'Por qué se aprueba sin cotejo' : undefined}
          reasonPlaceholder="El paciente envió la captura del banco por WhatsApp"
          reasonInicial={sinCotejo !== null && motivoConAviso ? motivoConAviso : undefined}
          bloqueo={
            sinCotejo !== null && !aceptaSinCotejo
              ? 'Marca «Aprobar sin cotejo bancario» para poder aprobarlo.'
              : undefined
          }
          confirmLabel={`Aprobar ${formatUsd(item.amountUsd)}`}
          busy={aprobar.isPending}
          // Con el doble control (`payment_four_eyes`), quien registró el
          // pago no puede aprobarlo: el 42501 se explica en vez de salir a
          // secas como «sin permiso».
          error={
            aprobar.isError
              ? explicarErrorDeAprobacion(
                  aprobar.error,
                  describeError(aprobar.error),
                  !!item.registeredById && item.registeredById === session?.user.id,
                )
              : undefined
          }
          onConfirm={(razon) => aprobar.mutate(razon)}
          onClose={() => setDialogo(null)}
        />
      )}

      {dialogo === 'rechazar' && (
        <ConfirmDialog
          title="Rechazar el pago"
          summary={`${item.fullName ?? 'El paciente'} va a recibir el motivo y podrá mandar el comprobante otra vez.`}
          detail={
            <div className="flex flex-col gap-3">
              <Select
                id={`motivo-${item.reportId}`}
                label="Motivo"
                value={motivo}
                options={MOTIVOS_RECHAZO}
                onChange={setMotivo}
              />
              <Input
                id={`detalle-${item.reportId}`}
                label={motivo === '' ? 'Motivo' : 'Detalle (opcional)'}
                value={detalle}
                onChange={setDetalle}
                placeholder="No encontramos esta referencia en el extracto"
              />
            </div>
          }
          bloqueo={motivo === '' && detalle.trim().length === 0 ? 'Falta el motivo.' : undefined}
          confirmLabel="Confirmar el rechazo"
          danger
          busy={rechazar.isPending}
          error={rechazar.isError ? describeError(rechazar.error) : undefined}
          onConfirm={() => rechazar.mutate([motivo, detalle.trim()].filter(Boolean).join('. '))}
          onClose={() => setDialogo(null)}
        />
      )}

      {dialogo === 'revision' && (
        <ConfirmDialog
          title="Poner el pago en revisión"
          summary={`El pago de ${quien} queda marcado «En revisión», con tu nota.`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              Sigue pendiente: se aprueba o se rechaza después, como los demás.
            </p>
          }
          nivel="sensible"
          reasonLabel="Nota para el equipo"
          reasonPlaceholder="Llamar mañana para confirmar desde qué cuenta transfirió"
          confirmLabel="Poner en revisión"
          busy={revisar.isPending}
          error={revisar.isError ? describeError(revisar.error) : undefined}
          onConfirm={(nota) => revisar.mutate(nota)}
          onClose={() => setDialogo(null)}
        />
      )}
    </>
  )
}

/** La cuota pendiente más antigua de todo lo que salda el pago. */
export function cuotaMasVieja(item: QueueItem) {
  const todas = item.purchases.flatMap((p) => p.installments.filter((i) => i.status !== 'paid'))
  if (todas.length === 0) return null
  return todas.reduce((oldest, i) => (i.dueDate < oldest.dueDate ? i : oldest))
}
