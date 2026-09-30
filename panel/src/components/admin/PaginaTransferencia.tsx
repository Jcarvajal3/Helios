import { useState } from 'react'
import type { ReactNode } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { FileText, Landmark } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { CabeceraDeFicha, MarcoDeFicha, ResumenDeFicha, VolverA } from '@/components/admin/ficha'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import {
  Badge,
  Button,
  Callout,
  Card,
  DataLabel,
  IconoDeArea,
  Seccion,
  SkeletonList,
  claseDeBoton,
  formatBcvRate,
  formatDateTime,
  formatDay,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { fetchPayoutDetail, payoutReceiptUrl } from '@/features/admin/api'
import type { PayoutItem } from '@/features/admin/api'
import { MOTIVO_DE_LIQUIDACION, nombreDelMedio } from '@/features/admin/liquidaciones'
import { csvDinero } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

/**
 * La página de una transferencia a un local.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Contesta las tres preguntas que llegan cuando alguien reclama un pago:
 *
 *   ¿Cuándo salió y por dónde?   la fecha del banco (que no es la del
 *                                registro), el medio y la referencia.
 *   ¿Qué cubrió?                 la liquidación y de qué consumo venía, con lo
 *                                APLICADO a cada una, que en un pago parcial
 *                                no es su monto.
 *   ¿Quién la registró?          y con qué papel detrás, en el carril.
 *
 * «← volver» regresa de donde se vino: la página del local o el histórico.
 */
export function PaginaTransferencia({
  payoutId,
  desdeElLocal,
}: {
  payoutId: string
  desdeElLocal: boolean
}) {
  const query = useQuery({
    queryKey: ['payout', payoutId],
    queryFn: () => fetchPayoutDetail(payoutId),
  })

  const payout = query.data

  return (
    <>
      {desdeElLocal && payout ? (
        <VolverA link={{ to: '/admin/pagos-clinicas/$id', params: { id: payout.merchant.id } }}>
          Pagos a {payout.merchant.name}
        </VolverA>
      ) : (
        <VolverA link={{ to: '/admin/pagos-clinicas', search: { vista: 'pagos' } }}>
          Transferencias a clínicas
        </VolverA>
      )}

      {query.isPending && <SkeletonList rows={3} />}

      {query.isError && (
        <SeccionSinLeer
          titulo="No se pudo abrir la transferencia"
          error={query.error}
          onReintentar={() => void query.refetch()}
        />
      )}

      {payout && (
        <MarcoDeFicha
          cabecera={
            <CabeceraDeFicha
              identidad={<IconoDeArea icon={Landmark} tamano="md" />}
              nombre={
                <Link to="/admin/clinicas/$id" params={{ id: payout.merchant.id }} className="hover:underline">
                  {payout.merchant.name}
                </Link>
              }
              insignias={payout.merchant.isTest && <Badge>Prueba</Badge>}
              datos={[
                `Salió del banco el ${formatDay(payout.paidOn)}`,
                `por ${nombreDelMedio(payout.method)}`,
                payout.reference ? `referencia ${payout.reference}` : null,
              ]}
              acciones={
                <Link
                  to="/admin/pagos-clinicas/$id"
                  params={{ id: payout.merchant.id }}
                  className={`whitespace-nowrap ${claseDeBoton('tonal', 'sm')}`}
                >
                  Ver sus pagos
                </Link>
              }
            />
          }
          carril={
            <>
              <ResumenDeFicha
                cifras={[
                  {
                    label: 'Transferido',
                    value: formatUsd(payout.amountUsd),
                    hint:
                      payout.amountVes != null
                        ? `${formatVes(payout.amountVes)}${
                            payout.fxRate != null ? ` a ${formatBcvRate(payout.fxRate)}` : ''
                          }`
                        : undefined,
                  },
                ]}
              />
              <Card as="section" className="flex flex-col gap-4">
                <h2 className="type-panel-label text-on-surface-variant">El registro</h2>
                <Dato label="Registrada">
                  {formatDateTime(payout.createdAt)}
                  <span className="block type-panel-caption text-panel-muted">
                    Día operativo {formatDay(payout.businessDate)}
                  </span>
                </Dato>
                <Dato label="Quién la registró">{payout.actorName ?? '—'}</Dato>
                <Dato label="Comprobante">
                  <Comprobante path={payout.receiptPath} />
                </Dato>
              </Card>
            </>
          }
        >
          {payout.note && (
            <Callout tone="info" titulo="Nota del registro">
              {payout.note}
            </Callout>
          )}
          <LoQueCubrio items={payout.items} payoutId={payout.id} />
        </MarcoDeFicha>
      )}
    </>
  )
}

function Dato({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <DataLabel>{label}</DataLabel>
      <div className="mt-shell-gap-stack type-panel-body text-on-surface">{children}</div>
    </div>
  )
}

/**
 * El papel del banco. Vive en un bucket privado (lleva datos bancarios de un
 * tercero), así que se pide un enlace firmado al abrirlo, que caduca en diez
 * minutos. Por eso es un botón y no un enlace.
 */
function Comprobante({ path }: { path: string | null }) {
  const [abriendo, setAbriendo] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!path) return <span className="text-on-surface-variant">Sin comprobante</span>

  return (
    <>
      <Button
        variant="tonal"
        size="sm"
        disabled={abriendo}
        onClick={async () => {
          setAbriendo(true)
          setError(null)
          try {
            const url = await payoutReceiptUrl(path)
            window.open(url, '_blank', 'noopener,noreferrer')
          } catch (e) {
            setError(describeError(e) ?? 'No se pudo abrir el comprobante')
          } finally {
            setAbriendo(false)
          }
        }}
      >
        <FileText size={16} aria-hidden />
        {abriendo ? 'Abriendo…' : 'Abrir'}
      </Button>
      {error && <span className="block type-panel-caption text-error">{error}</span>}
    </>
  )
}

