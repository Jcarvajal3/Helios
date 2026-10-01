import { SeccionMetricas } from '@/components/admin/metricas/kit'
import { SERIE, colorDeTono } from '@/components/charts'
import { Table, Td, Tr, formatUsd, formatPorcentaje } from '@/components/ui'
import { busquedaDeMetricas } from '@/features/admin/metricas/busqueda'
import { cohortesDelLocal } from '@/features/admin/metricas/locales/ficha'
import type { FilaDeCohorteDelLocal } from '@/features/admin/metricas/locales/ficha'
import { semanaCorta } from '@/features/admin/metricas/locales/semanas'
import type { CuotaDeCohorte, LocalesDeLaSemana } from '@/features/admin/metricas/locales/tipos'
import { Link } from '@tanstack/react-router'

import { ImporteConDesglose } from '../ImporteConDesglose'
import { MarcaConGlobo } from '@/components/charts/lectura'

/** Los cinco estados de una cuota, en el orden en que se leen, con su color. */
const ESTADOS = [
  { clave: 'aTiempo', rotulo: 'a tiempo', color: colorDeTono('success') },
  { clave: 'tarde', rotulo: 'tarde', color: colorDeTono('warning') },
  { clave: 'vencidas', rotulo: 'vencidas', color: colorDeTono('error') },
  { clave: 'perdidas', rotulo: 'perdidas', color: 'var(--color-on-surface-variant)' },
  { clave: 'porVencer', rotulo: 'por vencer', color: SERIE.tenue },
] as const

const CABECERAS = [
  'Semana de financiamiento',
  { label: 'Financiado (sin fee)', info: 'Sin el service fee: el financiado de esa semana en la clínica.' },
  { label: 'Pacientes', info: 'Pacientes distintos con una cuota en los financiamientos de esa semana en la clínica.' },
  { label: 'Cuota 1', info: 'Las cuotas 1 de lo financiado esa semana: el porcentaje es el de las pagadas a tiempo entre las que ya cerraron su plazo; la barra, el estado de hoy de todas (al pasar el ratón, cuántas hay en cada estado).' },
  { label: 'Cuota 2', info: 'Lo mismo para las cuotas 2, que vencen una semana después.' },
  { label: 'Vencido hoy (financiamiento + fee)', info: 'Financiamiento + fee: lo que sigue vencido y sin pagar hoy de las cuotas 1 y 2 de esa semana. Debajo, cada parte por separado: su financiamiento y el service fee (IVA incluido).' },
]

/**
 * «Cobro de las cuotas por semana de consumo»: las semanas de consumo del local (las ocho que acaban
 * en la elegida), cada una con el estado de hoy de sus dos cuotas. Es la vista
 * de Cohortes de un solo local, con la misma cuenta; la semana entera está en
 * Cohortes.
 */
export function CohortesDelLocal({ d, local }: { d: LocalesDeLaSemana; local: string }) {
  const filas = cohortesDelLocal(d, local)

  return (
    <div data-area="cobranza">
      <SeccionMetricas
        titulo="Cobro de las cuotas por semana de financiamiento"
        info={`Cada fila son los financiamientos de una semana en esta clínica, con el estado de hoy de sus cuotas 1 y 2. El porcentaje es el de cuotas pagadas a tiempo entre las que ya cerraron su plazo (el vencimiento más ${d.graciaDias} días de gracia): antes no se sabe si llegará a tiempo.`}
        acciones={
          <Link
            to="/admin/metricas"
            search={busquedaDeMetricas('cobros', {}, { semana: d.semana.enCurso ? undefined : d.semana.desde, local })}
            className="type-panel-caption font-semibold text-on-surface-variant underline-offset-2 hover:text-on-surface hover:underline"
          >
            Ver en Cobros
          </Link>
        }
      >
        <Leyenda />
        {filas.every((f) => f.cuota1 === null && f.cuota2 === null) ? (
          <p className="type-panel-body text-panel-muted">Esta clínica no financió nada en estas ocho semanas.</p>
        ) : (
          <Table headers={CABECERAS}>
            {filas.map((f) => (
              <FilaDeCohorte key={f.semana} f={f} />
            ))}
          </Table>
        )}
      </SeccionMetricas>
    </div>
  )
}

