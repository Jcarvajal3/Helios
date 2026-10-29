import { useEffect } from 'react'
import { Link, createFileRoute } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Mail } from 'lucide-react'

import { usePageTitle } from '@/components/layouts/PageAction'
import { ConfirmacionDelPaciente } from '@/components/registrar/ConfirmacionDelPaciente'
import { DesgloseDelServicio } from '@/components/registrar/PlanDePagos'
import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Callout,
  Card,
  DataLabel,
  ErrorBox,
  SectionTitle,
  SkeletonList,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatDay,
  formatMoneda,
  formatTime,
  formatUsd,
} from '@/components/ui'
import { canSee } from '@/features/auth/permissions'
import { useStaff } from '@/features/auth/session'
import { ESTADO_DEL_FINANCIAMIENTO, ESTADO_DEL_PAGO } from '@/features/merchant/financiamientos'
import type { DetalleDeFinanciamiento } from '@/features/merchant/financiamientos'
import { fetchDetalle } from '@/features/merchant/financiamientosApi'
import {
  COMPROBANTE,
  DE_LA_MONEDA,
  diaDeLaSemana,
  esperaAlPaciente,
} from '@/features/merchant/registro'
import type { EstadoDelComprobante } from '@/features/merchant/registro'
import { fetchFinanciamiento, reenviarComprobante } from '@/features/merchant/registroApi'
import { describeError } from '@/lib/supabase'

/**
 * LA FICHA DE UN PAGO EN CUOTAS, para la clínica.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Lo que se viene a mirar cuando alguien pregunta por la orden 1043:
 *
 *   1. Qué se registró: la consulta, a quién, quién lo registró y su
 *      comisión, con la Comisión Helios en su propia línea (nunca sumada).
 *      La consulta, en la moneda en que se cobró (dólares o euros); la
 *      comisión del personal, siempre en dólares.
 *   2. El comprobante: si le llegó al paciente, y «Reenviar» si dice que no.
 *   3. Cuándo te pagamos: el día de pago de cada mitad (el siguiente al
 *      vencimiento de su cuota).
 *
 * Lo que NO está, y no es un olvido: **el estado de pago de las cuotas del
 * paciente**. A la clínica se le paga por fecha, haya pagado el
 * paciente o no; un «en mora» aquí se leería como «esto no me lo van a
 * pagar», que es justo lo contrario de lo que pasa (plan §8.2).
 */
export const Route = createFileRoute('/_comercio/financiamientos_/$id')({
  staticData: { title: 'Pago en cuotas' },
  component: FinanciamientoRoute,
})

function FinanciamientoRoute() {
  const { id } = Route.useParams()
  const staff = useStaff()
  if (!staff) return null
  // La secretaria que solo registra no abre la ficha de una orden.
  if (!canSee(staff, 'financiamientos')) return null
  return <Ficha chargeId={id} />
}

function Ficha({ chargeId }: { chargeId: string }) {
  const query = useQuery({
    queryKey: ['merchant-order', chargeId],
    queryFn: () => fetchDetalle(chargeId),
  })

  usePageTitle(query.data ? `Orden #${query.data.orderNumber}` : null)

  return (
    <>
      <Link
        to="/financiamientos"
        className="mb-4 inline-flex items-center gap-1 type-panel-control text-on-surface-variant hover:text-on-surface max-sm:mb-2 max-sm:min-h-11"
      >
        <ArrowLeft size={14} aria-hidden /> Pagos en cuotas
      </Link>

      {query.isLoading && <SkeletonList rows={3} />}

      {query.isError && (
        <ErrorBox title="No pudimos abrir este pago en cuotas" detail={describeError(query.error)} />
      )}

      {query.data && (
        <div className="flex flex-col gap-6">
          <Resumen f={query.data} />
          {query.data.status === 'confirmed' || query.data.status === 'reverted' ? (
            <Comprobante f={query.data} />
          ) : (
            <RespuestaDelPaciente chargeId={query.data.id} />
          )}
          {query.data.pagos.length > 0 && <CuandoTePagamos f={query.data} />}
        </div>
      )}
    </>
  )
}

// ── 0. La respuesta del paciente (mientras no está confirmado) ────────────

/**
 * Una orden que espera el Sí del paciente, que rechazó o que venció (contrato
 * §1.3.1): cómo va la pregunta por WhatsApp y «Reenviar al paciente». Se
 * vuelve a pedir cada pocos segundos mientras espera; cuando cambia, la ficha
 * entera se recarga (si aceptó, ya es un pago en cuotas con su comprobante).
 */
