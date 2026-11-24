import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  HandCoins,
  ShieldAlert,
  ShoppingBag,
  Smartphone,
  TriangleAlert,
} from 'lucide-react'

import {
  CabeceraDeFicha,
  MarcoDeFicha,
  VolverA,
} from '@/components/admin/ficha'
import { usePageTitle } from '@/components/layouts/PageAction'
import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Callout,
  Card,
  ConfirmDialog,
  ErrorBox,
  IconoDeArea,
  Seccion,
  SkeletonList,
  formatDateTime,
  formatPhone,
} from '@/components/ui'
import {
  avanzarEstadoCompra,
  decidirAduanaCompra,
} from '@/features/admin/compras/api'
import {
  CLAVE_COMPRAS,
  consultaDetalleCompra,
} from '@/features/admin/compras/consultas'
import { etiquetaDeEventoCompra } from '@/features/admin/compras/estados'
import type { DetalleSolicitudCompra } from '@/features/admin/compras/tipos'
import { describeError } from '@/lib/supabase'
import { CarrilDeCompra } from './CarrilDeCompra'
import { EstadoSolicitudCompraBadge } from './EstadoCompraBadge'
import { ModalPagoManual } from './ModalPagoManual'
import { TarjetaDesglose, TarjetaProducto } from './TarjetaDesglose'
import { TarjetaPagoReportado } from './TarjetaPagoReportado'

export function PaginaFichaCompra({ requestId }: { requestId: string }) {
  const query = useQuery(consultaDetalleCompra(requestId))
  const detalle = query.data ?? null

  usePageTitle(
    detalle
      ? `${detalle.request.code} · ${detalle.request.merchantName}`
      : 'Solicitud de compra',
  )

  return (
    <>
      <VolverA link={{ to: '/admin/compras' }}>Compras Amazon</VolverA>

      {query.isPending && <SkeletonList rows={4} />}

      {query.isError && (
        <ErrorBox
          title="No se pudo cargar la solicitud de compra"
          detail={describeError(query.error)}
        />
      )}

      {query.isSuccess && !detalle && (
        <ErrorBox
          title="Esta solicitud de compra no existe"
          detail="Puede que el enlace sea antiguo o que el identificador no corresponda a una solicitud registrada."
        />
      )}

      {detalle && (
        <FichaCompraContenido key={detalle.request.id} detalle={detalle} />
      )}
    </>
  )
}

