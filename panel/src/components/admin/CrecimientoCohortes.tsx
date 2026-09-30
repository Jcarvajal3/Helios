import { useQuery } from '@tanstack/react-query'

import { FilterBar, Filtro, Segmented, SkeletonList, SkeletonStats } from '@/components/ui'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { TodasLasCohortes } from '@/components/admin/crecimiento/TodasLasCohortes'
import { UnaCohorte } from '@/components/admin/crecimiento/UnaCohorte'
import {
  GRANO_DE_CUBO,
  OPCIONES_DE_CUBO,
  OPCIONES_DE_VER,
  PERIODOS,
  UNIDAD,
  cohorteDeLaSemana,
  periodosValidos,
} from '@/components/admin/crecimiento/cohortes'
import type { Cubo, Medida, VerCohortes } from '@/components/admin/crecimiento/cohortes'
import { consultaDeRetencion } from '@/features/admin/metricas/gente/consultas'

/** Todo lo que se elige en la Retención. Vive en la URL. */
export type EstadoDeCohortes = {
  cubo: Cubo
  /** Cuántos cubos. Si no vale para el cubo elegido, se usa el primero. */
  cuantos: number | undefined
  ver: VerCohortes
  medida: Medida
  /** El primer día de la cohorte elegida. Sin él, la de la semana elegida arriba. */
  cohorte: string | undefined
}

/**
 * Retención: la gente que entró junta, ¿siguió junta?
 * ══════════════════════════════════════════════════════════════════════════
 *
 * La única vista del panel que contesta si el producto retiene, separando a
 * la gente por CUÁNDO entró: una cohorte no se puede inflar con crecimiento,
 * sigue siempre a las mismas personas. Sin local, entrar es registrarse; con
 * un local, es llegar a ese local (su primera cuota allí).
 *
 * Se entra eligiendo UNA cohorte —la de la semana elegida arriba si ya
 * cerró; con la semana en curso, la más reciente que ya tenga un «después»,
 * porque la de esta semana solo tiene su columna 0— y se lee su historia con
 * las piezas de siempre. «Comparar todas»
 * (la rejilla de analista) es el segundo paso. Su eje es el cubo y cuántos,
 * acabando hoy: una cohorte se mide en periodos desde que entró.
 */
export function CrecimientoCohortes({
  estado,
  onCambiar,
  local,
  lunes,
  enCurso,
}: {
  estado: EstadoDeCohortes
  onCambiar: (cambios: Partial<EstadoDeCohortes>) => void
  local: string | null
  /** El lunes de la semana elegida arriba: su cohorte es la que abre. */
  lunes: string
  /** La semana elegida es la de hoy: su cohorte acaba de nacer. */
  enCurso: boolean
}) {
  const grain = GRANO_DE_CUBO[estado.cubo]
  const periods = periodosValidos(grain, estado.cuantos)
  const unidad = UNIDAD[grain]
  const elegida = estado.cohorte ?? (enCurso ? undefined : cohorteDeLaSemana(grain, lunes))

  const cohortes = useQuery(consultaDeRetencion(grain, periods, local))

  return (
    <div className="flex flex-col gap-6">
      <FilterBar>
        <Filtro label="Agrupar por">
          <Segmented
            options={OPCIONES_DE_CUBO}
            value={estado.cubo}
            // Los cubos del anterior no valen para el nuevo, y la cohorte
            // elegida deja de existir: vuelve a la de la semana.
            onChange={(cubo) => onCambiar({ cubo, cuantos: undefined, cohorte: undefined })}
          />
        </Filtro>
        <Filtro label={`Cuántos ${unidad.unos}`}>
          <Segmented
            options={PERIODOS[grain].map((n) => ({ value: String(n), label: String(n) }))}
            value={String(periods)}
            onChange={(v) => onCambiar({ cuantos: Number(v), cohorte: undefined })}
          />
        </Filtro>
        <Filtro label="Ver">
          <Segmented options={OPCIONES_DE_VER} value={estado.ver} onChange={(ver) => onCambiar({ ver })} />
        </Filtro>
      </FilterBar>

      {cohortes.isPending && (
        <>
          <SkeletonStats count={4} cols={4} />
          <SkeletonList rows={6} />
        </>
      )}

      {cohortes.isError && (
        <ErrorConReintento
          title="No se pudo leer la retención"
          error={cohortes.error}
          onReintentar={() => void cohortes.refetch()}
        />
      )}

      {cohortes.data &&
        !cohortes.isError &&
        (estado.ver === 'una' ? (
          <UnaCohorte
            data={cohortes.data}
            elegida={elegida}
            onElegir={(cohorte) => onCambiar({ cohorte })}
            medida={estado.medida}
            onMedida={(medida) => onCambiar({ medida })}
          />
        ) : (
          <TodasLasCohortes
            data={cohortes.data}
            medida={estado.medida}
            onMedida={(medida) => onCambiar({ medida })}
            onAbrir={(cohorte) => onCambiar({ cohorte, ver: 'una' })}
          />
        ))}
    </div>
  )
}
