import { Link } from '@tanstack/react-router'
import { ArrowLeft } from 'lucide-react'

import { FraseConCifras } from '@/components/admin/metricas/kit'
import { EmptyState } from '@/components/ui'
import { busquedaConLocal } from '@/features/admin/metricas/locales/consultas'
import { serieDelLocal } from '@/features/admin/metricas/locales/ficha'
import { fraseDelLocal } from '@/features/admin/metricas/locales/frase'
import type { LocalesDeLaSemana } from '@/features/admin/metricas/locales/tipos'
import type { Parametros } from '@/features/admin/parametros'

import { CarteraDelLocal } from './CarteraDelLocal'
import { CifrasDelLocal } from './CifrasDelLocal'
import { CohortesDelLocal } from './CohortesDelLocal'
import { SerieDelLocal } from './SerieDelLocal'

/**
 * La ficha analítica de un local: lo que se ve en Locales con un local
 * elegido arriba.
 *
 * De arriba abajo: la frase, sus cifras de la semana, su consumo semana a
 * semana, cómo paga su gente semana de consumo a semana de
 * consumo, y su cartera al cierre. Para quitarlo, el selector de arriba o
 * «Todos los locales».
 */
export function FichaDelLocal({
  d,
  local,
  parametros,
}: {
  d: LocalesDeLaSemana
  local: string
  parametros: Parametros | undefined
}) {
  const fila = d.locales.find((l) => l.merchantId === local)
  const volver = (
    <Link
      to="/admin/metricas"
      search={busquedaConLocal({ semana: d.semana.desde, enCurso: d.semana.enCurso, local: null })}
      className="inline-flex items-center gap-1.5 type-panel-caption font-semibold text-on-surface-variant hover:text-on-surface"
    >
      <ArrowLeft size={14} aria-hidden />
      Todas las clínicas
    </Link>
  )

  if (!fila) {
    return (
      <div className="flex flex-col gap-4">
        {volver}
        <EmptyState
          title="Esta clínica no está entre los de Helios"
          description="Puede ser una clínica de prueba, uno que ya no existe o un enlace mal copiado. Elige otro arriba."
        />
      </div>
    )
  }

  const serie = serieDelLocal(d, local)

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-start justify-between gap-x-6 gap-y-2">
        <FraseConCifras partes={fraseDelLocal(d, fila)} />
        {volver}
      </div>

      <CifrasDelLocal d={d} l={fila} serie={serie} parametros={parametros} />

      <SerieDelLocal d={d} serie={serie} />

      <CohortesDelLocal d={d} local={local} />

      <CarteraDelLocal semana={d.semana.desde} enCurso={d.semana.enCurso} local={local} parametros={parametros} />
    </div>
  )
}
