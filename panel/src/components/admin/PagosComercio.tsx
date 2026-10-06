import { Link, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { Badge, ErrorBox, SkeletonList, estadoDeConsulta, formatDay, formatUsd } from '@/components/ui'
import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { CabeceraDeFicha, MarcoDeFicha, ResumenDeFicha, VolverA } from '@/components/admin/ficha'
import { LogoLocal } from '@/components/admin/directorio/LogoLocal'
import { LiquidacionesDelLocal } from '@/components/admin/caja/LiquidacionesDelLocal'
import { TransferenciasDelLocal } from '@/components/admin/caja/TransferenciasDelLocal'
import { fetchMerchantPayables, fetchMerchants } from '@/features/admin/api'
import { comprometidoFuturoDe } from '@/features/admin/definitions'
import { describeError } from '@/lib/supabase'

/**
 * La página de pagos de un local.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Tres bloques, en el orden de la conversación cuando llama el gerente:
 *
 *   1. Cuánto se le debe        las tres cifras que pregunta, en el carril.
 *   2. Por qué                  las liquidaciones por día de pago, y desde
 *                               aquí se le paga (`LiquidacionesDelLocal`).
 *   3. Qué se le ha pagado      el histórico de transferencias.
 */
export function PaginaPagosComercio({
  merchantId,
  cierre,
}: {
  merchantId: string
  /** Día de pago del que se viene, si se entró desde uno concreto. */
  cierre: string | null
}) {
  const navigate = useNavigate()
  const merchants = useQuery({ queryKey: ['merchants'], queryFn: fetchMerchants })
  const payables = useQuery({
    queryKey: ['merchant-payables'],
    queryFn: fetchMerchantPayables,
  })

  const merchant = merchants.data?.find((m) => m.id === merchantId) ?? null
  const payable = payables.data?.find((p) => p.merchantId === merchantId) ?? null
  // Un local sin fila en la previsión no debe nada: ahí el cero sí es un dato.
  const estado = estadoDeConsulta(payables)
  const reintentar = () => void payables.refetch()

  // `nextRunUsd` ya lleva dentro lo atrasado: no se resta dos veces.
  const futuro = payable ? comprometidoFuturoDe(payable) : 0
  const atrasado = payable?.overdueUsd ?? 0

  return (
    <>
      <VolverA link={{ to: '/admin/pagos-clinicas', search: cierre ? { cierre } : {} }}>
        Pagos a clínicas
      </VolverA>

      {merchants.isPending && <SkeletonList rows={2} />}

      {merchants.isError && (
        <ErrorBox title="No se pudo leer la clínica" detail={describeError(merchants.error)} />
      )}

      {merchants.data && !merchant && (
        <ErrorBox
          title="Esta clínica no existe"
          detail="Puede que el enlace sea viejo o que el identificador esté mal escrito."
        />
      )}

      {merchant && (
        <MarcoDeFicha
          cabecera={
            <CabeceraDeFicha
              identidad={<LogoLocal name={merchant.name} logoUrl={merchant.logoUrl} size="lg" />}
              nombre={
                <Link to="/admin/clinicas/$id" params={{ id: merchantId }} className="hover:underline">
                  {merchant.name}
                </Link>
              }
              insignias={
                <>
                  {merchant.status !== 'active' && <EstadoBadge tipo="local" valor={merchant.status} />}
                  {merchant.isTest && <Badge>Prueba</Badge>}
                </>
              }
              datos={[merchant.taxId ?? 'Sin RIF']}
            >
              {merchant.isTest && (
                <p className="type-panel-caption text-panel-muted">
                  Es una clínica de prueba: su deuda es real, pero no suma en las cifras.
                </p>
              )}
            </CabeceraDeFicha>
          }
          carril={
            // Tres cifras y no una: mezclarlas es lo que hacía pagar de más.
            <ResumenDeFicha
              titulo="Lo que se le debe"
              cifras={[
                {
                  // Se paga a diario: el próximo pago es siempre hoy.
                  label: 'Sale hoy (con lo atrasado)',
                  info: 'Lo que hay que transferirle hoy: cada liquidación se paga el día siguiente a su vencimiento (la consulta, a los 8 y a los 15 días; la comisión de la secretaria, el día siguiente a la confirmación).',
                  value: formatUsd(payable?.nextRunUsd ?? 0),
                  hint: payable?.desglose
                    ? `Consultas ${formatUsd(payable.desglose.consultasUsd)} + Comisiones del personal ${formatUsd(payable.desglose.comisionesUsd)}`
                    : undefined,
                  estado,
                  onReintentar: reintentar,
                },
                {
                  label: 'De eso, de días anteriores',
                  info: 'Liquidaciones que tocaba pagar ayer o antes y siguen sin transferirse: es un atraso con la clínica. Ya va dentro de la cifra de al lado.',
                  value: formatUsd(atrasado),
                  senal: atrasado > 0 ? { tone: 'error', texto: 'Atrasado' } : undefined,
                  hint: payable?.oldestDueDate ? `Desde el ${formatDay(payable.oldestDueDate)}` : undefined,
                  estado,
                  onReintentar: reintentar,
                },
                {
                  label: 'Por pagar en los próximos días',
                  info: 'Lo que se le deberá después del pago de hoy: lo que vence hoy (sale mañana) y, sobre todo, cuotas de sus pacientes que todavía no vencen y aún no son liquidaciones. Hoy no toca pagarlo.',
                  value: formatUsd(futuro),
                  estado,
                  onReintentar: reintentar,
                },
              ]}
            />
          }
        >
          <LiquidacionesDelLocal
            merchantId={merchantId}
            merchantName={merchant.name}
            nextRunDate={payable?.nextRunDate ?? null}
            cierre={cierre}
            onVerTodos={() =>
              void navigate({ to: '/admin/pagos-clinicas/$id', params: { id: merchantId }, search: {} })
            }
          />
          <TransferenciasDelLocal merchantId={merchantId} merchantName={merchant.name} />
        </MarcoDeFicha>
      )}
    </>
  )
}
