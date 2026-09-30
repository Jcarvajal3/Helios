import { DataLabel, formatDay, formatUsd } from '@/components/ui'
import { diaDeLaSemana, rotuloDelServicio } from '@/features/merchant/registro'
import type { CuotaDelPlan } from '@/features/merchant/registro'

/**
 * Las dos cuotas del paciente: cuándo y cuánto.
 *
 * Es lo que la secretaria le lee al paciente antes de confirmar, así que va
 * con el día de la semana («jueves 08/10/26»): así se apunta una cita.
 *
 * Cada cuota lleva dentro su parte del servicio Helios; eso es lo que dice
 * la regla (el fee va «dentro de las cuotas o como línea aparte»). Lo que no
 * hay aquí es una fila de total: sumar las cuotas daría la consulta MÁS el
 * servicio, y esa cifra no se enseña en el panel de la clínica.
 */
export function PlanDePagos({ cuotas }: { cuotas: CuotaDelPlan[] }) {
  return (
    <ol className="flex flex-col gap-2">
      {cuotas.map((c) => (
        <li
          key={c.sequence}
          className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 rounded-panel-card bg-panel-raised px-4 py-3"
        >
          <span className="type-panel-body text-on-surface">
            <strong>Cuota {c.sequence}</strong>
            <span className="text-on-surface-variant">
              {' '}
              · {diaDeLaSemana(c.dueDate)} {formatDay(c.dueDate)}
            </span>
          </span>
          <span className="type-panel-section tabular-nums text-on-surface">
            {formatUsd(c.amountUsd)}
          </span>
        </li>
      ))}
    </ol>
  )
}

/**
 * EL DESGLOSE: la consulta y, en su propia línea, el servicio Helios.
 *
 * ⚠️ Regla de Ronda que Helios hereda sin excepción: **ningún total mostrado
 * incluye el fee**. Aquí hay dos líneas y ninguna tercera que las sume. La
 * consulta es lo que cobra la clínica; el servicio (20 % + IVA) es de Helios
 * y lo paga el paciente repartido en sus cuotas.
 */
export function DesgloseDelServicio({
  baseUsd,
  feePct,
  feeUsd,
  feeVatUsd,
  concepto,
}: {
  baseUsd: number
  feePct: number
  feeUsd: number | null
  feeVatUsd: number | null
  concepto: string | null
}) {
  const servicio = feeUsd === null ? null : Math.round((feeUsd + (feeVatUsd ?? 0)) * 100) / 100

  return (
    <div>
      <DataLabel>Desglose</DataLabel>
      <dl className="mt-2 flex flex-col gap-1.5 type-panel-body">
        <div className="flex items-baseline justify-between gap-4">
          <dt className="text-on-surface-variant">{concepto ?? 'Consulta'}</dt>
          <dd className="tabular-nums text-on-surface">{formatUsd(baseUsd)}</dd>
        </div>

        {servicio !== null && (
          <div className="flex items-baseline justify-between gap-4">
            <dt className="text-on-surface-variant">
              {rotuloDelServicio(feePct)}
              <span className="block type-panel-caption text-panel-muted">
                Lo paga el paciente dentro de sus cuotas. No es de la clínica.
              </span>
            </dt>
            <dd className="tabular-nums text-on-surface-variant">{formatUsd(servicio)}</dd>
          </div>
        )}
      </dl>
    </div>
  )
}
