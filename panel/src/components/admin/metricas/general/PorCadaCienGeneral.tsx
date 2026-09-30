import { Card, SkeletonCard } from '@/components/ui'
import { Desglose } from '@/components/admin/tableros/Desglose'
import { lineasPorCadaCien, notaDeMadurez, resumenPorCadaCien } from '@/features/admin/metricas/general/cifras'
import { CIFRAS_GENERAL as T } from '@/features/admin/metricas/general/textos'
import { BloqueGeneral } from './BloqueGeneral'
import type { LecturaGeneral } from './lectura'

/**
 * «Por cada €100 financiados», desde el primer día: lo que entra por el
 * service fee y por los cargos por atraso y el margen que queda después del
 * impago (lo perdido no lleva línea: es el «Impago (%)» del bloque Riesgo).
 * Los cien euros son el denominador, no una línea.
 *
 * Debajo, qué parte de ese consumo ya cerró su ciclo de cobro: hasta
 * entonces lo perdido puede crecer y el margen es provisional.
 */
export function PorCadaCienGeneral({ lectura }: { lectura: LecturaGeneral }) {
  const p = lectura.datos?.porCadaCien
  const lineas = p ? lineasPorCadaCien(p) : null
  const nota = p ? notaDeMadurez(p) : null

  return (
    <BloqueGeneral titulo={T.porCadaCien.titulo} info={T.porCadaCien.que} lectura={lectura}>
      {lectura.estado === 'cargando' || !p ? (
        <SkeletonCard />
      ) : (
        <Card className="flex flex-col gap-4">
          <p className="type-panel-body text-on-surface-variant">{resumenPorCadaCien(p)}</p>
          {lineas === null ? (
            <p className="type-panel-body text-panel-muted">
              Sin financiamiento no hay nada que repartir.
            </p>
          ) : (
            <Desglose lineas={lineas} />
          )}
          {nota && <p className="type-panel-caption text-panel-muted">{nota}</p>}
        </Card>
      )}
    </BloqueGeneral>
  )
}
