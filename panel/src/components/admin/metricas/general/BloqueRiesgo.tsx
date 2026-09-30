import { StatGrid } from '@/components/ui'
import { CifraConTendencia } from '@/components/admin/metricas/kit'
import {
  cuotaATiempo,
  pctOGuion,
  pieCuotaATiempo,
  pieImpago,
  pieMora,
  senalCuotaATiempo,
  senalImpago,
  senalMora,
} from '@/features/admin/metricas/general/cifras'
import { CIFRAS_GENERAL as T } from '@/features/admin/metricas/general/textos'
import type { Parametros } from '@/features/admin/parametros'
import { BloqueGeneral } from './BloqueGeneral'
import type { LecturaGeneral } from './lectura'

/**
 * El riesgo: la mora de hoy, el impago de toda la historia frente al punto
 * de empate, y el cobro a tiempo de la cuota 1 y de la 2. Cada cifra lleva
 * su pastilla solo si cruza un umbral de los parámetros.
 */
export function BloqueRiesgo({
  lectura,
  parametros,
}: {
  lectura: LecturaGeneral
  /** Los umbrales. Sin ellos no hay pastillas: un color inventado es peor que ninguno. */
  parametros: Parametros | undefined
}) {
  const { datos: g, estado, local, reintentar } = lectura
  const conLocal = local ?? undefined
  const cuota1 = g && cuotaATiempo(g, 1)
  const cuota2 = g && cuotaATiempo(g, 2)

  return (
    <BloqueGeneral titulo="Riesgo desde el inicio" lectura={lectura}>
      <StatGrid cols={4}>
        <CifraConTendencia
          titulo={T.mora.titulo}
          info={T.mora.que}
          valor={g ? pctOGuion(g.riesgo.moraPct) : ''}
          senal={g && senalMora(g, parametros)}
          pie={g && pieMora(g)}
          link={{ to: '/admin/metricas', search: { vista: 'mora', local: conLocal } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={T.impago.titulo}
          info={T.impago.que}
          valor={g ? pctOGuion(g.riesgo.impagoPct) : ''}
          senal={g && senalImpago(g, parametros)}
          pie={g && pieImpago(g)}
          link={{ to: '/admin/metricas', search: { vista: 'mora', local: conLocal } }}
          estado={estado}
          onReintentar={reintentar}
        />
        {[
          { n: 1, c: cuota1 },
          { n: 2, c: cuota2 },
        ].map(({ n, c }) => (
          <CifraConTendencia
            key={n}
            titulo={`Cuota ${n} a tiempo`}
            info={T.cuotaATiempo.que}
            valor={g ? pctOGuion(c?.pct ?? null) : ''}
            senal={g && senalCuotaATiempo(c, parametros)}
            pie={g && pieCuotaATiempo(c)}
            link={{ to: '/admin/metricas', search: { vista: 'cobros', sub: 'calendario', local: conLocal } }}
            estado={estado}
            onReintentar={reintentar}
          />
        ))}
      </StatGrid>
    </BloqueGeneral>
  )
}