function RespuestaDelPaciente({ chargeId }: { chargeId: string }) {
  const queryClient = useQueryClient()
  const orden = useQuery({
    queryKey: ['financiamiento', chargeId],
    queryFn: () => fetchFinanciamiento(chargeId),
    refetchInterval: (q) => (q.state.data && esperaAlPaciente(q.state.data) ? 4_000 : false),
  })

  const status = orden.data?.status
  useEffect(() => {
    if (status && status !== 'pending') {
      void queryClient.invalidateQueries({ queryKey: ['merchant-order', chargeId] })
    }
  }, [status, chargeId, queryClient])

  if (orden.isError) {
    return <ErrorBox title="No pudimos ver la respuesta del paciente" detail={describeError(orden.error)} />
  }
  if (!orden.data) return <SkeletonList rows={1} />

  return (
    <section className="flex flex-col gap-3">
      <SectionTitle>La respuesta del paciente</SectionTitle>
      <ConfirmacionDelPaciente
        financiamiento={orden.data}
        onCambio={(nuevo) => queryClient.setQueryData(['financiamiento', chargeId], nuevo)}
      />
    </section>
  )
}

// ── 1. Qué se registró ────────────────────────────────────────────────────

function Resumen({ f }: { f: DetalleDeFinanciamiento }) {
  const estado = ESTADO_DEL_FINANCIAMIENTO[f.status]
  const cuando = f.confirmedAt ?? f.createdAt

  return (
    <Card variant="hero" className="flex flex-col gap-5">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={estado.tone} icono>
          {estado.texto}
        </Badge>
        {f.isTest && <Badge tone="neutral">Prueba</Badge>}
        <span className="type-panel-caption text-panel-muted">Orden #{f.orderNumber}</span>
      </div>

      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <DataLabel>{f.concept ?? 'Consulta'} · lo que cobra la clínica</DataLabel>
          <p className="mt-1 type-panel-hero tabular-nums text-on-surface">
            {formatMoneda(f.merchantSaleCur, f.moneda)}
          </p>
          <p className="mt-1 type-panel-body text-on-surface">
            {f.patientName ?? <span className="text-on-surface-variant">Sin nombre</span>}
          </p>
          {f.beneficiaryName && (
            <p className="type-panel-body text-on-surface-variant">
              Paciente atendido: {f.beneficiaryName}
            </p>
          )}
        </div>

        <div className="sm:text-right">
          <p className="type-panel-body text-on-surface">
            {f.businessDate ? formatDay(f.businessDate) : '—'} · {formatTime(cuando)}
          </p>
          <p className="type-panel-caption text-panel-muted">
            {f.branchName ?? 'Sin sede'}
            {f.registeredBy && ` · registró ${f.registeredBy}`}
          </p>
        </div>
      </div>

      <DesgloseDelServicio
        base={f.merchantSaleCur}
        feePct={f.feePct}
        fee={f.feeCur}
        feeVat={f.feeVatCur}
        moneda={f.moneda}
        concepto={f.concept}
      />

      {f.staffCommissionUsd !== null && (
        <div className="flex items-baseline justify-between gap-4 rounded-panel-card bg-panel-raised px-4 py-3 type-panel-body">
          <span className="text-on-surface-variant">
            Comisión de {f.commissionStaffName ?? f.registeredBy ?? 'quien lo registró'}
            <span className="block type-panel-caption text-panel-muted">
              Se paga el día siguiente a que el paciente confirma, en la transferencia de ese
              día a la clínica, aparte de la consulta.
            </span>
          </span>
          <span className="tabular-nums text-on-surface">{formatUsd(f.staffCommissionUsd)}</span>
        </div>
      )}

      {f.voidReason && (
        <p className="rounded-panel-control bg-panel-control p-3 type-panel-body italic text-on-surface-variant">
          {f.voidReason}
        </p>
      )}
    </Card>
  )
}

// ── 2. El comprobante ─────────────────────────────────────────────────────

/**
 * Lo que se dice del comprobante en la ficha. Distinto de la pantalla de
 * éxito: aquí puede hacer días del alta, y «en camino» ya no es cierto.
 */
const FRASE_DE_LA_FICHA: Record<EstadoDelComprobante | 'desconocido', string> = {
  pendiente: 'El comprobante está en la cola de envío.',
  enviado: 'El comprobante se envió al correo del paciente.',
  entregado: 'El comprobante llegó al correo del paciente.',
  rebotado: 'El comprobante no llegó: el correo rebotó.',
  sin_configurar:
    'El envío de correos de Helios todavía no está configurado: el comprobante saldrá en cuanto lo esté.',
  sin_enviar: 'El comprobante sale en cuanto el paciente acepte.',
  desconocido: 'Sin datos del comprobante.',
}

/**
 * Si al paciente le llegó el correo con sus cuotas, y el botón para
 * mandarlo otra vez. Va al correo REGISTRADO: si está mal, lo corrige
 * Helios, no la clínica (plan §7.3). La base limita los reenvíos por día.
 */
