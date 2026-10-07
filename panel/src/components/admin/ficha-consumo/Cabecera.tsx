import { Link } from '@tanstack/react-router'
import { Receipt, Store, User } from 'lucide-react'

import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { CabeceraDeFicha } from '@/components/admin/ficha'
import type { CifraDeFicha, HuecoDeMenu } from '@/components/admin/ficha'
import {
  Badge,
  Callout,
  Card,
  Divider,
  IconoDeArea,
  Seccion,
  formatDateTime,
  formatDay,
  formatMoneda,
  formatUsd,
  formatPhone,
} from '@/components/ui'
import type { ChargeDetail } from '@/features/admin/consumos'
import { redondear } from './comun'

/** El nombre del consumo: su número de orden, que es lo que se dicta al teléfono. */
export function nombreDelConsumo(detail: ChargeDetail): string {
  return detail.orderNumber === null
    ? `${formatUsd(detail.financedUsd)} (sin fee) en ${detail.merchant.name}`
    : `Orden #${detail.orderNumber}`
}

/**
 * «Cobrado en euros: €100,00 · tasa cruzada del registro 1,1263 $/€». `null`
 * en una orden en dólares, que es lo de siempre y no hace falta decirlo.
 *
 * Las cifras de la ficha siguen en dólares (el libro va en dólares); esto
 * dice lo que cobró de verdad el médico y con qué tasa se pasó a dólares el
 * día en que se registró.
 */
export function lineaDeLaMoneda(
  detail: Pick<ChargeDetail, 'currency' | 'baseCur' | 'amountCur' | 'fxUsdPerUnit'>,
): string | null {
  if (detail.currency !== 'EUR') return null
  const monto = detail.baseCur ?? detail.amountCur
  const partes = [
    `Cobrado en euros${monto === null ? '' : `: ${formatMoneda(monto, 'EUR')}`}`,
    detail.fxUsdPerUnit === null
      ? null
      : `tasa cruzada del registro ${detail.fxUsdPerUnit.toLocaleString('es-VE', {
          minimumFractionDigits: 4,
          maximumFractionDigits: 6,
        })} $/€`,
  ]
  return partes.filter(Boolean).join(' · ')
}

/**
 * Qué consumo es, de qué local y de quién. Anular o revertir va en el «⋯».
 *
 * El local va con su empresa y su RIF: con eso se reclama, el rótulo del
 * local no basta.
 */
export function Cabecera({ detail, menu }: { detail: ChargeDetail; menu: ReadonlyArray<HuecoDeMenu> }) {
  const empresa =
    detail.merchant.legalName && detail.merchant.legalName !== detail.merchant.name
      ? detail.merchant.legalName
      : null

  return (
    <CabeceraDeFicha
      identidad={<IconoDeArea icon={Receipt} tamano="md" />}
      nombre={nombreDelConsumo(detail)}
      insignias={
        <>
          <EstadoBadge tipo="consumo" valor={detail.status} />
          {detail.isTest && <Badge>Prueba</Badge>}
        </>
      }
      datos={[
        detail.businessDate ? `Día del ${formatDay(detail.businessDate)}` : null,
        lineaDeLaMoneda(detail),
        detail.branch?.name,
        `Generado el ${formatDateTime(detail.createdAt)}`,
        detail.confirmedAt ? `confirmado el ${formatDateTime(detail.confirmedAt)}` : null,
      ]}
      menu={menu}
    >
      <div className="flex flex-wrap gap-x-5 gap-y-1 type-panel-body">
        <Link
          to="/admin/clinicas/$id"
          params={{ id: detail.merchant.id }}
          className="inline-flex items-center gap-1.5 text-on-surface hover:underline"
        >
          <Store size={14} aria-hidden className="text-on-surface-variant" />
          {detail.merchant.name}
          <span className="text-on-surface-variant">
            {[empresa, detail.merchant.taxId ?? 'Sin RIF'].filter(Boolean).join(' · ')}
          </span>
        </Link>
        {detail.user ? (
          <Link
            to="/admin/pacientes/$id"
            params={{ id: detail.user.id }}
            className="inline-flex items-center gap-1.5 text-on-surface hover:underline"
          >
            <User size={14} aria-hidden className="text-on-surface-variant" />
            {detail.user.fullName ?? 'Sin nombre'}
            <span className="text-on-surface-variant">
              {formatPhone(detail.user.phone)}
            </span>
          </Link>
        ) : (
          <span className="text-on-surface-variant">Sin paciente asociado</span>
        )}
      </div>
    </CabeceraDeFicha>
  )
}

