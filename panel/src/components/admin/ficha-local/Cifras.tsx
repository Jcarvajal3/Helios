import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { ChartColumn } from 'lucide-react'

import type { CifraDeFicha } from '@/components/admin/ficha'
import type { ColumnasDeCifras } from '@/components/ui'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { SelectorDeVentana } from '@/components/admin/tableros/SelectorDeVentana'
import {
  diaOperativo,
  Seccion,
  SkeletonStats,
  Stat,
  StatGrid,
  estadoDeConsulta,
  formatUsd,
  formatPct,
} from '@/components/ui'
import { fetchMerchantStats } from '@/features/admin/api'
import { desgloseSiLoHay } from '@/features/admin/metricas/locales/cifras'
import type { Parametros } from '@/features/admin/parametros'
import {
  senalPorUmbral,
  senalPorUmbralAlto,
  umbralCobroATiempo,
  umbralMora,
} from '@/features/admin/umbrales'

/** Las ventanas que se ofrecen. Van en la URL como `?dias=`. */
export const VENTANAS_LOCAL = ['7', '30', '90'] as const
export type VentanaLocal = (typeof VENTANAS_LOCAL)[number]

const OPCIONES = VENTANAS_LOCAL.map((v) => ({ valor: v, dias: Number(v) }))

type CifrasDelLocal = Awaited<ReturnType<typeof fetchMerchantStats>>

/** Un porcentaje de umbral, sin decimales: «desde 7 %». */
const pctEntero = (n: number) => formatPct(n, 0)

type Cartera = CifrasDelLocal['portfolio']

/**
 * Lo que su gente todavía debe y se puede cobrar (vencido + por vencer), en
 * cuotas. Lo dado por perdido no entra, como en la mora de toda la cartera.
 * Es payable: se enseña siempre con sus dos partes.
 */
const deudaViva = (c: Cartera) => c.openUsd

/**
 * Lo vencido, dicho por sus dos partes. Sin ellas (una base sin actualizar)
 * se dice que no hay desglose: el hueco no enseña otra medida, y lo perdido ya
 * va en la ayuda de «Por cobrar a sus usuarios».
 */
function vencidoConDesglose(c: Cartera): string {
  const partes = desgloseSiLoHay(c.overdueFinancedUsd, c.overdueFeeUsd)
  return partes ? `Vencido: ${partes}` : 'Vencido: sin desglose'
}

/** Sin nada vivo no hay mora que juzgar. */
const hayDeudaViva = (c: Cartera) => deudaViva(c) > 0.005

/**
 * Las cifras del local. La leen el carril (la mora y la deuda viva, que son
 * de toda su historia) y la pestaña Resumen (lo vendido en la ventana): misma
 * clave, una sola llamada.
 */
export function useCifrasDelLocal(merchantId: string, dias: VentanaLocal) {
  return useQuery({
    queryKey: ['merchant-stats', merchantId, dias],
    queryFn: () => fetchMerchantStats(merchantId, Number(dias)),
  })
}

/**
 * Las tres cifras del carril: lo que se le debe, la mora de su gente y lo que
 * su gente todavía debe.
 *
 * La mora de Ronda puede ser del 4 % y la de un local concreto del 22 %, y
 * esa conversación (subirle la comisión, pausarlo) no se puede tener con el
 * número de toda la cartera. La pastilla sale de los umbrales de Ajustes, los
 * mismos para todo el panel.
 */
export function cifrasDelCarril({
  pendingUsd,
  cifras,
  parametros,
}: {
  pendingUsd: number
  cifras: ReturnType<typeof useCifrasDelLocal>
  parametros: Parametros | undefined
}): Array<CifraDeFicha> {
  const estado = estadoDeConsulta(cifras)
  const reintentar = () => void cifras.refetch()
  const c = cifras.data?.portfolio
  const hayMora = !!c && hayDeudaViva(c)

  return [
    {
      label: 'Pendiente de transferir a la clínica',
      value: formatUsd(pendingUsd),
      info: 'Liquidaciones ya generadas y todavía sin transferir a la clínica (pendientes o parciales), de toda su historia. El detalle, en «Sus pagos».',
      hint: pendingUsd > 0 ? undefined : 'No se le debe nada',
    },
    {
      label: 'Mora de sus pacientes (%)',
      value: c && hayMora ? formatPct(c.arrearsPct) : '—',
      info: 'Vencido ÷ (vencido + por vencer) de las cuotas de los financiamientos hechos en esta clínica, en financiamiento + comisión y de toda su historia; lo perdido no entra. Mismos umbrales de Ajustes que la mora de toda la cartera.',
      senal: c && hayMora ? senalPorUmbral(c.arrearsPct, umbralMora(parametros), pctEntero) : undefined,
      hint:
        c && hayMora
          ? vencidoConDesglose(c)
          : 'Sus pacientes no deben nada en cuotas de esta clínica',
      estado,
      onReintentar: reintentar,
    },
    {
      label: 'Por cobrar a sus pacientes (financiamiento + comisión)',
      value: c ? formatUsd(deudaViva(c)) : '',
      info: `Vencido + por vencer de las cuotas de los financiamientos hechos en esta clínica, en financiamiento + Comisión Helios (IVA incluido), de toda su historia; debajo, sus dos partes. Lo perdido no entra${c ? ` (${formatPct(c.badDebtPct)} de lo financiado sin comisión)` : ''}.`,
      hint: c ? (desgloseSiLoHay(c.openFinancedUsd, c.openFeeUsd) ?? undefined) : undefined,
      estado,
      onReintentar: reintentar,
    },
  ]
}

