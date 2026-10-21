import { useState } from 'react'

import { Button, Callout, Card, Checkbox, Modal, formatDay, formatUsd, formatVes } from '@/components/ui'
import { CuotasDelAbono } from '@/components/admin/caja/CuotasDelAbono'
import { QuienPagoElAbono } from '@/components/admin/caja/QuienPagoElAbono'
import type { UnmatchedDeposit } from '@/features/admin/deposits'
import type { UserRow } from '@/features/admin/users'

/**
 * Asignar un abono: buscar a la persona, elegir sus cuotas, confirmar.
 *
 * Al confirmar, el servidor hace lo mismo que con un pago reportado desde la
 * app: la misma cotización, el mismo asiento, el mismo aviso. No hay un camino
 * paralelo para mover dinero.
 *
 * Tras asignar no se vuelve a la lista: «Siguiente abono» abre el que venía
 * después, que es como se despacha una lista de abonos.
 */
export function AsignarAbono({
  deposit,
  siguiente,
  onSiguiente,
  onClose,
}: {
  deposit: UnmatchedDeposit
  /** El abono que viene después en la lista, si queda alguno. */
  siguiente: UnmatchedDeposit | null
  onSiguiente: (id: string) => void
  onClose: () => void
}) {
  const [persona, setPersona] = useState<UserRow | null>(null)
  const [hecho, setHecho] = useState<string | null>(null)
  // Un abono cuyo pagador no es de Helios casi seguro es de Ronda: asignarlo
  // pide confirmar que no lo es.
  const [confirmaQueEsDeHelios, setConfirmaQueEsDeHelios] = useState(false)
  const pideConfirmar = !deposit.deHelios && !confirmaQueEsDeHelios

  return (
    <Modal title="Asignar el abono" onClose={onClose} width="lg">
      <div className="flex flex-col gap-5">
        <Card tone="inset">
          <div className="flex flex-wrap items-baseline justify-between gap-3">
            <div>
              <p className="type-panel-body text-on-surface">
                Referencia <span className="font-mono">{deposit.reference}</span> · {deposit.bank}
              </p>
              <p className="mt-0.5 type-panel-caption text-on-surface-variant">
                Entró el {formatDay(deposit.movedOn)}
                {deposit.description && ` · ${deposit.description}`}
              </p>
            </div>
            <p className="type-panel-section tabular-nums text-on-surface">
              {deposit.amountUsd === null ? formatVes(deposit.amountVes) : formatUsd(deposit.amountUsd)}
            </p>
          </div>
        </Card>

        {hecho !== null ? (
          <div className="flex flex-col gap-4">
            <Callout tone="success" titulo={hecho}>
              {siguiente ? undefined : 'No quedan más abonos sin dueño en la lista.'}
            </Callout>
            <div className="flex flex-wrap gap-3">
              {siguiente && (
                <Button size="md" onClick={() => onSiguiente(siguiente.id)}>
                  Siguiente abono
                </Button>
              )}
              <Button size="md" variant="tonal" onClick={onClose}>
                Volver a la lista
              </Button>
            </div>
          </div>
        ) : pideConfirmar ? (
          <div className="flex flex-col gap-4">
            <Callout tone="warning" titulo="Este abono parece de Ronda">
              Quien pagó no es paciente de Helios ni el pagador de ningún pago registrado aquí. Helios y Ronda
              cobran en la misma cuenta del BNC: si es de Ronda, no se asigna aquí, se descarta.
            </Callout>
            <Checkbox
              id={`abono-de-helios-${deposit.id}`}
              label="Sé que este abono es de un paciente de Helios (pagó otra persona por él, por ejemplo)"
              checked={confirmaQueEsDeHelios}
              onChange={setConfirmaQueEsDeHelios}
            />
          </div>
        ) : persona === null ? (
          <QuienPagoElAbono deposit={deposit} onElegir={setPersona} />
        ) : (
          <CuotasDelAbono
            deposit={deposit}
            persona={persona}
            onCambiarPersona={() => setPersona(null)}
            onHecho={setHecho}
          />
        )}
      </div>
    </Modal>
  )
}
