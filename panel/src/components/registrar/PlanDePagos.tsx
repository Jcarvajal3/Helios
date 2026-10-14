import { DataLabel, formatDay, formatMoneda, formatVes } from '@/components/ui'
import type { Moneda } from '@/components/ui'
import { DE_LA_MONEDA, LO_PAGA_EL_PACIENTE, diaDeLaSemana, rotuloDelServicio } from '@/features/merchant/registro'
import type { CuotaDelPlan } from '@/features/merchant/registro'

/**
 * Las dos cuotas del paciente: cuándo y cuánto.
 *
 * Es lo que la secretaria le lee al paciente antes de confirmar, así que va
 * con el día de la semana («jueves 08/10/26»): así se apunta una cita.
 *
 * Cada cuota va en la moneda en la que cobró la clínica y, debajo, lo que
 * serían hoy en bolívares. Solo de referencia: el paciente paga en bolívares
 * a la tasa del día en que paga, y la nota de abajo se lo dice.
 *
 * Cada cuota lleva dentro su parte de la Comisión Helios; eso es lo que
 * dice la regla (va «dentro de las cuotas o como línea aparte»). Lo que no
 * hay aquí es una fila de total: sumar las cuotas daría la consulta MÁS la
 * Comisión Helios, y esa cifra no se enseña en el panel de la clínica.
 */
export function PlanDePagos({ cuotas, moneda }: { cuotas: CuotaDelPlan[]; moneda: Moneda }) {
  return (
    <div className="flex flex-col gap-2">
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
            <span className="text-right">
              <span className="block type-panel-section tabular-nums text-on-surface">
                {formatMoneda(c.amountCur, moneda)}
              </span>
              {c.amountVes !== null && (
                <span className="block type-panel-caption tabular-nums text-panel-muted">
                  ≈ {formatVes(c.amountVes)} hoy
                </span>
              )}
            </span>
          </li>
        ))}
      </ol>
      <p className="type-panel-caption text-panel-muted">
        Pagas en bolívares a la tasa BCV {DE_LA_MONEDA[moneda]} del día en que pagues.
      </p>
    </div>
  )
}

/**
 * EL DESGLOSE: la consulta y, en su propia línea, la Comisión Helios.
 * En la moneda en la que cobró la clínica.
 *
 * ⚠️ Regla de Ronda que Helios hereda sin excepción: **ningún total mostrado
 * a la clínica incluye la Comisión Helios**. Aquí hay dos líneas y
 * ninguna tercera que las sume. La consulta es lo que cobra la clínica; la
 * Comisión Helios (el % que manda la base, hoy 12 %, + IVA 16 % sobre
 * ella) es de Helios y la paga el paciente repartida en sus cuotas.
 */
export function DesgloseDelServicio({
  base,
  feePct,
  fee,
  feeVat,
  moneda,
  concepto,
}: {
  base: number
  feePct: number
  fee: number | null
  feeVat: number | null
  moneda: Moneda
  concepto: string | null
}) {
  const servicio = fee === null ? null : Math.round((fee + (feeVat ?? 0)) * 100) / 100

  return (
    <div>
      <DataLabel>Desglose</DataLabel>
      <dl className="mt-2 flex flex-col gap-1.5 type-panel-body">
        <div className="flex items-baseline justify-between gap-4">
          <dt className="text-on-surface-variant">{concepto ?? 'Consulta'}</dt>
          <dd className="tabular-nums text-on-surface">{formatMoneda(base, moneda)}</dd>
        </div>

        {servicio !== null && (
          <div className="flex items-baseline justify-between gap-4">
            <dt className="text-on-surface-variant">
              {rotuloDelServicio(feePct)}{' '}
              <strong className="font-semibold text-on-surface">{LO_PAGA_EL_PACIENTE}</strong>
              <span className="block type-panel-caption text-panel-muted">
                Va dentro de sus cuotas. No se le descuenta a la clínica.
              </span>
            </dt>
            <dd className="tabular-nums text-on-surface-variant">{formatMoneda(servicio, moneda)}</dd>
          </div>
        )}
      </dl>
    </div>
  )
}