/**
 * Lo que factura en la ventana elegida y cuánta pérdida aguanta.
 *
 * La ventana solo afecta a lo facturado. El cobro a tiempo y la pérdida
 * máxima son de toda su historia: con treinta días casi nunca hay cuotas
 * vencidas suficientes para decir nada.
 */
export function LoVendido({
  merchantId,
  cifras,
  parametros,
  dias,
  onDias,
}: {
  merchantId: string
  cifras: ReturnType<typeof useCifrasDelLocal>
  parametros: Parametros | undefined
  dias: VentanaLocal
  onDias: (dias: VentanaLocal) => void
}) {
  return (
    <Seccion
      titulo="Lo que vende"
      info="Lo financiado y el ticket medio son de la ventana; las cuotas cobradas a tiempo y la pérdida máxima, de toda su historia."
      controles={
        <>
          {/* Semana a semana, con sus noches y cómo paga su gente: Métricas ›
              Locales con este local puesto. */}
          <Link
            to="/admin/metricas"
            search={{ vista: 'locales', local: merchantId }}
            className="inline-flex items-center gap-1.5 type-panel-caption font-semibold text-on-surface-variant underline-offset-2 hover:text-on-surface hover:underline"
          >
            <ChartColumn size={14} aria-hidden />
            Semana a semana, en Métricas
          </Link>
          <SelectorDeVentana valor={dias} opciones={OPCIONES} hoy={diaOperativo()} onChange={onDias} />
        </>
      }
    >
      {cifras.isPending && <SkeletonStats count={4} cols={4} />}

      {cifras.isError && (
        <SeccionSinLeer
          titulo="No se pudieron leer las cifras de la clínica"
          error={cifras.error}
          onReintentar={() => void cifras.refetch()}
        />
      )}

      {cifras.isSuccess && <CifrasListas d={cifras.data} parametros={parametros} />}
    </Seccion>
  )
}

function CifrasListas({ d, parametros }: { d: CifrasDelLocal; parametros: Parametros | undefined }) {
  const c = d.portfolio
  // El cobro a tiempo solo se mide cuando alguna cuota ya cerró su plazo.
  // Sin «pérdida máxima que aguanta»: todas las clínicas cobran igual (100 %,
  // por fecha) y salía la misma cifra para todas.
  const hayVeredicto = c.dueCount > 0
  const cols: ColumnasDeCifras = hayVeredicto ? 3 : 2

  return (
    <StatGrid cols={cols}>
      {/* Vendido y ticket medio van en consumo, sin la Comisión Helios: la base
          los suma de las cuotas (`metricas.consumos`). */}
      <Stat
        label={`Financiado (sin comisión), últimos ${d.windowDays} días`}
        value={formatUsd(d.financedUsd)}
        info="Suma de la consulta, sin la Comisión Helios, de las órdenes confirmadas en la clínica en los días operativos de la ventana; pacientes: los que tienen cuota en esas órdenes."
        hint={`${d.chargeCount} ${d.chargeCount === 1 ? 'financiamiento' : 'financiamientos'} · ${d.distinctUsers} ${
          d.distinctUsers === 1 ? 'paciente' : 'pacientes'
        }`}
      />
      <Stat
        label="Ticket medio (sin comisión)"
        value={formatUsd(d.avgTicketUsd)}
        info="Financiado (sin comisión) de la ventana ÷ número de financiamientos de la ventana."
        hint="Por financiamiento, en la misma ventana"
      />

      {hayVeredicto && (
        <Stat
          label="Cuotas cobradas a tiempo (%)"
          value={c.onTimePct === null ? '—' : formatPct(c.onTimePct)}
          info="De las cuotas de sus financiamientos con el plazo cerrado (vencimiento + días de gracia ya pasados), el % en número de cuotas que se reportó pagado dentro del plazo, de toda su historia; la pastilla sale de los umbrales de Ajustes."
          senal={senalPorUmbralAlto(c.onTimePct, umbralCobroATiempo(parametros), pctEntero)}
          hint={`Sobre ${c.dueCount} ${c.dueCount === 1 ? 'cuota con el plazo cerrado' : 'cuotas con el plazo cerrado'}`}
        />
      )}


    </StatGrid>
  )
}