function Leyenda() {
  return (
    <ul className="flex flex-wrap gap-x-4 gap-y-1">
      {ESTADOS.map((e) => (
        <li key={e.clave} className="inline-flex items-center gap-1.5 type-panel-caption text-on-surface-variant">
          <span aria-hidden className="size-2.5 rounded-full" style={{ backgroundColor: e.color }} />
          {e.rotulo}
        </li>
      ))}
    </ul>
  )
}

function FilaDeCohorte({ f }: { f: FilaDeCohorteDelLocal }) {
  const vencido = {
    payableUsd: (f.cuota1?.vencido.payableUsd ?? 0) + (f.cuota2?.vencido.payableUsd ?? 0),
    financedUsd: (f.cuota1?.vencido.financedUsd ?? 0) + (f.cuota2?.vencido.financedUsd ?? 0),
    feeUsd: (f.cuota1?.vencido.feeUsd ?? 0) + (f.cuota2?.vencido.feeUsd ?? 0),
  }

  if (f.cuota1 === null && f.cuota2 === null) {
    return (
      <Tr>
        <Td className="text-on-surface-variant">{semanaCorta(f.semana)}</Td>
        <Td colSpan={5} className="type-panel-caption text-panel-muted">
          Sin financiamientos
        </Td>
      </Tr>
    )
  }

  return (
    <Tr>
      <Td className="whitespace-nowrap">{semanaCorta(f.semana)}</Td>
      <Td className="text-right tabular-nums">{formatUsd(f.consumoUsd)}</Td>
      <Td className="text-right tabular-nums">{f.personas}</Td>
      <Td>
        <EstadoDeCuota c={f.cuota1} titulo={`Cuota 1 · ${semanaCorta(f.semana)}`} />
      </Td>
      <Td>
        <EstadoDeCuota c={f.cuota2} titulo={`Cuota 2 · ${semanaCorta(f.semana)}`} />
      </Td>
      <Td className="text-right tabular-nums">
        <ImporteConDesglose desglose={vencido} />
      </Td>
    </Tr>
  )
}

/**
 * El veredicto de una cuota y, debajo, la barra de sus cinco estados de hoy,
 * con el globo del kit: cuántas cuotas hay en cada estado.
 */
function EstadoDeCuota({ c, titulo }: { c: CuotaDeCohorte | null; titulo: string }) {
  if (!c || c.cuotas === 0) return <span className="text-on-surface-variant">—</span>

  const filas = ESTADOS.map((e) => ({
    key: e.clave,
    rotulo: e.rotulo,
    valor: String(c[e.clave]),
    color: e.color,
    forma: 'punto' as const,
  }))
  const nota = `${c.cuotas} ${c.cuotas === 1 ? 'cuota' : 'cuotas'} · ${c.juzgadas} con el plazo cerrado`

  return (
    <div className="flex min-w-40 flex-col gap-1">
      <span className="flex items-baseline justify-between gap-2 type-panel-caption">
        <span className="font-semibold tabular-nums text-on-surface">
          {c.pctATiempo === null ? 'en plazo' : `${formatPorcentaje(c.pctATiempo, 0)} a tiempo`}
        </span>
        <span className="tabular-nums text-on-surface-variant">
          {c.juzgadas} de {c.cuotas} juzgadas
        </span>
      </span>
      <MarcaConGlobo titulo={titulo} filas={filas} nota={nota} className="flex py-1">
        <span className="flex h-1.5 w-full overflow-hidden rounded-full" style={{ backgroundColor: SERIE.vacio }}>
          {ESTADOS.map((e) =>
            c[e.clave] > 0 ? (
              <span key={e.clave} className="h-full" style={{ width: `${(100 * c[e.clave]) / c.cuotas}%`, backgroundColor: e.color }} />
            ) : null,
          )}
        </span>
      </MarcaConGlobo>
    </div>
  )
}