/**
 * Las liquidaciones que cubrió el pago.
 *
 * «Aplicado» y «La liquidación» son dos columnas y no una: con un pago parcial
 * el pago cubre una parte y la liquidación sigue viva por el resto.
 */
function LoQueCubrio({ items, payoutId }: { items: PayoutItem[]; payoutId: string }) {
  const navigate = useNavigate()
  const aplicado = items.reduce((sum, i) => sum + i.appliedUsd, 0)

  return (
    <Seccion
      titulo="Qué cubrió"
      info="Las liquidaciones que cubrió el pago, con lo aplicado a cada una: en un pago parcial no es su monto. Cada fila abre el financiamiento del que venía."
    >
      {items.length === 0 ? (
        <p className="type-panel-body text-on-surface-variant">
          Esta transferencia no tiene liquidaciones asociadas.
        </p>
      ) : (
        <DataTable
          rows={items}
          rowKey={(i) => i.settlementId}
          columns={COLUMNAS_CUBRIO}
          noun={['liquidación', 'liquidaciones']}
          summary={`${formatUsd(aplicado)} aplicados`}
          exportar={{ archivo: `transferencia-${payoutId}` }}
          onRowClick={(item) => {
            if (item.chargeId) {
              void navigate({ to: '/admin/financiamientos/$id', params: { id: item.chargeId } })
            }
          }}
        />
      )}
    </Seccion>
  )
}

const COLUMNAS_CUBRIO: Array<Column<PayoutItem>> = [
  {
    key: 'consumo',
    header: 'Financiamiento',
    identity: true,
    sort: (i) => i.orderNumber,
    csv: (i) => i.orderNumber,
    cell: (i) => (
      <span className="block font-medium">
        {i.orderNumber != null ? `#${i.orderNumber}` : '—'}
        {i.chargeDate && (
          <span className="block type-panel-caption font-normal text-on-surface-variant">
            {formatDay(i.chargeDate)}
          </span>
        )}
      </span>
    ),
  },
  {
    key: 'origen',
    header: 'Origen',
    sort: (i) => i.reason,
    csv: (i) => MOTIVO_DE_LIQUIDACION[i.reason],
    cell: (i) => <span className="text-on-surface-variant">{MOTIVO_DE_LIQUIDACION[i.reason]}</span>,
  },
  {
    key: 'vencia',
    header: 'Vencía',
    sort: (i) => i.dueDate,
    csv: (i) => i.dueDate,
    cell: (i) => <span className="whitespace-nowrap">{formatDay(i.dueDate)}</span>,
  },
  {
    key: 'cierre',
    header: 'Cierre',
    sort: (i) => i.runDate,
    csv: (i) => i.runDate,
    cell: (i) => <span className="whitespace-nowrap text-on-surface-variant">{formatDay(i.runDate)}</span>,
  },
  {
    key: 'aplicado',
    header: 'Aplicado',
    type: 'number',
    sort: (i) => i.appliedUsd,
    csv: (i) => csvDinero(i.appliedUsd),
    cell: (i) => <span className="font-semibold">{formatUsd(i.appliedUsd)}</span>,
  },
  {
    key: 'liquidacion',
    header: 'La liquidación',
    type: 'number',
    sort: (i) => i.settlementUsd,
    csv: (i) => csvDinero(i.settlementUsd),
    cell: (i) => (
      <span className="text-on-surface-variant">
        {formatUsd(i.settlementUsd)}
        {i.pendingUsd > 0.005 && (
          <span className="block type-panel-caption text-warning">quedan {formatUsd(i.pendingUsd)}</span>
        )}
      </span>
    ),
  },
]