function Comprobante({ f }: { f: DetalleDeFinanciamiento }) {
  const avisar = useToast()
  const queryClient = useQueryClient()

  const reenvio = useMutation({
    mutationFn: () => reenviarComprobante(f.id),
    onSuccess: (r) => {
      avisar(`Comprobante reenviado${r.emailEnmascarado ? ` a ${r.emailEnmascarado}` : ''}`)
      void queryClient.invalidateQueries({ queryKey: ['merchant-order', f.id] })
      void queryClient.invalidateQueries({ queryKey: ['merchant-transactions'] })
    },
  })

  const estado = f.receipt?.status ?? null
  const puedeReenviar = f.status === 'confirmed' && estado !== 'sin_configurar'

  return (
    <section className="flex flex-col gap-3">
      <SectionTitle>Comprobante del paciente</SectionTitle>

      {estado === 'rebotado' && (
        <Callout tone="error" titulo="El correo del paciente no es válido">
          El comprobante rebotó: el paciente no lo recibió. Pídele un correo que funcione y
          avisa a Helios para corregirlo; después reenvíalo desde aquí.
        </Callout>
      )}

      <Card className="flex flex-wrap items-center gap-3">
        <Mail size={20} aria-hidden className="shrink-0 text-on-surface-variant" />
        <div className="min-w-0 flex-1 basis-60">
          <p className="type-panel-body text-on-surface">
            {FRASE_DE_LA_FICHA[estado ?? 'desconocido']}
          </p>
          {f.receipt?.sentAt && (
            <p className="type-panel-caption text-panel-muted">
              Enviado el {formatDateTime(f.receipt.sentAt)}
              {f.receipt.lastEvent && ` · último aviso del correo: ${f.receipt.lastEvent}`}
            </p>
          )}
        </div>
        {estado && (
          <Badge tone={COMPROBANTE[estado].tone} icono>
            {COMPROBANTE[estado].texto}
          </Badge>
        )}
        {puedeReenviar && (
          <Button
            size="sm"
            variant="tonal"
            disabled={reenvio.isPending}
            onClick={() => reenvio.mutate()}
          >
            {reenvio.isPending ? 'Reenviando…' : 'Reenviar comprobante'}
          </Button>
        )}
      </Card>

      {reenvio.isError && (
        <ErrorBox title="No se pudo reenviar el comprobante" detail={describeError(reenvio.error)} />
      )}
    </section>
  )
}

// ── 3. Cuándo te pagamos ──────────────────────────────────────────────────

/**
 * Las dos mitades: el vencimiento de cada cuota del paciente (solo la fecha)
 * y el día en que se le paga a la clínica (el siguiente al vencimiento; lo
 * calcula la base con `helios_settlement_run_for`). El importe y el estado
 * de la transferencia son del administrador; la base los manda vacíos a una
 * secretaria.
 */
function CuandoTePagamos({ f }: { f: DetalleDeFinanciamiento }) {
  const conImportes = f.isGerente

  return (
    <section>
      <SectionTitle className="mb-3">Cuándo te pagamos</SectionTitle>
      <Table
        apilada
        headers={
          conImportes
            ? ['Mitad', 'Vence la cuota', 'Te pagamos el', 'Importe', 'Transferencia']
            : ['Mitad', 'Vence la cuota', 'Te pagamos el']
        }
      >
        {f.pagos.map((p, i) => {
          const estado = p.status ? ESTADO_DEL_PAGO[p.status] : null
          return (
            <Tr key={`${p.sequence ?? i}-${p.dueDate}`}>
              <Td className="whitespace-nowrap">{p.sequence ?? i + 1} de 2</Td>
              <Td className="whitespace-nowrap text-on-surface-variant">{formatDay(p.dueDate)}</Td>
              <Td className="whitespace-nowrap font-semibold">
                {diaDeLaSemana(p.paidToMerchantOn)} {formatDay(p.paidToMerchantOn)}
              </Td>
              {conImportes && (
                <>
                  <Td className="whitespace-nowrap tabular-nums">
                    {p.amountCur === null ? (
                      <span className="text-on-surface-variant">Se calcula al vencer</span>
                    ) : (
                      <>
                        {formatMoneda(p.amountCur, p.moneda)}
                        {p.status === 'partial' && p.paidCur !== null && (
                          <span className="block type-panel-caption text-panel-muted">
                            {formatMoneda(p.paidCur, p.moneda)} transferidos
                          </span>
                        )}
                      </>
                    )}
                  </Td>
                  <Td>
                    {estado ? (
                      <Badge tone={estado.tone}>{estado.texto}</Badge>
                    ) : (
                      <span className="text-on-surface-variant">—</span>
                    )}
                  </Td>
                </>
              )}
            </Tr>
          )
        })}
      </Table>
      <p className="mt-4 type-panel-caption leading-5 text-panel-muted">
        Helios te paga cada mitad el día siguiente al vencimiento de su cuota (a los 8 y a los
        15 días de la consulta), <strong>haya pagado o no tu paciente</strong>: cobrarle es cosa
        de Helios. Te lo pagamos en bolívares a la tasa BCV {DE_LA_MONEDA[f.moneda]}.
      </p>
    </section>
  )
}
