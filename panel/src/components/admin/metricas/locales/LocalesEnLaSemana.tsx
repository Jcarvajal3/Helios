import { Store } from 'lucide-react'

import { FraseConCifras } from '@/components/admin/metricas/kit'
import { EmptyState } from '@/components/ui'
import { fraseDeLaSemana } from '@/features/admin/metricas/locales/frase'
import type { LocalesDeLaSemana } from '@/features/admin/metricas/locales/tipos'
import type { Parametros } from '@/features/admin/parametros'

import { ComoPagaLaGente } from './ComoPagaLaGente'
import { ConsumoPorSemana } from './ConsumoPorSemana'
import { TablaDeLocales } from './TablaDeLocales'

/**
 * Locales sin un local elegido: la frase, la tabla de la semana, el consumo
 * de cada uno semana a semana con la misma escala y cómo paga su gente. Los
 * usuarios nuevos y los que repiten, por local, son columnas de la tabla.
 */
export function LocalesEnLaSemana({ d, parametros }: { d: LocalesDeLaSemana; parametros: Parametros | undefined }) {
  if (d.locales.length === 0) {
    return (
      <EmptyState
        icon={<Store size={40} aria-hidden />}
        title="Todavía no hay clínicas"
        description="Esta pestaña se llena en cuanto haya una clínica dado de alta y activo."
      />
    )
  }

  return (
    <div className="flex flex-col gap-6">
      <FraseConCifras partes={fraseDeLaSemana(d)} />

      <TablaDeLocales d={d} parametros={parametros} />

      <div className="grid gap-4 xl:grid-cols-2">
        <ConsumoPorSemana d={d} />
        <ComoPagaLaGente d={d} parametros={parametros} />
      </div>
    </div>
  )
}
