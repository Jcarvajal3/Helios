import { useState } from 'react'
import { createFileRoute } from '@tanstack/react-router'
import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { Lock } from 'lucide-react'

import { BarChart } from '@/components/charts'
import {
  EmptyState,
  ErrorBox,
  Segmented,
  SectionTitle,
  SkeletonStats,
  Stat,
  StatGrid,
  formatDay,
  formatPorcentaje,
  formatUsd,
  formatUsdShort,
} from '@/components/ui'
import { canSee } from '@/features/auth/permissions'
import { useStaff } from '@/features/auth/session'
import {
  fetchMerchantDailySeries,
  fetchMerchantOverview,
  fetchMerchantRecurrence,
} from '@/features/merchant/metrics'
import type {
  MerchantDayPoint,
  MerchantRecurrence,
} from '@/features/merchant/metrics'
import { describeError } from '@/lib/supabase'

export const Route = createFileRoute('/_comercio/metricas')({
  staticData: { title: 'Métricas' },
  component: MetricasPage,
})

const RANGES = [
  { value: '7', label: '7 días' },
  { value: '30', label: '30 días' },
  { value: '90', label: '90 días' },
]

/**
 * La recurrencia va SIEMPRE a 30 días y no sigue al selector de arriba.
 *
 * "Vino 4 veces" solo significa algo con una ventana fija: en 7 días es
 * casi imposible y en 90 lo consigue cualquier paciente en control. Que
 * cambiara con el rango haría que el mismo paciente saltara de cubo sin
 * haber hecho nada.
 */
const RECURRENCE_DAYS = 30

/** Los cubos del filtro. `4` es "cuatro o más": pacientes en tratamiento. */
const RECURRENCE_TIMES = [
  { value: '2', label: '2 veces' },
  { value: '3', label: '3 veces' },
  { value: '4', label: '4 o más veces' },
]

