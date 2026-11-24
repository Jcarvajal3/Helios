import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Ban,
  CheckCircle2,
  ExternalLink,
  HandCoins,
  Package,
  Plane,
  ShieldAlert,
  Ship,
  ShoppingBag,
  Smartphone,
  TriangleAlert,
  Truck,
} from 'lucide-react'

import { AdjuntarComprobante } from '@/components/admin/caja/AdjuntarComprobante'
import { VerCaptura } from '@/components/admin/caja/VerCaptura'
import { CabeceraDeFicha, MarcoDeFicha, VolverA } from '@/components/admin/ficha'
import { usePageTitle } from '@/components/layouts/PageAction'
import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Callout,
  Card,
  ConfirmDialog,
  DataLabel,
  ErrorBox,
  IconoDeArea,
  Input,
  Modal,
  Seccion,
  Select,
  SkeletonList,
  Textarea,
  claseDeBoton,
  diaOperativo,
  formatBcvRate,
  formatDateTime,
  formatDay,
  formatNumero,
  formatPhone,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { formatTasa } from '@/features/admin/ajustesReglas'
import { BANKS } from '@/features/admin/banks'
import {
  avanzarEstadoCompra,
  conciliarPagoCompra,
  decidirAduanaCompra,
  marcarPagoCompraDuplicado,
  marcarPagoCompraEnRevision,
  registrarPagoCompra,
  subirComprobanteCompra,
} from '@/features/admin/compras/api'
import {
  CLAVE_COMPRAS,
  consultaAjustesCompras,
  consultaDetalleCompra,
  consultaPrevisionPagoCompra,
} from '@/features/admin/compras/consultas'
import {
  METODOS_PAGO_COMPRA,
  SIGUIENTES_ESTADOS_LOGISTICA,
  etiquetaDeEnvio,
  etiquetaDeEventoCompra,
  etiquetaDeMetodoPago,
  sePuedeCancelarSolicitud,
} from '@/features/admin/compras/estados'
import type {
  DetalleSolicitudCompra,
  EstadoSolicitudCompra,
  MetodoPagoCompra,
  PagoCompraReporte,
  SolicitudCompraResumen,
} from '@/features/admin/compras/tipos'
import { valorDe } from '@/features/admin/parametros'
import {
  MARGEN_POR_DEFECTO,
  diferenciaEnBs,
  explicarErrorDeAprobacion,
  motivoDeArchivo,
} from '@/features/admin/pagosRegistrados/registrarPago'
import { useIsSuperAdmin } from '@/features/admin/role'
import { useParametros } from '@/features/admin/useParametros'
import { useSession } from '@/features/auth/session'
import { leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'
import { EstadoPagoCompraBadge, EstadoSolicitudCompraBadge } from './EstadoCompraBadge'

export function PaginaFichaCompra({ requestId }: { requestId: string }) {
  const query = useQuery(consultaDetalleCompra(requestId))
  const detalle = query.data ?? null

  usePageTitle(
    detalle ? `${detalle.request.code} · ${detalle.request.merchantName}` : 'Solicitud de compra',
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

      {detalle && <FichaCompraContenido key={detalle.request.id} detalle={detalle} />}
    </>
  )
}

function FichaCompraContenido({ detalle }: { detalle: DetalleSolicitudCompra }) {
  const { request, payments, events } = detalle
  const ajustes = useQuery(consultaAjustesCompras())
  const bcvRateToday = detalle.bcvRateToday ?? ajustes.data?.bcvRateToday ?? null
  const queryClient = useQueryClient()
  const avisar = useToast()

  const [modalPagoManual, setModalPagoManual] = useState(false)
  const [dialogoAduana, setDialogoAduana] = useState<'aprobar' | 'rechazar' | null>(null)
  const [dialogoCancelar, setDialogoCancelar] = useState(false)

  const pagoAbierto =
    payments.find((p) => p.status === 'reported' || p.status === 'in_review') ?? null

  function invalidarTodo() {
    void queryClient.invalidateQueries({ queryKey: CLAVE_COMPRAS })
  }

  const aprobarAduana = useMutation({
    mutationFn: (nota: string) =>
      decidirAduanaCompra({ requestId: request.id, approve: true, note: nota || null }),
    onSuccess: () => {
      setDialogoAduana(null)
      invalidarTodo()
      avisar(`Aduana aprobada para ${request.code}. Se habilitó el pago al médico.`)
    },
  })

  const rechazarAduana = useMutation({
    mutationFn: (nota: string) =>
      decidirAduanaCompra({ requestId: request.id, approve: false, note: nota }),
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
            bcvRateToday={bcvRateToday}
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
                <Button size="sm" variant="tonal" onClick={() => setDialogoAduana('rechazar')}>
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

        <TarjetaDesgloseFinanciero request={request} bcvRateToday={bcvRateToday} />

        <Seccion
          titulo="Pagos reportados y conciliación"
          controles={
            puedeRegistrarPagoManual ? (
              <Button size="sm" variant="tonal" onClick={() => setModalPagoManual(true)}>
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
                  Si el médico envió el comprobante por WhatsApp o por fuera, usa «Registrar pago
                  manual» para cargarlo y conciliarlo aquí mismo.
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
                        {ev.fromStatus && <EstadoSolicitudCompraBadge valor={ev.fromStatus} />}
                        {ev.fromStatus && ev.toStatus && (
                          <span className="type-panel-caption text-panel-muted">→</span>
                        )}
                        {ev.toStatus && <EstadoSolicitudCompraBadge valor={ev.toStatus} />}
                      </div>
                    )}
                    {ev.note && (
                      <p className="type-panel-body text-on-surface-variant">{ev.note}</p>
                    )}
                    {ev.actorName && (
                      <p className="type-panel-caption text-panel-muted">
                        Por {ev.actorName}
                        {ev.actorRole ? ` (${ev.actorRole})` : ''}
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
          error={aprobarAduana.isError ? describeError(aprobarAduana.error) : undefined}
          onConfirm={(nota) => aprobarAduana.mutate(nota)}
          onClose={() => setDialogoAduana(null)}
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
          error={rechazarAduana.isError ? describeError(rechazarAduana.error) : undefined}
          onConfirm={(nota) => rechazarAduana.mutate(nota)}
          onClose={() => setDialogoAduana(null)}
        />
      )}

      {dialogoCancelar && (
        <ConfirmDialog
          title="Cancelar solicitud de compra"
          summary={`Vas a cancelar la solicitud ${request.code} de ${request.merchantName}.`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              El estado cambiará a «Cancelado» y el motivo quedará registrado en el timeline de la
              solicitud.
            </p>
          }
          nivel="sensible"
          reasonLabel="Motivo de la cancelación"
          reasonPlaceholder="El médico solicitó cancelar antes de colocar la orden en Amazon"
          confirmLabel="Cancelar solicitud"
          danger
          busy={cancelarSolicitud.isPending}
          error={cancelarSolicitud.isError ? describeError(cancelarSolicitud.error) : undefined}
          onConfirm={(nota) => cancelarSolicitud.mutate(nota)}
          onClose={() => setDialogoCancelar(false)}
        />
      )}

      {modalPagoManual && (
        <ModalRegistrarPagoManual
          request={request}
          onClose={() => setModalPagoManual(false)}
          onRegistrado={() => {
            setModalPagoManual(false)
            invalidarTodo()
            avisar(`Pago registrado para ${request.code}. Queda listo para conciliación.`)
          }}
        />
      )}
    </>
  )
}

// ── Tarjeta de producto ────────────────────────────────────────────────────

function TarjetaProducto({ request }: { request: SolicitudCompraResumen }) {
  return (
    <Seccion titulo="Producto cotizado">
      <Card className="flex flex-col gap-4">
        <div className="flex flex-col gap-4 sm:flex-row">
          <div className="flex size-28 shrink-0 items-center justify-center overflow-hidden rounded-panel-control border border-panel-hairline bg-panel-raised">
            {request.imageUrl ? (
              <img
                src={request.imageUrl}
                alt={request.productTitle}
                className="size-full object-cover"
              />
            ) : (
              <Package size={32} className="text-panel-muted" aria-hidden />
            )}
          </div>
          <div className="flex min-w-0 flex-1 flex-col gap-2">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <h3 className="type-panel-body font-semibold text-on-surface">
                {request.productTitle}
              </h3>
              {request.productUrl && (
                <a
                  href={request.productUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                  className={claseDeBoton('tonal', 'sm')}
                >
                  Ver en Amazon <ExternalLink size={14} aria-hidden />
                </a>
              )}
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge tone="neutral">ASIN: {request.asin}</Badge>
              <Badge tone="neutral" icono={request.shippingMethod === 'maritimo' ? Ship : Plane}>
                Envío {etiquetaDeEnvio(request.shippingMethod)}
              </Badge>
              <Badge tone="neutral">Cantidad: {request.quantity}</Badge>
              {request.variantLabel && <Badge tone="neutral">{request.variantLabel}</Badge>}
              {request.category && <Badge tone="neutral">{request.category}</Badge>}
            </div>

            <dl className="mt-1 grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-4">
              <Dato
                label="Peso real"
                value={request.weightLb !== null ? `${formatNumero(request.weightLb, 2)} lb` : 'Sin listar'}
              />
              <Dato
                label="Peso volumétrico"
                value={
                  request.volumetricWeightLb !== null
                    ? `${formatNumero(request.volumetricWeightLb, 2)} lb`
                    : '—'
                }
              />
              <Dato
                label="Volumen"
                value={request.volumeFt3 !== null ? `${formatNumero(request.volumeFt3, 2)} ft³` : '—'}
              />
              <Dato label="Precio unitario" value={formatUsd(request.unitPriceUsd)} />
            </dl>
          </div>
        </div>

        {request.weightEstimated && (
          <Callout tone="warning" titulo="Peso estimado en la cotización">
            Amazon no listó el peso exacto de este producto; se utilizó el peso de respaldo
            configurado en Ajustes para calcular el flete.
          </Callout>
        )}

        {(request.amazonOrderId || request.usTrackingNumber) && (
          <div className="grid grid-cols-1 gap-3 border-t border-panel-hairline pt-3 sm:grid-cols-2">
            {request.amazonOrderId && (
              <Dato label="ID de orden en Amazon" value={request.amazonOrderId} mono />
            )}
            {request.usTrackingNumber && (
              <Dato label="Tracking almacén USA" value={request.usTrackingNumber} mono />
            )}
          </div>
        )}
      </Card>
    </Seccion>
  )
}

// ── Desglose financiero congelado ──────────────────────────────────────────

function TarjetaDesgloseFinanciero({
  request,
  bcvRateToday,
}: {
  request: SolicitudCompraResumen
  bcvRateToday: number | null
}) {
  const tasaHoy = bcvRateToday ?? request.bcvRateToday
  const vesHoy =
    request.totalVesToday ??
    (tasaHoy !== null ? Math.round(request.totalUsd * tasaHoy * 100) / 100 : null)

  return (
    <Seccion titulo="Desglose financiero congelado">
      <Card className="flex flex-col gap-3">
        <div className="flex flex-col gap-2">
          <FilaFinanciera
            rotulo={`Subtotal Amazon (${request.quantity} × ${formatUsd(request.unitPriceUsd)})`}
            valor={formatUsd(request.subtotalUsd)}
          />
          <FilaFinanciera rotulo="Tax USA" valor={formatUsd(request.taxUsaUsd)} />
          <FilaFinanciera
            rotulo={`Envío internacional (${etiquetaDeEnvio(request.shippingMethod)})`}
            valor={formatUsd(request.shippingUsd)}
          />
          <FilaFinanciera rotulo="Tarifa de gestión Helios" valor={formatUsd(request.serviceFeeUsd)} />
        </div>

        <div className="border-t border-panel-hairline pt-3">
          <FilaFinanciera rotulo="Total en dólares" valor={formatUsd(request.totalUsd)} fuerte />
        </div>

        <div className="grid grid-cols-1 gap-3 rounded-panel-control bg-panel-raised p-3.5 sm:grid-cols-2">
          <div>
            <DataLabel>Equivalente en Bs hoy</DataLabel>
            <p className="mt-1 type-panel-section tabular-nums text-on-surface">
              {vesHoy !== null ? formatVes(vesHoy) : 'Sin tasa BCV cargada'}
            </p>
            {tasaHoy !== null && (
              <p className="mt-0.5 type-panel-caption text-on-surface-variant">
                {formatBcvRate(tasaHoy)}
              </p>
            )}
          </div>
          <div>
            <DataLabel>Referencia al cotizar</DataLabel>
            <p className="mt-1 type-panel-body font-semibold tabular-nums text-on-surface">
              {request.totalVesQuote !== null ? formatVes(request.totalVesQuote) : '—'}
            </p>
            <p className="mt-0.5 type-panel-caption text-on-surface-variant">
              {request.bcvRateQuote !== null
                ? formatTasa(request.bcvRateQuote, 'USD')
                : 'Se liquida a la tasa BCV del día del pago'}
            </p>
          </div>
        </div>
      </Card>
    </Seccion>
  )
}

// ── Tarjeta de cada pago reportado ─────────────────────────────────────────

function TarjetaPagoReportado({ pago }: { pago: PagoCompraReporte }) {
  const diff = diferenciaEnBs(pago.amountVes, pago.expectedVes, pago.fxRate, MARGEN_POR_DEFECTO)

  return (
    <Card className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <EstadoPagoCompraBadge valor={pago.status} />
          <span className="type-panel-body font-semibold tabular-nums text-on-surface">
            {formatVes(pago.amountVes)}
          </span>
          {diff && (
            <Badge tone={diff.cuadra ? 'success' : 'warning'} icono={diff.cuadra ? CheckCircle2 : TriangleAlert}>
              {diff.cuadra
                ? `Cuadra (${diff.bs >= 0 ? '+' : '−'}${formatVes(Math.abs(diff.bs))})`
                : `Fuera de margen (${diff.bs >= 0 ? '+' : '−'}${formatVes(Math.abs(diff.bs))})`}
            </Badge>
          )}
        </div>
        <span className="type-panel-caption tabular-nums text-panel-muted">
          Reportado el {formatDateTime(pago.createdAt)}
        </span>
      </div>

      <dl className="grid grid-cols-2 gap-x-4 gap-y-2.5 sm:grid-cols-4">
        <Dato label="Medio" value={etiquetaDeMetodoPago(pago.method)} />
        <Dato label="Banco" value={pago.bank ?? '—'} />
        <Dato label="Referencia" value={pago.reference ?? '—'} mono />
        <Dato label="Fecha del pago" value={formatDay(pago.paidOn)} />
        <Dato label="Teléfono pagador" value={formatPhone(pago.payerPhone)} />
        <Dato
          label="Esperado (Bs)"
          value={pago.expectedVes !== null ? formatVes(pago.expectedVes) : '—'}
        />
        <Dato
          label="Tasa BCV"
          value={pago.fxRate !== null ? formatTasa(pago.fxRate, 'USD') : '—'}
        />
        <Dato label="Registrado por" value={pago.registeredByName ?? 'Médico / Bot'} />
      </dl>

      {pago.referenceCollisions > 0 && (
        <Callout tone="warning" titulo="Referencia repetida en otro reporte">
          Esta referencia aparece en {pago.referenceCollisions}{' '}
          {pago.referenceCollisions === 1 ? 'reporte adicional' : 'reportes adicionales'}. Verifica
          el extracto bancario antes de aprobar.
        </Callout>
      )}

      {(pago.rejectionNote || pago.note) && (
        <p className="rounded-panel-control bg-panel-raised px-3 py-2 type-panel-body text-on-surface-variant">
          {pago.rejectionNote ?? pago.note}
        </p>
      )}

      {pago.reviewedAt && (
        <p className="type-panel-caption text-panel-muted">
          Revisado el {formatDateTime(pago.reviewedAt)}
          {pago.reviewedByName ? ` por ${pago.reviewedByName}` : ''}.
        </p>
      )}

      {pago.receiptPath && <VerCaptura ruta={pago.receiptPath} rotulo="Ver captura del comprobante" />}
    </Card>
  )
}

// ── Carril fijo derecho: Conciliación, Aduana y Logística ──────────────────

function CarrilDeCompra({
  request,
  pagoAbierto,
  bcvRateToday,
  onAprobarAduana,
  onRechazarAduana,
  onCancelar,
  onRefrescar,
}: {
  request: SolicitudCompraResumen
  pagoAbierto: PagoCompraReporte | null
  bcvRateToday: number | null
  onAprobarAduana: () => void
  onRechazarAduana: () => void
  onCancelar: () => void
  onRefrescar: () => void
}) {
  const avisar = useToast()
  const session = useSession()
  const esSuperAdmin = useIsSuperAdmin()
  const parametros = useParametros()

  const [dialogoPago, setDialogoPago] = useState<
    'aprobar' | 'rechazar' | 'revision' | 'duplicado' | null
  >(null)
  const [pasoLogistica, setPasoLogistica] = useState<{
    status: EstadoSolicitudCompra
    label: string
    requiereAmazonOrderId?: boolean
    requiereUsTracking?: boolean
  } | null>(null)
  const [amazonOrderId, setAmazonOrderId] = useState(request.amazonOrderId ?? '')
  const [usTrackingNumber, setUsTrackingNumber] = useState(request.usTrackingNumber ?? '')
  const [notaLogistica, setNotaLogistica] = useState('')

  const cuatroOjos = valorDe(parametros.data, 'payment_four_eyes') === 1
  const registradoPorMi =
    Boolean(pagoAbierto?.registeredById) && pagoAbierto?.registeredById === session?.user.id
  const bloqueadoCuatroOjos =
    (pagoAbierto ? !pagoAbierto.canApprove : false) ||
    (cuatroOjos && registradoPorMi && !esSuperAdmin)

  const aprobarPago = useMutation({
    mutationFn: (nota: string) =>
      conciliarPagoCompra({
        reportId: pagoAbierto?.id ?? '',
        approve: true,
        note: nota || null,
      }),
    onSuccess: () => {
      setDialogoPago(null)
      onRefrescar()
      avisar(`Pago aprobado para ${request.code}. El médico ya fue notificado.`)
    },
  })

  const rechazarPago = useMutation({
    mutationFn: (nota: string) =>
      conciliarPagoCompra({
        reportId: pagoAbierto?.id ?? '',
        approve: false,
        note: nota,
      }),
    onSuccess: () => {
      setDialogoPago(null)
      onRefrescar()
      avisar(`Pago rechazado para ${request.code}. Se avisó al médico para que reenvíe el comprobante.`)
    },
  })

  const ponerEnRevision = useMutation({
    mutationFn: (nota: string) =>
      marcarPagoCompraEnRevision({ reportId: pagoAbierto?.id ?? '', note: nota }),
    onSuccess: () => {
      setDialogoPago(null)
      onRefrescar()
      avisar('El pago quedó marcado en revisión.')
    },
  })

  const marcarDuplicado = useMutation({
    mutationFn: (nota: string) =>
      marcarPagoCompraDuplicado({ reportId: pagoAbierto?.id ?? '', note: nota }),
    onSuccess: () => {
      setDialogoPago(null)
      onRefrescar()
      avisar('Pago cerrado como duplicado (sin aviso al médico).')
    },
  })

  const avanzarLogistica = useMutation({
    mutationFn: () => {
      if (!pasoLogistica) throw new Error('Selecciona el siguiente paso.')
      return avanzarEstadoCompra({
        requestId: request.id,
        status: pasoLogistica.status,
        amazonOrderId: pasoLogistica.requiereAmazonOrderId ? amazonOrderId : request.amazonOrderId,
        usTrackingNumber: pasoLogistica.requiereUsTracking
          ? usTrackingNumber
          : request.usTrackingNumber,
        note: notaLogistica,
      })
    },
    onSuccess: () => {
      const etiqueta = pasoLogistica?.label ?? 'Estado actualizado'
      setPasoLogistica(null)
      setNotaLogistica('')
      onRefrescar()
      avisar(`${request.code}: ${etiqueta}.`)
    },
  })

  const siguientesLogistica = SIGUIENTES_ESTADOS_LOGISTICA[request.status] ?? []
  const tasaHoy = bcvRateToday ?? request.bcvRateToday
  const vesHoy =
    request.totalVesToday ??
    (tasaHoy !== null ? Math.round(request.totalUsd * tasaHoy * 100) / 100 : null)

  return (
    <>
      <Card as="section" className="flex flex-col gap-4">
        <div className="flex flex-col gap-1">
          <DataLabel>Total de la solicitud</DataLabel>
          <p className="type-panel-figure text-on-surface">{formatUsd(request.totalUsd)}</p>
          <p className="type-panel-caption text-panel-muted">
            {vesHoy !== null
              ? `${formatVes(vesHoy)} a tasa BCV de hoy`
              : 'Sin tasa BCV del día cargada'}
          </p>
        </div>

        {/* 1. Conciliación de pago abierto */}
        {pagoAbierto && (
          <div className="flex flex-col gap-2 border-t border-panel-hairline pt-4">
            <DataLabel>Conciliar pago reportado</DataLabel>
            <p className="type-panel-caption text-on-surface-variant">
              {formatVes(pagoAbierto.amountVes)} · {pagoAbierto.bank ?? 'Banco'} · Ref.{' '}
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
              Aprobar pago
            </Button>
            <Button
              size="md"
              variant="tonal"
              className="w-full"
              onClick={() => setDialogoPago('rechazar')}
            >
              Rechazar pago
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

        {/* 2. Revisión aduanal */}
        {request.status === 'revision_aduanal' && (
          <div className="flex flex-col gap-2 border-t border-panel-hairline pt-4">
            <DataLabel>Decisión aduanal</DataLabel>
            <Button size="md" className="w-full" onClick={onAprobarAduana}>
              Aprobar aduana
            </Button>
            <Button size="md" variant="tonal" className="w-full" onClick={onRechazarAduana}>
              Rechazar solicitud
            </Button>
          </div>
        )}

        {/* 3. Gestión logística desde pagado en adelante */}
        {siguientesLogistica.length > 0 && (
          <div className="flex flex-col gap-2 border-t border-panel-hairline pt-4">
            <DataLabel>Gestión logística</DataLabel>
            {siguientesLogistica.map((paso, idx) => (
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

        {/* 4. Cancelar solicitud */}
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

      {/* Diálogos de conciliación */}
      {dialogoPago === 'aprobar' && pagoAbierto && (
        <ConfirmDialog
          title="Aprobar pago de compra"
          summary={`Vas a aprobar el pago de ${formatVes(pagoAbierto.amountVes)} (${formatUsd(request.totalUsd)}) para ${request.code} · Ref. ${pagoAbierto.reference ?? '—'}.`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              La solicitud pasará a estado «Pagado» lista para comprar en Amazon, y se enviará la
              confirmación al médico.
            </p>
          }
          reasonLabel="Nota interna (opcional)"
          reasonPlaceholder="Verificado en cuenta BNC"
          motivoMinimo={0}
          confirmLabel="Aprobar pago"
          busy={aprobarPago.isPending}
          error={
            aprobarPago.isError
              ? explicarErrorDeAprobacion(
                  aprobarPago.error,
                  describeError(aprobarPago.error),
                  registradoPorMi,
                )
              : undefined
          }
          onConfirm={(nota) => aprobarPago.mutate(nota)}
          onClose={() => setDialogoPago(null)}
        />
      )}

      {dialogoPago === 'rechazar' && pagoAbierto && (
        <ConfirmDialog
          title="Rechazar pago reportado"
          summary={`Se rechazará el comprobante de ${formatVes(pagoAbierto.amountVes)} y la solicitud volverá a «Esperando pago».`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              El médico recibirá el motivo por WhatsApp (o en el Simulador) para que vuelva a
              reportar el pago.
            </p>
          }
          nivel="sensible"
          reasonLabel="Motivo del rechazo"
          reasonPlaceholder="La referencia no aparece acreditada en el banco"
          confirmLabel="Rechazar pago"
          danger
          busy={rechazarPago.isPending}
          error={rechazarPago.isError ? describeError(rechazarPago.error) : undefined}
          onConfirm={(nota) => rechazarPago.mutate(nota)}
          onClose={() => setDialogoPago(null)}
        />
      )}

      {dialogoPago === 'revision' && pagoAbierto && (
        <ConfirmDialog
          title="Marcar pago en revisión"
          summary={`El pago de ${request.code} queda apartado «En revisión» para seguimiento del equipo.`}
          nivel="sensible"
          reasonLabel="Nota para el equipo"
          reasonPlaceholder="Confirmar titular de la cuenta origen antes de aprobar"
          confirmLabel="Marcar en revisión"
          busy={ponerEnRevision.isPending}
          error={ponerEnRevision.isError ? describeError(ponerEnRevision.error) : undefined}
          onConfirm={(nota) => ponerEnRevision.mutate(nota)}
          onClose={() => setDialogoPago(null)}
        />
      )}

      {dialogoPago === 'duplicado' && pagoAbierto && (
        <ConfirmDialog
          title="Marcar pago como duplicado"
          summary={`Se cerrará este reporte como duplicado sin enviar mensaje de rechazo al médico.`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              Usa esta opción cuando el mismo pago ya fue reportado o conciliado en otro registro.
            </p>
          }
          nivel="sensible"
          reasonLabel="Por qué es duplicado"
          reasonPlaceholder="El médico reenvió la misma captura dos veces"
          confirmLabel="Marcar como duplicado"
          busy={marcarDuplicado.isPending}
          error={marcarDuplicado.isError ? describeError(marcarDuplicado.error) : undefined}
          onConfirm={(nota) => marcarDuplicado.mutate(nota)}
          onClose={() => setDialogoPago(null)}
        />
      )}

      {/* Modal para avanzar logística */}
      {pasoLogistica && (
        <Modal
          title={pasoLogistica.label}
          width="sm"
          onClose={() => setPasoLogistica(null)}
        >
          <div className="flex flex-col gap-4">
            <p className="type-panel-body text-on-surface-variant">
              Actualiza el estado de <span className="font-mono text-on-surface">{request.code}</span>{' '}
              y notifica al médico el progreso del pedido.
            </p>

            {pasoLogistica.requiereAmazonOrderId && (
              <Input
                id="logistica-amazon-order"
                label="Número de orden en Amazon"
                value={amazonOrderId}
                onChange={setAmazonOrderId}
                placeholder="114-3941689-8772232"
                autoComplete="off"
              />
            )}

            {pasoLogistica.requiereUsTracking && (
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
              value={notaLogistica}
              onChange={setNotaLogistica}
              rows={2}
              placeholder="Ej: Despachado en vuelo del viernes, estimado 5 días"
            />

            {avanzarLogistica.isError && (
              <ErrorBox
                title="No se pudo actualizar el estado"
                detail={describeError(avanzarLogistica.error)}
              />
            )}

            <div className="flex flex-wrap gap-2">
              <Button
                size="md"
                disabled={
                  avanzarLogistica.isPending ||
                  (pasoLogistica.requiereAmazonOrderId === true && amazonOrderId.trim().length < 4) ||
                  (pasoLogistica.requiereUsTracking === true && usTrackingNumber.trim().length < 4)
                }
                motivoApagado={
                  pasoLogistica.requiereAmazonOrderId && amazonOrderId.trim().length < 4
                    ? 'Escribe el ID de la orden de Amazon.'
                    : pasoLogistica.requiereUsTracking && usTrackingNumber.trim().length < 4
                      ? 'Escribe el número de rastreo USA.'
                      : undefined
                }
                onClick={() => avanzarLogistica.mutate()}
              >
                {avanzarLogistica.isPending ? 'Guardando…' : 'Confirmar avance'}
              </Button>
              <Button size="md" variant="text" onClick={() => setPasoLogistica(null)}>
                Cancelar
              </Button>
            </div>
          </div>
        </Modal>
      )}
    </>
  )
}

// ── Modal: Registrar pago manual ───────────────────────────────────────────

function ModalRegistrarPagoManual({
  request,
  onClose,
  onRegistrado,
}: {
  request: SolicitudCompraResumen
  onClose: () => void
  onRegistrado: () => void
}) {
  const hoy = diaOperativo()
  const [metodo, setMetodo] = useState<MetodoPagoCompra>('pago_movil')
  const [banco, setBanco] = useState('')
  const [referencia, setReferencia] = useState('')
  const [pagadoEl, setPagadoEl] = useState(hoy)
  const [telefonoPagador, setTelefonoPagador] = useState(request.phone)
  const [montoBs, setMontoBs] = useState('')
  const [archivo, setArchivo] = useState<File | null>(null)
  const [nota, setNota] = useState('')

  const fechaValida = pagadoEl !== '' && pagadoEl <= hoy

  const prevision = useQuery({
    ...consultaPrevisionPagoCompra(request.id, pagadoEl),
    enabled: fechaValida,
    placeholderData: keepPreviousData,
  })

  const escritoBs = leerMonto(montoBs)
  const esperadoBs = prevision.data?.expectedVes ?? null
  const tasa = prevision.data?.fxRate ?? null
  const diferencia = diferenciaEnBs(escritoBs, esperadoBs, tasa, MARGEN_POR_DEFECTO)

  const faltan: string[] = []
  if (!banco) faltan.push('Elige el banco de origen.')
  if (referencia.trim().length < 4) faltan.push('Escribe la referencia del comprobante.')
  if (!fechaValida) faltan.push('La fecha no puede ser futura.')
  if (escritoBs === null || escritoBs <= 0) faltan.push('Escribe el monto en bolívares.')
  const errArchivo = archivo ? motivoDeArchivo(archivo) : null
  if (errArchivo) faltan.push(errArchivo)

  const registrar = useMutation({
    mutationFn: async () => {
      const ruta = archivo
        ? await subirComprobanteCompra({ requestId: request.id, file: archivo })
        : null
      return registrarPagoCompra({
        requestId: request.id,
        method: metodo,
        bank: banco,
        reference: referencia,
        paidOn: pagadoEl,
        amountVes: escritoBs ?? 0,
        receiptPath: ruta,
        payerPhone: telefonoPagador,
        note: nota,
      })
    },
    onSuccess: onRegistrado,
  })

  return (
    <Modal title={`Registrar pago manual · ${request.code}`} width="lg" onClose={onClose}>
      <div className="flex flex-col gap-4">
        <div className="rounded-panel-control border border-panel-hairline bg-panel-raised p-4">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <span className="type-panel-body text-on-surface-variant">
              Total de la solicitud
            </span>
            <span className="type-panel-section tabular-nums text-on-surface">
              {formatUsd(request.totalUsd)}
            </span>
          </div>
          {prevision.isPending ? (
            <p className="mt-1 type-panel-caption text-on-surface-variant">
              Consultando tasa BCV del {formatDay(pagadoEl)}…
            </p>
          ) : prevision.isError ? (
            <p className="mt-1 type-panel-caption text-warning">
              No se pudo precalcular el monto en Bs; el servidor usará la tasa BCV vigente.
            </p>
          ) : esperadoBs !== null && tasa !== null ? (
            <p className="mt-1 type-panel-caption text-on-surface-variant">
              Esperado al {formatDay(pagadoEl)}:{' '}
              <span className="font-semibold text-on-surface">{formatVes(esperadoBs)}</span> (
              {formatBcvRate(tasa)}).
            </p>
          ) : (
            <p className="mt-1 type-panel-caption text-warning">
              No hay tasa BCV cargada para el {formatDay(pagadoEl)}.
            </p>
          )}
        </div>

        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <Select
            id="compra-pago-metodo"
            label="Medio de pago (bolívares)"
            value={metodo}
            options={METODOS_PAGO_COMPRA}
            onChange={setMetodo}
          />
          <Select
            id="compra-pago-banco"
            label="Banco origen"
            value={banco}
            placeholder="Elige el banco"
            options={BANKS.map((b) => ({ value: b.name, label: b.name }))}
            onChange={setBanco}
          />
          <Input
            id="compra-pago-referencia"
            label="Referencia"
            value={referencia}
            onChange={setReferencia}
            placeholder="Últimos 6–8 dígitos del comprobante"
            autoComplete="off"
          />
          <Input
            id="compra-pago-fecha"
            label="Fecha del pago"
            type="date"
            value={pagadoEl}
            onChange={setPagadoEl}
            max={hoy}
          />
          <Input
            id="compra-pago-monto"
            label="Monto en bolívares"
            value={montoBs}
            onChange={setMontoBs}
            inputMode="decimal"
            placeholder={esperadoBs !== null ? formatVes(esperadoBs) : 'Bs'}
            hint={
              diferencia === null
                ? undefined
                : diferencia.cuadra
                  ? `Dentro del margen (−10 / +100 Bs): diferencia ${diferencia.bs >= 0 ? '+' : '−'}${formatVes(Math.abs(diferencia.bs))}.`
                  : `Fuera del margen: diferencia ${diferencia.bs >= 0 ? '+' : '−'}${formatVes(Math.abs(diferencia.bs))} (≈ ${formatUsd(Math.abs(diferencia.usd))}).`
            }
            error={diferencia !== null && !diferencia.cuadra}
          />
          <Input
            id="compra-pago-telefono"
            label="Teléfono del pagador (opcional)"
            value={telefonoPagador}
            onChange={setTelefonoPagador}
            placeholder="0414-1234567"
            inputMode="tel"
          />
        </div>

        <AdjuntarComprobante id="compra-pago-captura" file={archivo} onChange={setArchivo} />

        <Textarea
          id="compra-pago-nota"
          label="Nota (opcional)"
          value={nota}
          onChange={setNota}
          rows={2}
          maxLength={300}
          placeholder="Comprobante recibido por WhatsApp del Dr."
        />

        {registrar.isError && (
          <ErrorBox
            title="No se pudo registrar el pago"
            detail={describeError(registrar.error)}
          />
        )}

        <div className="flex flex-wrap gap-2">
          <Button
            size="md"
            disabled={faltan.length > 0 || registrar.isPending}
            motivoApagado={faltan[0]}
            onClick={() => registrar.mutate()}
          >
            {registrar.isPending ? 'Registrando…' : 'Registrar pago'}
          </Button>
          <Button size="md" variant="text" onClick={onClose}>
            Cancelar
          </Button>
        </div>
      </div>
    </Modal>
  )
}

// ── Pequeños auxiliares de presentación ────────────────────────────────────

function FilaFinanciera({
  rotulo,
  valor,
  fuerte = false,
}: {
  rotulo: string
  valor: string
  fuerte?: boolean
}) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <span className="type-panel-body text-on-surface-variant">{rotulo}</span>
      <span
        className={`tabular-nums text-on-surface ${
          fuerte ? 'type-panel-section' : 'type-panel-body font-semibold'
        }`}
      >
        {valor}
      </span>
    </div>
  )
}

function Dato({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0">
      <dt className="type-panel-label text-on-surface-variant">{label}</dt>
      <dd
        className={`mt-0.5 type-panel-body text-on-surface [overflow-wrap:anywhere] ${
          mono ? 'font-mono tracking-wider' : ''
        }`}
      >
        {value}
      </dd>
    </div>
  )
}