/**
 * Las cifras del carril: el consumo en el local, cómo se paga y lo que recibe
 * el local.
 *
 * La cifra grande es la que el cliente ve en su app y el cajero en su
 * comprobante: lo que cobró el local. El service fee NUNCA va sumado a
 * ella: va en su línea del desglose y repartido en las cuotas.
 */
export function cifrasDelConsumo(detail: ChargeDetail): Array<CifraDeFicha> {
  const cuotas = detail.installments
  const personas = new Set(cuotas.map((c) => c.userId ?? '')).size

  const comoSePaga: CifraDeFicha =
    cuotas.length === 0
      ? {
          label: 'Se paga en',
          value: 'Sin cuotas',
          hint:
            detail.status === 'reverted'
              ? 'Sus cuotas se borraron al revertirlo'
              : detail.status === 'confirmed'
                ? undefined
                : 'No llegó a confirmarse',
        }
      : {
          label: 'Se paga en',
          value: `${cuotas.length} ${cuotas.length === 1 ? 'cuota' : 'cuotas'}`,
          info: 'Cada cuota es financiamiento + service fee: lleva dentro su parte del fee, con su IVA; es lo que transfiere cada paciente.',
          // Sin los montos de las cuotas: dos cifras con el fee dentro no van
          // sueltas, y abajo ya están con su desglose.
          hint:
            personas === 1
              ? 'Financiamiento + fee cada una; el detalle, en «Las cuotas»'
              : `Repartidas entre ${personas} pacientes`,
        }

  return [
    {
      label: 'Financiamiento en la clínica (sin fee)',
      value: formatUsd(detail.financedUsd),
      info: 'Sin el service fee: lo que cobró la clínica, el monto de la consulta que figura en el comprobante.',
      hint: 'Se descuenta del saldo',
    },
    comoSePaga,
    ...(detail.merchantNetUsd === null
      ? []
      : [
          {
            label: 'Recibe la clínica',
            value: formatUsd(detail.merchantNetUsd),
            hint:
              detail.merchantFeeUsd !== null && detail.merchantFeeUsd > 0
                ? `El financiamiento menos la comisión de la clínica y su IVA, ${formatUsd(
                    detail.merchantFeeUsd + (detail.merchantFeeVatUsd ?? 0),
                  )}`
                : 'El financiamiento entero, sin comisión de la clínica',
          },
        ]),
  ]
}

/**
 * El desglose, como en el recibo de la app: el consumo y, en su línea, el
 * service fee con su IVA. Sin fila de total: la suma de las dos no es una
 * cifra que exista para nadie, porque el fee se paga repartido en las cuotas.
 */
export function Desglose({ detail }: { detail: ChargeDetail }) {
  const conIva = redondear(detail.amountUsd - detail.financedUsd)
  const fee = detail.consumerFeeUsd
  const iva = detail.consumerFeeVatUsd

  // El fee y su IVA por separado solo si SUMAN el fee con IVA. Si no cuadran
  // (un cobro anterior al desglose), una línea con el fee entero, que es
  // cierto siempre.
  const desglosado = fee !== null && iva !== null && Math.abs(fee + iva - conIva) < 0.005

  return (
    <Seccion titulo="El desglose">
      <Card className="flex flex-col gap-3">
        <dl className="flex flex-col gap-2 type-panel-body">
          <Linea label="Financiamiento en la clínica (sin fee)" hint="se descuenta del saldo" value={formatUsd(detail.financedUsd)} />
          {desglosado ? (
            <>
              <Linea label="Service fee sin IVA" value={formatUsd(fee)} />
              <Linea label="IVA del service fee" value={formatUsd(iva)} />
            </>
          ) : (
            conIva > 0 && <Linea label="Service fee + IVA" value={formatUsd(conIva)} />
          )}
        </dl>

        {detail.voidReason && (
          <>
            <Divider />
            <Callout tone="info" titulo="Motivo">
              {detail.voidReason}
            </Callout>
          </>
        )}
      </Card>
    </Seccion>
  )
}

/** Una fila rótulo–monto del desglose. Los montos en una sola columna. */
function Linea({ label, hint, value }: { label: string; hint?: string; value: string }) {
  return (
    <div className="flex items-baseline justify-between gap-4">
      <dt className="text-on-surface-variant">
        {label}
        {hint && <span className="ml-2 type-panel-caption text-panel-muted">{hint}</span>}
      </dt>
      <dd className="tabular-nums text-on-surface">{value}</dd>
    </div>
  )
}
