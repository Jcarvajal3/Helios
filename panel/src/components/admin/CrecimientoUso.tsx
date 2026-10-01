import { useQuery } from '@tanstack/react-query'

import {
  Callout,
  Seccion,
  SkeletonList,
  SkeletonStats,
  Stat,
  StatGrid,
  estadoDeConsulta,
  formatUsd,
  formatUsdShort,
  formatNumero,
  formatPorcentaje,
} from '@/components/ui'
import type { Rango } from '@/components/ui'
import { BarChart, ChartCard, ShareBars } from '@/components/charts'
import type { ShareRow } from '@/components/charts'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { NivelesDeUso } from '@/components/admin/crecimiento/NivelesDeUso'
import { NoSeParte } from '@/components/admin/metricas/kit'
import { UsuariosPorEstado } from '@/components/admin/tableros/UsuariosPorEstado'
import type { UserBehavior } from '@/features/admin/growth'
import { consultaDelTablero, consultaDelUso } from '@/features/admin/metricas/gente/consultas'
import { MOTIVO_ESTADOS } from '@/features/admin/metricas/gente/textos'

const usuarios = (v: number) => `${Math.round(v)} pacientes`
const cuenta = (v: number) => String(Math.round(v))

/**
 * Gente › Uso: cuánto gasta la gente y cómo se reparte ese gasto.
 *
 * La sub-vista existe por una sola idea: **una media no describe a nadie**.
 * Por eso la media siempre viene con su mediana al lado, y debajo va la forma
 * entera: el histograma, la concentración y los niveles. Con un local, todo
 * es del consumo en ese local; el padrón por estado no se parte.
 */
