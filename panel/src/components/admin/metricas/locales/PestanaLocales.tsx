import { useQuery } from '@tanstack/react-query'

import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { SkeletonBlock, SkeletonStats, SkeletonTable } from '@/components/ui'
import { consultaDeLocales } from '@/features/admin/metricas/locales/consultas'
import type { BusquedaLocales } from '@/features/admin/metricas/locales/busqueda'
import type { PropsPestana } from '@/features/admin/metricas/tipos'
import { useParametros } from '@/features/admin/useParametros'

import { LocalesEnLaSemana } from './LocalesEnLaSemana'
import { FichaDelLocal } from './ficha/FichaDelLocal'

/**
 * Métricas › Locales.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Sin local elegido: dónde se consumió la semana, local a local, y cómo paga
 * la gente de cada uno (`LocalesEnLaSemana`). Pulsar un local lo pone en el
 * selector de arriba, y entonces esta pestaña enseña su ficha analítica
 * (`FichaDelLocal`) y las demás pestañas lo miran solo a él.
 *
 * Una sola lectura para las dos vistas, `admin_metricas_locales`, que lo
 * cuenta todo desde el esquema `metricas`: las cifras de la tabla, de los
 * gráficos y de la ficha cuadran entre sí porque salen de la misma
 * respuesta. Las noches y la cartera de un local se leen aparte, cada una en
 * su bloque.
 */
export function PestanaLocales({ semana, local }: PropsPestana<BusquedaLocales>) {
  const q = useQuery(consultaDeLocales(semana, local))
  const parametros = useParametros()

  // Mientras llega otra semana o se cambia de local, TanStack deja a la vista
  // la respuesta anterior. Si era la de otro local (o la de todos), no se
  // pinta: la ficha de uno con las cifras de otro sería peor que esperar.
  const deOtroLocal = q.data !== undefined && q.data.local !== local

  if (q.isError && !q.data) {
    return (
      <ErrorConReintento
        title="No se pudieron leer las clínicas de la semana"
        error={q.error}
        onReintentar={() => void q.refetch()}
      />
    )
  }

  if (q.isPending || deOtroLocal) return <Esqueleto conLocal={local !== null} />

  return (
    <div
      aria-busy={q.isPlaceholderData || undefined}
      className={`flex flex-col gap-6 transition-opacity duration-[var(--transition-fast)] ${
        q.isPlaceholderData ? 'opacity-60' : ''
      }`}
    >
      {q.isError && (
        <ErrorConReintento
          title="No se pudo leer esta semana: lo que se ve es la anterior"
          error={q.error}
          onReintentar={() => void q.refetch()}
        />
      )}
      {local === null ? (
        <LocalesEnLaSemana d={q.data} parametros={parametros.data} />
      ) : (
        <FichaDelLocal d={q.data} local={local} parametros={parametros.data} />
      )}
    </div>
  )
}

/** La forma de la pestaña mientras llega: la frase y la tabla, o las cifras del local. */
function Esqueleto({ conLocal }: { conLocal: boolean }) {
  return (
    <div aria-busy className="flex flex-col gap-6">
      <SkeletonBlock className="h-5 w-3/5" />
      {conLocal ? <SkeletonStats count={8} cols={4} /> : <SkeletonTable rows={4} columns={8} />}
      <div className="grid gap-4 xl:grid-cols-2">
        <SkeletonBlock className="h-48" />
        <SkeletonBlock className="h-48" />
      </div>
    </div>
  )
}