function FichaCompraContenido({
  detalle,
}: {
  detalle: DetalleSolicitudCompra
}) {
  const { request, payments, events } = detalle
  const queryClient = useQueryClient()
  const avisar = useToast()

  const [modalPagoManual, setModalPagoManual] = useState(false)
  const [dialogoAduana, setDialogoAduana] = useState<
    'aprobar' | 'rechazar' | null
  >(null)
  const [dialogoCancelar, setDialogoCancelar] = useState(false)

  const pagoAbierto =
    payments.find((p) => p.status === 'reported' || p.status === 'in_review') ??
    null

  function invalidarTodo() {
    void queryClient.invalidateQueries({ queryKey: CLAVE_COMPRAS })
  }

  const aprobarAduana = useMutation({
    mutationFn: (nota: string) =>
      decidirAduanaCompra({
        requestId: request.id,
        approve: true,
        note: nota || null,
      }),
    onSuccess: () => {
      setDialogoAduana(null)
      invalidarTodo()
      avisar(
        `Aduana aprobada para ${request.code}. Se habilitó el pago al médico.`,
      )
    },
  })

  const rechazarAduana = useMutation({
    mutationFn: (nota: string) =>
      decidirAduanaCompra({
        requestId: request.id,
        approve: false,
        note: nota,
      }),
    onSuccess: () => {
      setDialogoAduana(null)
      invalidarTodo()
      avisar(`Solicitud ${request.code} rechazada por restricción aduanal.`)
    },
  })

  const cancelarSolicitud = useMutation({
    mutationFn: (nota: string) =>
      avanzarEstadoCompra({
        requestId: request.id,
        status: 'cancelado',
        note: nota,
      }),
    onSuccess: () => {
      setDialogoCancelar(false)
      invalidarTodo()
      avisar(`Solicitud ${request.code} cancelada.`)
    },
  })

  function cerrarAduana() {
    aprobarAduana.reset()
    rechazarAduana.reset()
    setDialogoAduana(null)
  }

  function cerrarCancelar() {
    cancelarSolicitud.reset()
    setDialogoCancelar(false)
  }

  const puedeRegistrarPagoManual =
    request.status === 'esperando_pago' || request.status === 'pago_reportado'

  return (
    <>
      <MarcoDeFicha
        carrilFijo
        etiquetaDelCarril="Acciones y logística"
        cabecera={
          <CabeceraDeFicha
            identidad={<IconoDeArea icon={ShoppingBag} tamano="md" />}
            nombre={
              <span className="inline-flex flex-wrap items-center gap-2">
                <span className="font-mono">{request.code}</span>
                <span className="text-on-surface-variant">·</span>
                <Link
                  to="/admin/clinicas/$id"
                  params={{ id: request.merchantId }}
                  className="hover:underline"
                >
                  {request.merchantName}
                </Link>
              </span>
            }
            insignias={
              <div className="flex flex-wrap items-center gap-1.5">
                <EstadoSolicitudCompraBadge valor={request.status} />
                {request.channel === 'simulador' && (
                  <Badge tone="neutral" icono={Smartphone}>
                    Simulador
                  </Badge>
                )}
                {request.restrictedFlag && (
                  <Badge tone="warning" icono={ShieldAlert}>
                    Aduana
                  </Badge>
                )}
                {request.vencida && (
                  <Badge tone="warning" icono={TriangleAlert}>
                    Cotización vencida
                  </Badge>
                )}
              </div>
            }
            datos={[
              request.doctorName,
              request.phone ? formatPhone(request.phone) : null,
              `Creada el ${formatDateTime(request.createdAt)}`,
            ]}
          />
        }
        carril={
          <CarrilDeCompra
            request={request}
            pagoAbierto={pagoAbierto}
            onAprobarAduana={() => setDialogoAduana('aprobar')}
            onRechazarAduana={() => setDialogoAduana('rechazar')}
            onCancelar={() => setDialogoCancelar(true)}
            onRefrescar={invalidarTodo}
          />
        }
      >
        {request.status === 'revision_aduanal' && (
          <Callout
            tone="warning"
            titulo="Requiere aprobación aduanal antes de habilitar el pago"
            accion={
              <div className="flex flex-wrap gap-2">
                <Button size="sm" onClick={() => setDialogoAduana('aprobar')}>
                  Aprobar aduana
                </Button>
                <Button
                  size="sm"
                  variant="tonal"
                  onClick={() => setDialogoAduana('rechazar')}
                >
                  Rechazar solicitud
                </Button>
              </div>
            }
          >
            {request.restrictedReason ??
              'Este artículo fue marcado con posible restricción aduanal o sanitaria. Valida si puede importarse antes de habilitar el pago en bolívares.'}
          </Callout>
        )}

        <TarjetaProducto request={request} />

        <TarjetaDesglose
          request={request}
          bcvRateToday={detalle.bcvRateToday}
          paymentBlock={detalle.paymentBlock}
        />

        <Seccion
          titulo="Pagos reportados y conciliación"
          controles={
            puedeRegistrarPagoManual ? (
              <Button
                size="sm"
                variant="tonal"
                onClick={() => setModalPagoManual(true)}
              >
                <HandCoins size={14} aria-hidden /> Registrar pago manual
              </Button>
            ) : undefined
          }
        >
          {payments.length === 0 ? (
            <Card className="flex flex-col gap-2">
              <p className="type-panel-body text-on-surface-variant">
                Todavía no hay pagos reportados para esta solicitud.
              </p>
              {puedeRegistrarPagoManual && (
                <p className="type-panel-caption text-panel-muted">
                  Si el médico envió el comprobante por WhatsApp o por fuera,
                  usa «Registrar pago manual» para cargarlo y conciliarlo aquí
                  mismo.
                </p>
              )}
            </Card>
          ) : (
            <div className="flex flex-col gap-3">
              {payments.map((pago) => (
                <TarjetaPagoReportado key={pago.id} pago={pago} />
              ))}
            </div>
          )}
        </Seccion>

        <Seccion titulo="Timeline de eventos">
          <Card>
            {events.length === 0 ? (
              <p className="type-panel-body text-on-surface-variant">
                Sin eventos registrados todavía.
              </p>
            ) : (
              <ol className="flex flex-col gap-4">
                {events.map((ev) => (
                  <li
                    key={ev.id}
                    className="flex flex-col gap-1 border-b border-panel-hairline pb-3 last:border-b-0 last:pb-0"
                  >
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span className="type-panel-body font-semibold text-on-surface">
                        {ev.title || etiquetaDeEventoCompra(ev.eventType)}
                      </span>
                      <span className="type-panel-caption tabular-nums text-panel-muted">
                        {formatDateTime(ev.createdAt)}
                      </span>
                    </div>
                    {(ev.fromStatus || ev.toStatus) && (
                      <div className="flex flex-wrap items-center gap-1.5">
                        {ev.fromStatus && (
                          <EstadoSolicitudCompraBadge valor={ev.fromStatus} />
                        )}
                        {ev.fromStatus && ev.toStatus && (
                          <span className="type-panel-caption text-panel-muted">
                            →
                          </span>
                        )}
                        {ev.toStatus && (
                          <EstadoSolicitudCompraBadge valor={ev.toStatus} />
                        )}
                      </div>
                    )}
                    {ev.note && (
                      <p className="type-panel-body text-on-surface-variant">
                        {ev.note}
                      </p>
                    )}
                    {ev.actorName && (
                      <p className="type-panel-caption text-panel-muted">
                        Por {ev.actorName}
                      </p>
                    )}
                  </li>
                ))}
              </ol>
            )}
          </Card>
        </Seccion>
      </MarcoDeFicha>

      {dialogoAduana === 'aprobar' && (
        <ConfirmDialog
          title="Aprobar revisión aduanal"
          summary={`Se aprobará la importación de ${request.code} (${request.productTitle}) y se notificará al médico para que realice el pago en bolívares.`}
          reasonLabel="Nota de aprobación (opcional)"
          reasonPlaceholder="Validado con agente aduanal, permitido por carga aérea"
          motivoMinimo={0}
          confirmLabel="Aprobar aduana y habilitar pago"
          busy={aprobarAduana.isPending}
          error={
            aprobarAduana.isError
              ? describeError(aprobarAduana.error)
              : undefined
          }
          onConfirm={(nota) => aprobarAduana.mutate(nota)}
          onClose={cerrarAduana}
        />
      )}

      {dialogoAduana === 'rechazar' && (
        <ConfirmDialog
          title="Rechazar solicitud por aduana"
          summary={`La solicitud ${request.code} se cancelará y se avisará al médico que el artículo no puede importarse.`}
          nivel="sensible"
          reasonLabel="Motivo del rechazo aduanal"
          reasonPlaceholder="Requiere permiso sanitario SACS no disponible para carga courier"
          confirmLabel="Rechazar y cancelar"
          danger
          busy={rechazarAduana.isPending}
          error={
            rechazarAduana.isError
              ? describeError(rechazarAduana.error)
              : undefined
          }
          onConfirm={(nota) => rechazarAduana.mutate(nota)}
          onClose={cerrarAduana}
        />
      )}

      {dialogoCancelar && (
        <ConfirmDialog
          title="Cancelar solicitud de compra"
          summary={`Vas a cancelar la solicitud ${request.code} de ${request.merchantName}.`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              El estado cambiará a «Cancelado», los pagos abiertos se cerrarán
              como rechazados y el motivo quedará registrado en el timeline de
              la solicitud.
            </p>
          }
          nivel="sensible"
          reasonLabel="Motivo de la cancelación"
          reasonPlaceholder="El médico solicitó cancelar antes de colocar la orden en Amazon"
          confirmLabel="Cancelar solicitud"
          danger
          busy={cancelarSolicitud.isPending}
          error={
            cancelarSolicitud.isError
              ? describeError(cancelarSolicitud.error)
              : undefined
          }
          onConfirm={(nota) => cancelarSolicitud.mutate(nota)}
          onClose={cerrarCancelar}
        />
      )}

      {modalPagoManual && (
        <ModalPagoManual
          request={request}
          onClose={() => setModalPagoManual(false)}
          onRegistrado={() => {
            setModalPagoManual(false)
            invalidarTodo()
            avisar(
              `Pago registrado para ${request.code}. Queda listo para conciliación.`,
            )
          }}
        />
      )}
    </>
  )
}