export function CrecimientoUso({ rango, local }: { rango: Rango; local: string | null }) {
  // La misma clave que Resumen: cambiar de sub-vista no vuelve a pedir el tablero.
  const tablero = useQuery(consultaDelTablero(rango, local))
  const uso = useQuery(consultaDelUso(rango, local))

  if (uso.isPending) {
    return (
      <>
        <SkeletonStats count={4} cols={4} />
        <SkeletonList rows={4} className="mt-6" />
      </>
    )
  }

  if (uso.isError) {
    return (
      <ErrorConReintento
        title="No se pudo leer el uso"
        error={uso.error}
        onReintentar={() => void uso.refetch()}
      />
    )
  }

  const b = uso.data
  const days = b.windowDays
  const periodo = { desde: b.from, hasta: b.to, local: b.merchantId ?? undefined }
  const sesgo = b.perUser.p50FinancedUsd > 0 ? b.perUser.avgFinancedUsd / b.perUser.p50FinancedUsd : 0

  return (
    <div className="flex flex-col gap-10">
      <div className="flex flex-col gap-4">
        <StatGrid cols={4}>
          <Stat
            label="Financiado por paciente, mediana (sin fee)"
            value={formatUsd(b.perUser.p50FinancedUsd)}
            info="Sin el service fee. Se suma lo financiado por cada paciente en la ventana y se toma la mediana: la mitad gastó esto o menos. Al lado, la media."
            hint={`Media ${formatUsd(b.perUser.avgFinancedUsd)}`}
          />
          <Stat
            label="Financiamientos por paciente, mediana"
            // La MEDIANA, igual que la tarjeta de al lado: dos tarjetas
            // contiguas no enseñan cifras de distinta clase.
            value={formatNumero(b.perUser.p50Orders, 0)}
            info="Los financiamientos de cada paciente en la ventana, y su mediana: la mitad hizo esto o menos. Al lado, la media y los días distintas de media."
            hint={`Media ${formatNumero(b.perUser.avgOrders)} en ${formatNumero(b.perUser.avgNights)} días`}
          />
          <Stat
            label="Ticket medio (sin fee)"
            // Sale de otra consulta: mientras no llega, o si falla, no es €0,00.
            value={formatUsd(tablero.data?.spend.perOrderUsd ?? 0)}
            estado={estadoDeConsulta(tablero)}
            onReintentar={() => void tablero.refetch()}
            info="Sin el service fee: el financiado entre el número de financiamientos de la ventana."
            hint="Financiado entre financiamientos"
            link={{ to: '/admin/financiamientos', search: periodo }}
          />
          <Stat
            // El mismo nombre que en Resumen: es el mismo número.
            label="Pacientes que se financiaron"
            value={String(b.activeUsers)}
            info="Pacientes distintos con un financiamiento en la ventana."
            hint={`Pacientes distintos en ${days} ${days === 1 ? 'día' : 'días'}`}
            link={{ to: '/admin/financiamientos', search: periodo }}
          />
        </StatGrid>

        {/* Solo con sesgo de verdad: con la media a menos de vez y media la
            mediana, el promedio sí describe a la persona normal. */}
        {sesgo >= 1.5 && (
          <Callout
            tone="info"
            titulo={`La media es ${formatNumero(sesgo)} veces la mediana`}
            detalles={`El 10 % de arriba llega a ${formatUsd(b.perUser.p90FinancedUsd)} o más. Media ${formatUsd(b.perUser.avgFinancedUsd)}, mediana ${formatUsd(b.perUser.p50FinancedUsd)}.`}
          >
            El financiado lo sostiene una minoría: para hablar del paciente normal, la cifra es la mediana.
          </Callout>
        )}
      </div>

      <Seccion titulo="Pacientes por financiado y por financiamientos">
        <div className="grid gap-4 xl:grid-cols-2">
          <BarChart
            title="Pacientes por tramo de financiado (sin fee)"
            summary={`${b.activeUsers} pacientes, repartidos por su financiado en la ventana`}
            enteros
            series={[{ key: 'users', label: 'Pacientes' }]}
            points={b.spendBuckets.map((t) => ({ key: String(t.key), label: t.label, values: [t.users] }))}
            format={usuarios}
            formatShort={cuenta}
            ejeLabel="Tramo"
            empty="Nadie se financió en esta ventana."
            footnote="Sin el service fee: cada paciente va en el tramo de lo que se le financió en la ventana. Los tramos son fijos en dólares, no percentiles: cuanto más larga la ventana, más a la derecha se corre la gente sin haber cambiado de hábito."
          />

          <BarChart
            title="Pacientes por número de financiamientos"
            summary={`${formatNumero(b.perUser.avgOrders)} financiamientos de media · la mitad hizo ${b.perUser.p50Orders} o menos`}
            enteros
            series={[{ key: 'users', label: 'Pacientes' }]}
            points={b.orderBuckets.map((t) => ({ key: String(t.key), label: t.label, values: [t.users] }))}
            format={usuarios}
            formatShort={cuenta}
            ejeLabel="Financiamientos"
            empty="Nadie se financió en esta ventana."
          />
        </div>
      </Seccion>

      <div className="grid gap-4 xl:grid-cols-2">
        <ChartCard
          titulo="Concentración del financiado (sin fee)"
          info={`Sin el service fee. Se ordena a los pacientes que se financiaron por su financiado en la ventana y se parten en tres bloques: el 10 % de arriba, el 40 % siguiente y la mitad de abajo. Cada barra es el financiado de su bloque. Dice de cuántos pacientes depende el negocio.${formulaConcentracion(b)}`}
        >
          <ShareBars rows={concentracion(b)} format={formatUsd} />
        </ChartCard>

        <ChartCard
          titulo="Registros por estado de la cuenta"
          info="Todos los pacientes registrados por las clínicas, por el estado de su cuenta hoy: no sigue a la ventana. Cada estado abre el directorio filtrado por él."
        >
          {b.statuses ? (
            <UsuariosPorEstado filas={b.statuses.map((s) => ({ estado: s.status, personas: s.users }))} />
          ) : (
            <NoSeParte variante="bloque" motivo={MOTIVO_ESTADOS} />
          )}
        </ChartCard>
      </div>

      <NivelesDeUso niveles={b.levels} />
    </div>
  )
}

function concentracion(b: UserBehavior): ShareRow[] {
  return b.concentration.map((c) => ({
    key: c.key,
    label: c.label,
    value: c.financedUsd,
    // Solo el primer bloque va en el tono del área: es el que contesta la
    // pregunta. Aquí no hay un bueno y un malo, hay una forma.
    tone: c.key === 'top10' ? 'primary' : 'neutral',
    note: `${c.users} pacientes · ${formatUsdShort(c.users > 0 ? c.financedUsd / c.users : 0)} sin fee cada uno`,
  }))
}

/** La cuenta del bloque de arriba, para la explicación, o nada si no hay gasto. */
function formulaConcentracion(b: UserBehavior): string {
  const total = b.concentration.reduce((s, c) => s + c.financedUsd, 0)
  const top = b.concentration.find((c) => c.key === 'top10')
  if (!top || total <= 0) return ''

  return ` Ahora: el 10 % de arriba (${top.users} pacientes) mueve ${formatUsd(top.financedUsd)} de ${formatUsd(total)}, el ${formatPorcentaje((top.financedUsd / total) * 100)}.`
}
