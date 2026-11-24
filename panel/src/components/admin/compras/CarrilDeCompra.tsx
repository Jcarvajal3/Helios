import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { Ban, Truck } from 'lucide-react'

import { useAtajos } from '@/components/admin/ModoCola'
import { useToast } from '@/components/Toast'
import {
  Button,
  Card,
  DataLabel,
  ErrorBox,
  Input,
  Modal,
  Tecla,
  Textarea,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { avanzarEstadoCompra } from '@/features/admin/compras/api'
import {
  SIGUIENTES_ESTADOS_LOGISTICA,
  sePuedeCancelarSolicitud,
} from '@/features/admin/compras/estados'
import type {
  EstadoSolicitudCompra,
  PagoCompraReporte,
  SolicitudCompraResumen,
} from '@/features/admin/compras/tipos'
import { valorDe } from '@/features/admin/parametros'
import { useIsSuperAdmin } from '@/features/admin/role'
import { useParametros } from '@/features/admin/useParametros'
import { useSession } from '@/features/auth/session'
import { describeError } from '@/lib/supabase'
import { DialogoDePago } from './DialogosDePago'
import type { TipoDialogoPago } from './DialogosDePago'

type PasoLogistica = {
  status: EstadoSolicitudCompra
  label: string
  requiereAmazonOrderId?: boolean
  requiereUsTracking?: boolean
}

/** Carril fijo de la ficha: conciliación del pago abierto, aduana, logística y cancelación. */
export function CarrilDeCompra({
  request,
  pagoAbierto,
  onAprobarAduana,
  onRechazarAduana,
  onCancelar,
  onRefrescar,
}: {
  request: SolicitudCompraResumen
  pagoAbierto: PagoCompraReporte | null
  onAprobarAduana: () => void
  onRechazarAduana: () => void
  onCancelar: () => void
  onRefrescar: () => void
}) {
  const session = useSession()
  const esSuperAdmin = useIsSuperAdmin()
  const parametros = useParametros()
  const [dialogoPago, setDialogoPago] = useState<TipoDialogoPago | null>(null)
  const [pasoLogistica, setPasoLogistica] = useState<PasoLogistica | null>(null)

  const cuatroOjos = valorDe(parametros.data, 'payment_four_eyes') === 1
  const registradoPorMi =
    Boolean(pagoAbierto?.registeredById) &&
    pagoAbierto?.registeredById === session?.user.id
  const bloqueadoCuatroOjos =
    (pagoAbierto ? !pagoAbierto.canApprove : false) ||
    (cuatroOjos && registradoPorMi && !esSuperAdmin)

  // A y R abren el mismo diálogo que los botones; `useAtajos` ya las ignora al escribir o con una ventana abierta.
  useAtajos(
    {
      a: () => {
        if (!bloqueadoCuatroOjos) setDialogoPago('aprobar')
      },
      r: () => setDialogoPago('rechazar'),
    },
    pagoAbierto !== null,
  )

  const siguientes = SIGUIENTES_ESTADOS_LOGISTICA[request.status] ?? []

  return (
    <>
      <Card as="section" className="flex flex-col gap-4">
        <div className="flex flex-col gap-1">
          <DataLabel>Total de la solicitud</DataLabel>
          <p className="type-panel-figure text-on-surface">
            {formatUsd(request.totalUsd)}
          </p>
          <p className="type-panel-caption text-panel-muted">
            {request.totalVesQuote !== null
              ? `${formatVes(request.totalVesQuote)} al cotizar`
              : 'Sin total en bolívares congelado'}
          </p>
        </div>

        {pagoAbierto && (
          <div className="flex flex-col gap-2 border-t border-panel-hairline pt-4">
            <DataLabel>Conciliar pago reportado</DataLabel>
            <p className="type-panel-caption text-on-surface-variant">
              {pagoAbierto.amountVes !== null
                ? formatVes(pagoAbierto.amountVes)
                : 'Monto no declarado'}{' '}
              · {pagoAbierto.bank ?? 'Banco'} · Ref.{' '}
              <span className="font-mono">{pagoAbierto.reference ?? '—'}</span>
            </p>
            <Button
              size="md"
              className="w-full"
              disabled={bloqueadoCuatroOjos}
              motivoApagado={
                bloqueadoCuatroOjos
                  ? 'Doble control activo: quien registró el pago no puede aprobarlo (pide a otro operador o super admin).'
                  : undefined
              }
              onClick={() => setDialogoPago('aprobar')}
            >
              Aprobar pago <Tecla enBoton>A</Tecla>
            </Button>
            <Button
              size="md"
              variant="tonal"
              className="w-full"
              onClick={() => setDialogoPago('rechazar')}
            >
              Rechazar pago <Tecla enBoton>R</Tecla>
            </Button>
            <Button
              size="md"
              variant="text"
              className="w-full"
              disabled={pagoAbierto.status === 'in_review'}
              motivoApagado="Este pago ya está en revisión."
              onClick={() => setDialogoPago('revision')}
            >
              Marcar en revisión
            </Button>
            <Button
              size="md"
              variant="text"
              className="w-full"
              onClick={() => setDialogoPago('duplicado')}
            >
              Marcar duplicado
            </Button>
          </div>
        )}

        {request.status === 'revision_aduanal' && (
          <div className="flex flex-col gap-2 border-t border-panel-hairline pt-4">
            <DataLabel>Decisión aduanal</DataLabel>
            <Button size="md" className="w-full" onClick={onAprobarAduana}>
              Aprobar aduana
            </Button>
            <Button
              size="md"
              variant="tonal"
              className="w-full"
              onClick={onRechazarAduana}
            >
              Rechazar solicitud
            </Button>
          </div>
        )}

        {siguientes.length > 0 && (
          <div className="flex flex-col gap-2 border-t border-panel-hairline pt-4">
            <DataLabel>Gestión logística</DataLabel>
            {siguientes.map((paso, idx) => (
              <Button
                key={paso.status}
                size="md"
                variant={idx === 0 ? 'filled' : 'tonal'}
                className="w-full"
                onClick={() => setPasoLogistica(paso)}
              >
                <Truck size={15} aria-hidden />
                {paso.label}
              </Button>
            ))}
          </div>
        )}

        {sePuedeCancelarSolicitud(request.status) && (
          <div className="border-t border-panel-hairline pt-3">
            <Button
              size="sm"
              variant="text"
              className="w-full text-error hover:bg-error/10"
              onClick={onCancelar}
            >
              <Ban size={14} aria-hidden /> Cancelar solicitud
            </Button>
          </div>
        )}
      </Card>

      {dialogoPago && pagoAbierto && (
        <DialogoDePago
          tipo={dialogoPago}
          request={request}
          pago={pagoAbierto}
          registradoPorMi={registradoPorMi}
          onCerrar={() => setDialogoPago(null)}
          onHecho={() => {
            setDialogoPago(null)
            onRefrescar()
          }}
        />
      )}

      {pasoLogistica && (
        <ModalLogistica
          request={request}
          paso={pasoLogistica}
          onClose={() => setPasoLogistica(null)}
          onHecho={() => {
            setPasoLogistica(null)
            onRefrescar()
          }}
        />
      )}
    </>
  )
}

function ModalLogistica({
  request,
  paso,
  onClose,
  onHecho,
}: {
  request: SolicitudCompraResumen
  paso: PasoLogistica
  onClose: () => void
  onHecho: () => void
}) {
  const avisar = useToast()
  const [amazonOrderId, setAmazonOrderId] = useState(
    request.amazonOrderId ?? '',
  )
  const [usTrackingNumber, setUsTrackingNumber] = useState(
    request.usTrackingNumber ?? '',
  )
  const [nota, setNota] = useState('')

  const falta =
    paso.requiereAmazonOrderId && amazonOrderId.trim().length < 4
      ? 'Escribe el ID de la orden de Amazon.'
      : paso.requiereUsTracking && usTrackingNumber.trim().length < 4
        ? 'Escribe el número de rastreo USA.'
        : undefined

  const avanzar = useMutation({
    mutationFn: () =>
      avanzarEstadoCompra({
        requestId: request.id,
        status: paso.status,
        amazonOrderId: paso.requiereAmazonOrderId
          ? amazonOrderId
          : request.amazonOrderId,
        usTrackingNumber: paso.requiereUsTracking
          ? usTrackingNumber
          : request.usTrackingNumber,
        note: nota,
      }),
    onSuccess: () => {
      onHecho()
      avisar(`${request.code}: ${paso.label}.`)
    },
  })

  return (
    <Modal title={paso.label} width="sm" onClose={onClose}>
      <div className="flex flex-col gap-4">
        <p className="type-panel-body text-on-surface-variant">
          Actualiza el estado de{' '}
          <span className="font-mono text-on-surface">{request.code}</span> y
          notifica al médico el progreso del pedido.
        </p>
        {paso.requiereAmazonOrderId && (
          <Input
            id="logistica-amazon-order"
            label="Número de orden en Amazon"
            value={amazonOrderId}
            onChange={setAmazonOrderId}
            placeholder="114-3941689-8772232"
            autoComplete="off"
          />
        )}
        {paso.requiereUsTracking && (
          <Input
            id="logistica-us-tracking"
            label="Tracking de recepción en almacén USA"
            value={usTrackingNumber}
            onChange={setUsTrackingNumber}
            placeholder="1Z999AA10123456784"
            autoComplete="off"
          />
        )}
        <Textarea
          id="logistica-nota"
          label="Nota de seguimiento (opcional)"
          value={nota}
          onChange={setNota}
          rows={2}
          placeholder="Ej: Despachado en vuelo del viernes, estimado 5 días"
        />
        {avanzar.isError && (
          <ErrorBox
            title="No se pudo actualizar el estado"
            detail={describeError(avanzar.error)}
          />
        )}
        <div className="flex flex-wrap gap-2">
          <Button
            size="md"
            disabled={avanzar.isPending || falta !== undefined}
            motivoApagado={falta}
            onClick={() => avanzar.mutate()}
          >
            {avanzar.isPending ? 'Guardando…' : 'Confirmar avance'}
          </Button>
          <Button size="md" variant="text" onClick={onClose}>
            Cancelar
          </Button>
        </div>
      </div>
    </Modal>
  )
}