function MetricasPage() {
  const staff = useStaff()
  const [range, setRange] = useState('30')
  const days = Number(range)

  // `keepPreviousData` en las tres que siguen al selector de arriba.
  //
  // Sin esto, pasar de 30 a 90 días vacía `data` mientras vuelve la
  // respuesta: las tarjetas y los dos gráficos desaparecen, la página se
  // encoge, salen los esqueletos y al llegar los datos vuelve a crecer. Dos
  // saltos de medio metro de alto por cada pastilla que se toca.
  //
  // Con esto se queda lo anterior en pantalla, apagado al 60 %, y cuando
  // llega lo nuevo se enciende sin mover nada de sitio.
  const overview = useQuery({
    queryKey: ['merchant-overview', days],
    queryFn: () => fetchMerchantOverview(days),
    enabled: !!staff && canSee(staff.role, 'metricas'),
    placeholderData: keepPreviousData,
  })

  const daily = useQuery({
    queryKey: ['merchant-daily', days],
    queryFn: () => fetchMerchantDailySeries(days),
    enabled: !!staff && canSee(staff.role, 'metricas'),
    placeholderData: keepPreviousData,
  })

  // Sin `days` en la clave: la ventana es fija y refetchear al cambiar el
  // rango pediría lo mismo otra vez.
  const recurrence = useQuery({
    queryKey: ['merchant-recurrence', RECURRENCE_DAYS],
    queryFn: () => fetchMerchantRecurrence(RECURRENCE_DAYS),
    enabled: !!staff && canSee(staff.role, 'metricas'),
  })

  if (!staff) return null

  if (!canSee(staff.role, 'metricas')) {
    return (
      <EmptyState
        icon={<Lock size={48} />}
        title="Esto lo ve el administrador"
        description="Lo que registra la clínica entera es información del administrador. Tu cuenta registra pagos en cuotas y consulta los suyos."
      />
    )
  }

  const error = overview.error ?? daily.error ?? recurrence.error

  return (
    <>
      <Segmented options={RANGES} value={range} onChange={setRange} />

      {error && (
        <div className="mt-6">
          <ErrorBox
            title="No pudimos cargar las métricas"
            detail={describeError(error)}
          />
        </div>
      )}

      {overview.isLoading && <SkeletonStats className="mt-6" />}

      {overview.data && !overview.isError && (
        <>
          <StatGrid className="mt-6">
            <Stat
              label="Registrado"
              value={formatUsd(overview.data.soldUsd)}
              tone="success"
              hint={
                <Delta
                  current={overview.data.soldUsd}
                  previous={overview.data.previousSoldUsd}
                  days={days}
                />
              }
            />
            <Stat
              label="Tu parte"
              value={formatUsd(overview.data.netUsd)}
              // Con comisión 0 —lo normal desde el 2026-08-30— la pista decía
              // "Después de la comisión (0%)", que es una resta que no
              // existe y siembra la duda de si existe alguna otra.
              hint={
                overview.data.commissionPct > 0
                  ? `Después de la comisión de Helios (${overview.data.commissionPct}%)`
                  : 'El monto completo de tus consultas: Helios no te cobra comisión'
              }
            />
            <Stat
              label="Órdenes"
              value={String(overview.data.chargeCount)}
              hint={
                <Delta
                  current={overview.data.chargeCount}
                  previous={overview.data.previousChargeCount}
                  days={days}
                />
              }
            />
            <Stat
              label="Consulta promedio"
              value={formatUsd(overview.data.avgTicketUsd)}
              hint="Registrado ÷ órdenes"
            />
          </StatGrid>

          {/* Los días con órdenes no son parte del promedio, que va
              por orden y no por día: aquí abajo son contexto del
              periodo. */}
          {overview.data.activeDays > 0 && (
            <p className="mt-3 type-label-medium text-on-surface-variant">
              {overview.data.activeDays}{' '}
              {overview.data.activeDays === 1 ? 'día' : 'días'} con pagos en cuotas en el
              periodo.
              {overview.data.bestDate &&
                ` El mejor fue el ${formatDay(overview.data.bestDate)}, con ${formatUsd(
                  overview.data.bestUsd,
                )}.`}
            </p>
          )}
        </>
      )}

      {daily.data && !daily.isError && daily.data.some((p) => p.chargeCount > 0) && (
        <div
          className={`mt-6 transition-opacity duration-[var(--duration-medium1)] ${
            daily.isPlaceholderData ? 'opacity-60' : 'opacity-100'
          }`}
        >
          <DailyChart points={daily.data} />
        </div>
      )}

      {recurrence.isLoading && <SkeletonStats className="mt-8" />}

      {recurrence.data && !recurrence.isError && recurrence.data.customers > 0 && (
        <Recurrence data={recurrence.data} />
      )}

      {!overview.isError && overview.data?.chargeCount === 0 && (
        <EmptyState
          title="Todavía no hay pagos en cuotas en este periodo"
          description="En cuanto registres el primero, aquí verás cuánto se paga en cuotas en tu clínica."
        />
      )}
    </>
  )
}

/**
 * Comparación contra el periodo anterior de la misma duración.
 *
 * Sin periodo anterior no se inventa un porcentaje: dividir entre cero daría
 * un "+∞%" o un "+100%" que se lee como un crecimiento que nadie tuvo. Una
 * clínica que empezó hace dos semanas no creció, simplemente no había antes.
 */
function Delta({
  current,
  previous,
  days,
}: {
  current: number
  previous: number
  days: number
}) {
  if (previous === 0) {
    return <span className="text-on-surface-variant">Sin datos de los {days} días previos</span>
  }

  const pct = ((current - previous) / previous) * 100
  const up = pct >= 0

  return (
    <span className={up ? 'text-primary' : 'text-warning'}>
      {up ? '▲' : '▼'} {formatPorcentaje(Math.abs(pct))} vs. los {days} días previos
    </span>
  )
}

