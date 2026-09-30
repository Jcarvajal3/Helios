import { useId, useState } from 'react'
import type { UseQueryResult } from '@tanstack/react-query'

import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { Button, DataLabel, SkeletonBlock } from '@/components/ui'
import type { ListaDeCohortes } from '@/features/admin/metricas/cohortes/tipos'
import { nombreDeCohorte } from '@/features/admin/metricas/cohortes/semanas'
import { FilaDeSemana } from './FilaDeSemana'

/** Las que se ven sin pedir más: un trimestre. */
const A_LA_VISTA = 12

type Props = {
  lista: UseQueryResult<ListaDeCohortes>
  /** El lunes de la primera cohorte de todos los locales: de él salen los nombres (A1, A2…). */
  primerLunes: string | null
  semana: string
  hoy: string
  local: string | null
  nombreLocal: string | null
}

/**
 * La columna de la izquierda: todas las semanas de consumo, de la más
 * reciente a la más vieja, cada una con lo que hay que cobrar de ella y cómo
 * va. La elegida es la que se ve a la derecha.
 */
export function ListaDeSemanas(props: Props) {
  const id = useId()

  return (
    <aside
      aria-labelledby={id}
      className="flex flex-col gap-2.5 rounded-panel-card border border-panel-hairline bg-panel-card p-3"
    >
      <DataLabel className="px-1.5 pt-1">
        <span id={id}>Cohortes (semanas de financiamiento)</span>
      </DataLabel>
      <CuerpoDeLaLista {...props} />
    </aside>
  )
}

function CuerpoDeLaLista({ lista, semana, hoy, local, nombreLocal, primerLunes }: Props) {
  const [todas, setTodas] = useState(false)

  if (lista.isPending) {
    return (
      <div aria-busy className="flex flex-col gap-2 px-1.5">
        {Array.from({ length: 6 }, (_, i) => (
          <SkeletonBlock key={i} className="h-19 w-full" />
        ))}
      </div>
    )
  }
  if (lista.isError) {
    return (
      <ErrorConReintento
        title="No se pudieron leer las semanas"
        error={lista.error}
        onReintentar={() => void lista.refetch()}
      />
    )
  }

  const cohortes = lista.data.cohortes
  if (cohortes.length === 0) {
    return (
      <p className="px-1.5 pb-2 type-panel-body text-on-surface-variant">
        {nombreLocal ? `${nombreLocal} todavía no tiene financiamientos.` : 'Todavía no hay financiamientos.'}
      </p>
    )
  }

  // La elegida siempre a la vista, aunque sea vieja.
  const posicion = cohortes.findIndex((c) => c.semana === semana)
  const cuantas = todas ? cohortes.length : Math.max(A_LA_VISTA, posicion + 1)
  const vistas = cohortes.slice(0, cuantas)
  const quedan = cohortes.length - vistas.length

  return (
    // Con otro local elegido, la lista del anterior se ve atenuada hasta que
    // llega la nueva: no se puede confundir con la buena.
    <div
      aria-busy={lista.isPlaceholderData || undefined}
      className={`flex flex-col gap-1 transition-opacity duration-[var(--transition-fast)] ${
        lista.isPlaceholderData ? 'opacity-60' : ''
      }`}
    >
      {vistas.map((c) => (
        <FilaDeSemana
          key={c.semana}
          nombre={primerLunes ? nombreDeCohorte(c.semana, primerLunes) : null}
          cohorte={c}
          activa={c.semana === semana}
          hoy={hoy}
          local={local}
        />
      ))}
      {quedan > 0 && (
        <Button variant="text" size="sm" onClick={() => setTodas(true)} className="mt-1 self-start">
          Ver {quedan === 1 ? 'la semana anterior' : `las ${quedan} semanas anteriores`}
        </Button>
      )}
    </div>
  )
}
