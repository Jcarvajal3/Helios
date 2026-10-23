import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'

import { DataTable } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { CifraConTendencia, SeccionMetricas } from '@/components/admin/metricas/kit'
import { StatGrid, describirRango, estadoDeConsulta, formatNumero, formatPorcentaje, formatUsd } from '@/components/ui'
import type { BusquedaJuanPablo } from '@/features/admin/metricas/juan-pablo/busqueda'
import { consultaDeJuanPablo } from '@/features/admin/metricas/juan-pablo/api'
import type { MedicoDeJuanPablo } from '@/features/admin/metricas/juan-pablo/lectura'
import { rangoElegido } from '@/features/admin/metricas/juan-pablo/periodo'
import type { PropsPestana } from '@/features/admin/metricas/tipos'
import { csvDinero } from '@/lib/csv'

/**
 * Métricas › Juan Pablo: órdenes, GTV y revenue del periodo, y cómo se
 * reparten entre los médicos.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Una sola vista, sin sub-pestañas. El periodo lo elige su propio selector,
 * arriba en el hueco de la semana (`MarcoMetricas`); por defecto, hoy. No se
 * parte por clínica: un médico es una clínica, y la distribución es entre
 * todos.
 *
 * Cada cifra sale una vez: el ticket medio y las órdenes por médico van en
 * el pie de la suya, no en una tarjeta aparte.
 */
export function PestanaJuanPablo({ hoy, busqueda }: PropsPestana<BusquedaJuanPablo>) {
  const rango = rangoElegido(busqueda, hoy)
  const q = useQuery(consultaDeJuanPablo(rango))
  const d = q.data
  const estado = estadoDeConsulta(q)
  const reintentar = () => void q.refetch()
  const columnas = useMemo(() => columnasDeMedicos(), [])

  const periodo = d ? describirRango({ from: d.desde, to: d.hasta }) : describirRango(rango)

  return (
    <div className="flex flex-col gap-6">
      <StatGrid cols={4}>
        <CifraConTendencia
          titulo="Órdenes generadas"
          info="Los pagos en cuotas confirmados en el periodo, por su día. Los de prueba no cuentan."
          valor={d ? formatNumero(d.ordenes, 0) : ''}
          pie={d && d.ticketMedioUsd !== null ? `Ticket medio ${formatUsd(d.ticketMedioUsd)}` : 'Sin órdenes en el periodo'}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo="GTV"
          info="Lo que suman las consultas de las órdenes del periodo, sin la Comisión Helios. Una orden en euros cuenta en dólares, a la tasa del día en que se registró."
          valor={d ? formatUsd(d.gtvUsd) : ''}
          pie="Sin la Comisión Helios"
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo="Revenue generado"
          info="La Comisión Helios de las órdenes del periodo (el 12 % del GTV), sin el IVA, que no es ingreso."
          valor={d ? formatUsd(d.revenueUsd) : ''}
          pie={d && d.revenuePct !== null ? `${formatPorcentaje(d.revenuePct, 0)} del GTV · sin IVA` : 'Sin IVA'}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo="% de consumo por médico"
          info="Los médicos que generaron al menos una orden en el periodo, entre todos los afiliados (con sus accesos) al cierre del periodo. Debajo, las órdenes entre los médicos que las generaron."
          valor={d && d.medicos.conOrdenesPct !== null ? formatPorcentaje(d.medicos.conOrdenesPct, 1) : d ? '—' : ''}
          pie={
            d
              ? `${d.medicos.conOrdenes} de ${d.medicos.afiliados} médicos` +
                (d.medicos.ordenesPorMedico !== null
                  ? ` · ${formatNumero(d.medicos.ordenesPorMedico, 1)} órdenes por médico`
                  : '')
              : undefined
          }
          estado={estado}
          onReintentar={reintentar}
        />
      </StatGrid>

      <SeccionMetricas
        titulo="Distribución de consumo por médico"
        ayuda={periodo.charAt(0).toUpperCase() + periodo.slice(1)}
        info="Cada médico con órdenes en el periodo y su parte de todas las órdenes: con 20 órdenes, un médico con 5 tiene el 25 %. El GTV y el revenue de cada uno, como arriba."
      >
        {d && d.porMedico.length === 0 ? (
          <p className="type-panel-body text-on-surface-variant">Ningún médico generó órdenes en el periodo.</p>
        ) : (
          <DataTable
            rows={d?.porMedico ?? []}
            rowKey={(m) => m.merchantId}
            columns={columnas}
            noun={['médico', 'médicos']}
            exportar={d ? { archivo: `juan-pablo-${d.desde}-${d.hasta}` } : undefined}
          />
        )}
      </SeccionMetricas>
    </div>
  )
}

function columnasDeMedicos(): Array<Column<MedicoDeJuanPablo>> {
  return [
    {
      key: 'medico',
      header: 'Médico',
      identity: true,
      sort: (m) => m.medico,
      csv: (m) => m.medico,
      cell: (m) => (
        <div>
          <p className="font-semibold text-on-surface">{m.medico}</p>
          {m.clinica !== m.medico && (
            <span className="mt-0.5 block type-panel-caption text-on-surface-variant">{m.clinica}</span>
          )}
        </div>
      ),
    },
    {
      key: 'ordenes',
      header: 'Órdenes',
      type: 'number',
      sortDir: 'desc',
      sort: (m) => m.ordenes,
      csv: (m) => m.ordenes,
      cell: (m) => <span className="font-semibold">{formatNumero(m.ordenes, 0)}</span>,
    },
    {
      key: 'pct',
      header: '% de las órdenes',
      info: 'Sus órdenes entre todas las del periodo.',
      type: 'number',
      sortDir: 'desc',
      sort: (m) => m.pct,
      csv: (m) => m.pct,
      cell: (m) => (m.pct === null ? '—' : <BarraDeParte pct={m.pct} />),
    },
    {
      key: 'gtv',
      header: 'GTV',
      info: 'Sin la Comisión Helios.',
      type: 'number',
      sortDir: 'desc',
      sort: (m) => m.gtvUsd,
      csv: (m) => csvDinero(m.gtvUsd),
      cell: (m) => formatUsd(m.gtvUsd),
    },
    {
      key: 'revenue',
      header: 'Revenue',
      info: 'La Comisión Helios de sus órdenes, sin IVA.',
      type: 'number',
      sortDir: 'desc',
      sort: (m) => m.revenueUsd,
      csv: (m) => csvDinero(m.revenueUsd),
      cell: (m) => formatUsd(m.revenueUsd),
    },
  ]
}

/** «25,0 %» con una barra que dice lo mismo a la vista. */
function BarraDeParte({ pct }: { pct: number }) {
  return (
    <span className="inline-flex items-center justify-end gap-2">
      <span aria-hidden className="h-1.5 w-20 overflow-hidden rounded-full bg-panel-raised">
        <span className="block h-full rounded-full bg-(--area)" style={{ width: `${Math.min(pct, 100)}%` }} />
      </span>
      <span className="tabular-nums">{formatPorcentaje(pct, 1)}</span>
    </span>
  )
}
