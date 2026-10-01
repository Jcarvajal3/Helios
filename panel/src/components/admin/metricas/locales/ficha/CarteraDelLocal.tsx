import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'

import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { CifraConTendencia, SeccionMetricas } from '@/components/admin/metricas/kit'
import { SkeletonStats, StatGrid, formatUsd, formatPct, formatPorcentaje } from '@/components/ui'
import type { MerchantStats } from '@/features/admin/api'
import { desgloseSiLoHay } from '@/features/admin/metricas/locales/cifras'
import { consultaDeCartera } from '@/features/admin/metricas/locales/consultas'
import type { Parametros } from '@/features/admin/parametros'
import { senalPorUmbral, senalPorUmbralAlto, umbralCobroATiempo, umbralMora } from '@/features/admin/umbrales'

const pctEntero = (n: number) => formatPorcentaje(n, 0)

/**
 * La cartera de su gente al cierre de la semana (hoy, si está en curso): la
 * mora, lo vivo y lo vencido —siempre con su consumo y su service fee por
 * separado—, el cobro a tiempo de toda su historia, lo dado por perdido y a
 * partir de qué mora deja de convenir. Sale de `admin_merchant_stats`, la
 * misma lectura que la ficha del local, con la semana puesta.
 */
export function CarteraDelLocal({
  semana,
  enCurso,
  local,
  parametros,
}: {
  semana: string
  enCurso: boolean
  local: string
  parametros: Parametros | undefined
}) {
  const q = useQuery(consultaDeCartera(semana, local))

  return (
    <SeccionMetricas
      titulo={enCurso ? 'Cartera de la clínica hoy' : 'Cartera de la clínica al cierre de la semana'}
      info="Calculado de las cuotas de los financiamientos en esta clínica, de toda su historia hasta ese día. La mora es la misma cuenta que la de toda la cartera, con los mismos umbrales de Ajustes."
      acciones={
        <Link
          to="/admin/clinicas/$id"
          params={{ id: local }}
          className="type-panel-caption font-semibold text-on-surface-variant underline-offset-2 hover:text-on-surface hover:underline"
        >
          Abrir la ficha de la clínica
        </Link>
      }
    >
      {q.isPending ? (
        <SkeletonStats count={4} cols={4} />
      ) : q.isError ? (
        <ErrorConReintento
          title="No se pudo leer su cartera"
          error={q.error}
          onReintentar={() => void q.refetch()}
        />
      ) : (
        <div className={q.isPlaceholderData ? 'opacity-60 transition-opacity' : 'transition-opacity'}>
          <Cifras s={q.data} parametros={parametros} />
        </div>
      )}
    </SeccionMetricas>
  )
}

function Cifras({ s, parametros }: { s: MerchantStats; parametros: Parametros | undefined }) {
  const c = s.portfolio
  const b = s.breakEven
  const hayVivo = c.openUsd > 0.005

  return (
    <StatGrid cols={4}>
      <CifraConTendencia
        titulo="Mora (%)"
        valor={hayVivo ? formatPct(c.arrearsPct) : '—'}
        senal={hayVivo ? senalPorUmbral(c.arrearsPct, umbralMora(parametros), pctEntero) : undefined}
        info="Vencido ÷ (vencido + por vencer), en cuotas de financiamientos en esta clínica (financiamiento + fee). Lo dado por perdido va aparte."
        pie={
          hayVivo
            ? `Vencido: ${desgloseSiLoHay(c.overdueFinancedUsd, c.overdueFeeUsd) ?? 'sin su desglose'}`
            : 'No había nada por cobrar'
        }
      />
      <CifraConTendencia
        titulo="Por cobrar (financiamiento + fee)"
        valor={formatUsd(c.openUsd)}
        info="Financiamiento + fee: las cuotas de financiamientos en esta clínica sin pagar ni dadas por perdidas, vencidas o por vencer. Debajo, cada parte por separado: su financiamiento y el service fee (IVA incluido)."
        pie={desgloseSiLoHay(c.openFinancedUsd, c.openFeeUsd) ?? undefined}
      />
      <CifraConTendencia
        titulo="Cobrado a tiempo, histórico (%)"
        valor={c.onTimePct === null ? '—' : formatPct(c.onTimePct)}
        senal={senalPorUmbralAlto(c.onTimePct, umbralCobroATiempo(parametros), pctEntero)}
        info="De todas las cuotas de financiamientos en esta clínica cuyo plazo ya terminó (el vencimiento más los días de gracia), las pagadas dentro de él. Un pago cuenta el día en que se registró."
        pie={c.dueCount > 0 ? `${c.onTimeCount} de ${c.dueCount} cuotas con el plazo cerrado` : 'Ninguna cuota ha cerrado su plazo'}
      />
      <CifraConTendencia
        titulo="Punto de empate (mora %)"
        valor={b.breakEvenPct === null ? '—' : formatPct(b.breakEvenPct)}
        senal={
          b.breakEvenPct !== null && hayVivo && c.arrearsPct >= b.breakEvenPct
            ? { tone: 'error', texto: 'Ya no conviene' }
            : undefined
        }
        info={
          b.policy === 'on_collection'
            ? 'Se le paga por cobranza: no se le adelanta nada, así que en un impago solo se pierde el service fee. Es la mora a partir de la cual la clínica deja de convenir.'
            : 'Se le paga por fecha: se le adelanta el dinero, así que en un impago se pierde el financiamiento entero. Es la mora a partir de la cual deja de convenir.'
        }
        pie={`Perdido: ${formatPct(c.badDebtPct)} de su financiado (sin fee)`}
      />
    </StatGrid>
  )
}