/**
 * CUÁNTOS DE TUS PACIENTES VUELVEN.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * La cifra de arriba —"Registrado"— no distingue entre cien pacientes que
 * vinieron una vez y veinticinco que vinieron cuatro. Para una clínica son
 * dos cosas distintas: los segundos están en tratamiento o en control, y
 * vuelven a pagar en cuotas con Helios.
 *
 * **Una visita es un pago en cuotas de un paciente**, y se cuenta por
 * persona: por eso este bloque no se deriva de las órdenes de arriba.
 *
 * En cubos y no en un promedio: "mis pacientes vienen 1,8 veces" no se puede
 * accionar; "tengo 12 que vinieron 4 veces o más y me dejaron $840" sí.
 */
function Recurrence({ data }: { data: MerchantRecurrence }) {
  const [times, setTimes] = useState('2')

  const option = RECURRENCE_TIMES.find((t) => t.value === times)
  // La base devuelve siempre los cuatro cubos, pero el tipo no lo sabe: un
  // cubo vacío se lee igual de bien que la ausencia de cubo, y no revienta.
  const bucket = data.buckets.find((b) => b.times === Number(times)) ?? {
    times: Number(times),
    customers: 0,
    visits: 0,
    saleUsd: 0,
  }

  return (
    <div className="mt-8">
      <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <SectionTitle>Pacientes que vuelven</SectionTitle>
        {/* Se dice que la ventana es fija porque justo encima hay un selector
            de 7/30/90 que NO manda aquí. */}
        <span className="type-label-medium text-on-surface-variant">
          Siempre {data.windowDays} días, no sigue al rango de arriba
        </span>
      </div>

      <div className="mt-4">
        <Segmented options={RECURRENCE_TIMES} value={times} onChange={setTimes} />
      </div>

      <StatGrid className="mt-4">
        <Stat
          label="Recurrencia"
          value={formatPorcentaje(data.returningPct)}
          hint={`${data.returningCustomers} de ${data.customers} ${
            data.customers === 1 ? 'paciente volvió' : 'pacientes volvieron'
          } al menos una vez más`}
        />
        <Stat
          label="Pacientes"
          value={String(bucket.customers)}
          hint={`Vinieron ${option?.label ?? ''}`}
        />
        <Stat
          label="Visitas"
          value={String(bucket.visits)}
          hint="Cada pago en cuotas suyo cuenta una"
        />
        <Stat
          label="Te dejaron"
          value={formatUsd(bucket.saleUsd)}
          hint="Sus consultas, sin la comisión de servicio"
        />
      </StatGrid>
    </div>
  )
}

/**
 * Lo registrado por día. Una serie y hasta noventa barras, dibujadas por el
 * kit de `components/charts`: eje, rejilla, la cifra del mejor día escrita
 * encima de su barra y los números en una tabla desplegable.
 *
 * La media va de línea de referencia y se calcula sobre TODOS los días de la
 * ventana, no solo sobre los que hubo órdenes. Una clínica que
 * atiende tres días por semana tiene una media más baja que la de sus días de
 * consulta, y la que decide si el mes sale son los siete días.
 */
function DailyChart({ points }: { points: MerchantDayPoint[] }) {
  const total = points.reduce((s, p) => s + p.soldUsd, 0)
  const media = points.length > 0 ? total / points.length : 0

  return (
    <BarChart
      title="Registrado por día"
      series={[{ key: 'sold', label: 'Registrado' }]}
      points={points.map((p) => ({
        key: p.businessDate,
        label: formatDay(p.businessDate),
        values: [p.soldUsd],
        note: `${p.chargeCount} ${p.chargeCount === 1 ? 'orden' : 'órdenes'}`,
      }))}
      format={formatUsd}
      formatShort={formatUsdShort}
      ejeLabel="Día"
      unidadLabel="Órdenes"
      reference={{ value: media, label: `Media ${formatUsdShort(media)} al día` }}
      summary={
        <>
          <span className="type-body-medium-emphasized tabular-nums text-on-surface">
            {formatUsd(total)}
          </span>{' '}
          en {points.length} días · media {formatUsd(media)} al día
        </>
      }
      footnote="Cada día va de medianoche a medianoche, hora de Caracas."
    />
  )
}
