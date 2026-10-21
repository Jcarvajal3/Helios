import { useQuery } from '@tanstack/react-query'

import { SkeletonList } from '@/components/ui'
import type { Rango } from '@/components/ui'
import { ChartCard } from '@/components/charts'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { NivelesDeUso } from '@/components/admin/crecimiento/NivelesDeUso'
import { NoSeParte } from '@/components/admin/metricas/kit'
import { UsuariosPorEstado } from '@/components/admin/tableros/UsuariosPorEstado'
import { consultaDelUso } from '@/features/admin/metricas/gente/consultas'
import { MOTIVO_ESTADOS } from '@/features/admin/metricas/gente/textos'

/**
 * Métricas › Pacientes, debajo del Resumen: cómo están las cuentas hoy y por
 * nivel.
 *
 * Es lo que queda de la antigua sub-pestaña Uso. El resto (medianas,
 * histogramas, concentración del gasto) era el análisis del gasto nocturno de
 * Ronda: en Helios un paciente vuelve cuando tiene otra consulta y su cupo lo
 * frena hasta pagar las dos cuotas. Los niveles se quedan: hoy solo está
 * activo el 1, y se encenderán más adelante.
 */
export function EstadosYNiveles({ rango, local }: { rango: Rango; local: string | null }) {
  const uso = useQuery(consultaDelUso(rango, local))

  if (uso.isPending) return <SkeletonList rows={4} />

  if (uso.isError) {
    return (
      <ErrorConReintento
        title="No se pudieron leer los estados de las cuentas"
        error={uso.error}
        onReintentar={() => void uso.refetch()}
      />
    )
  }

  const b = uso.data

  return (
    <div className="flex flex-col gap-10">
      <ChartCard
        titulo="Registros por estado de la cuenta"
        info="Todos los pacientes registrados por las clínicas, por el estado de su cuenta hoy: no sigue a la ventana. Cada estado abre el directorio filtrado por él."
      >
        {b.statuses ? (
          <UsuariosPorEstado filas={b.statuses.map((s) => ({ estado: s.status, personas: s.users }))} />
        ) : (
          <NoSeParte variante="bloque" motivo={MOTIVO_ESTADOS} />
        )}
      </ChartCard>

      <NivelesDeUso niveles={b.levels} />
    </div>
  )
}
