import { useQuery } from '@tanstack/react-query'

import { estadoDeConsulta } from '@/components/ui'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { FraseConCifras } from '@/components/admin/metricas/kit'
import { consultaGeneral } from '@/features/admin/metricas/general/api'
import { fraseGeneral } from '@/features/admin/metricas/general/cifras'
import type { BusquedaGeneral } from '@/features/admin/metricas/general/busqueda'
import type { PropsPestana } from '@/features/admin/metricas/tipos'
import { useParametros } from '@/features/admin/useParametros'
import { BloqueConsumo } from './BloqueConsumo'
import { BloqueDinero } from './BloqueDinero'
import { BloqueGente } from './BloqueGente'
import { BloqueRiesgo } from './BloqueRiesgo'
import { CurvaAcumulada } from './CurvaAcumulada'
import { PorCadaCienGeneral } from './PorCadaCienGeneral'
import type { LecturaGeneral } from './lectura'

/**
 * Métricas › Global › Resumen (la carpeta General): lo global del negocio
 * desde el primer día, sin
 * semanas. La gente, el consumo, el dinero, el riesgo, lo que deja cada
 * $100 y cómo ha crecido.
 *
 * Todo sale de una lectura (`admin_metricas_general`), que no pide la semana:
 * el marco cambia su selector por «Desde el inicio». Con un local elegido, lo
 * que es de un local se parte y lo que no (los registros, la caja) dice «No
 * se parte por local» en su sitio, nunca un cero.
 */
export function PestanaGeneral({ local, nombreLocal }: PropsPestana<BusquedaGeneral>) {
  const q = useQuery(consultaGeneral(local))
  const parametros = useParametros()

  // Mientras llega la respuesta de otro local se ve la anterior: lo que no
  // se parte, y el nombre de la frase, se deciden con el local de ESOS datos.
  const localDeLosDatos = q.data ? q.data.local : local
  const lectura: LecturaGeneral = {
    datos: q.data,
    estado: estadoDeConsulta(q),
    local: localDeLosDatos,
    reintentar: () => void q.refetch(),
  }
  const nombre = localDeLosDatos === local ? nombreLocal : null

  return (
    <div
      aria-busy={q.isFetching || undefined}
      className={`flex flex-col gap-8 transition-opacity duration-[var(--transition-fast)] ${
        q.isPlaceholderData ? 'opacity-60' : ''
      }`}
    >
      {q.isError ? (
        <ErrorConReintento
          title="No se pudieron leer las cifras de Global"
          error={q.error}
          onReintentar={() => void q.refetch()}
        />
      ) : (
        <FraseConCifras partes={q.data ? fraseGeneral(q.data, nombre) : []} cargando={q.isPending} />
      )}

      <BloqueGente lectura={lectura} />
      <BloqueConsumo lectura={lectura} />
      <BloqueDinero lectura={lectura} />
      <BloqueRiesgo lectura={lectura} parametros={parametros.data} />

      <div className="@container">
        <div className="grid gap-8 @5xl:grid-cols-[minmax(0,1fr)_minmax(0,2fr)]">
          <PorCadaCienGeneral lectura={lectura} />
          <CurvaAcumulada lectura={lectura} />
        </div>
      </div>
    </div>
  )
}
