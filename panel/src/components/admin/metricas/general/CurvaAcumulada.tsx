import { SkeletonCard, formatUsd, formatUsdShort } from '@/components/ui'
import { LineChart } from '@/components/charts'
import { NoSeParte } from '@/components/admin/metricas/kit'
import {
  entero,
  puntosDeConsumo,
  puntosDeRegistros,
  resumenDeConsumo,
  resumenDeRegistros,
} from '@/features/admin/metricas/general/cifras'
import { CIFRAS_GENERAL as T } from '@/features/admin/metricas/general/textos'
import { BloqueGeneral } from './BloqueGeneral'
import type { LecturaGeneral } from './lectura'

/**
 * Cómo ha crecido el negocio: los registros y el consumo acumulados, semana a
 * semana desde la primera. Dos gráficos y no uno: son personas y euros, y en
 * un mismo eje uno de los dos saldría plano.
 *
 * Las líneas van en escalón (un acumulado sube el día en que entra algo) y
 * cada una escribe su última cifra, que es la más alta. La tabla está a un
 * clic, en la cabecera de cada gráfico, y cada semana enseña el globo del
 * kit al señalarla (ratón, dedo o flechas): el acumulado y lo de esa semana.
 * El consumo va sin el service fee, y lo dicen el título, la serie y el globo.
 */
export function CurvaAcumulada({ lectura }: { lectura: LecturaGeneral }) {
  const g = lectura.datos
  const cargando = lectura.estado === 'cargando' || !g

  return (
    <BloqueGeneral titulo={T.curva.titulo} info={T.curva.que} lectura={lectura}>
      <div className="@container">
        <div className="grid gap-4 @3xl:grid-cols-2">
          {cargando ? (
            <>
              <SkeletonCard />
              <SkeletonCard />
            </>
          ) : (
            <>
              {lectura.local !== null ? (
                <NoSeParte
                  variante="bloque"
                  motivo="Los registros no son de ninguna clínica. Quita la clínica de arriba para ver cómo ha crecido la gente."
                />
              ) : (
                <LineChart
                  title="Registros acumulados"
                  summary={resumenDeRegistros(g)}
                  series={[{ key: 'registros', label: 'Registros' }]}
                  points={puntosDeRegistros(g.curva, g.hoy) ?? []}
                  escalon
                  area
                  enteros
                  format={entero}
                  formatShort={entero}
                  ejeLabel="Semana"
                  unidadLabel="Esa semana"
                  empty="Todavía no hay registros."
                />
              )}
              <LineChart
                title="Total financiado acumulado (sin fee)"
                summary={resumenDeConsumo(g)}
                series={[{ key: 'consumo', label: 'Financiado (sin fee)' }]}
                points={puntosDeConsumo(g.curva, g.hoy)}
                escalon
                area
                format={formatUsd}
                formatShort={formatUsdShort}
                ejeLabel="Semana"
                unidadLabel="Esa semana"
                footnote="Sin el service fee. Cada semana va de lunes a domingo por día operativo."
                empty="Todavía no hay financiamientos."
              />
            </>
          )}
        </div>
      </div>
    </BloqueGeneral>
  )
}
