import { keepPreviousData, useQuery } from '@tanstack/react-query'

import { Card, NoSePudoLeer, Seccion, SkeletonCard } from '@/components/ui'
import { NoSeParte } from '@/components/admin/metricas/kit'
import { SemaforoDeCapital } from '@/components/admin/resumen/SemaforoDeCapital'
import { MOTIVO_CAPITAL } from '@/features/admin/metricas/caja/textos'
import { fetchCashPosition } from '@/features/admin/metrics'
import { fetchWeeklySummary } from '@/features/admin/resumen'
import { useIsSuperAdmin } from '@/features/admin/role'
import { useParametros } from '@/features/admin/useParametros'

/**
 * Las semanas que se piden para el ritmo del semáforo: las cuatro cerradas
 * más la en curso caben de sobra, y trece es lo que pide el Resumen por
 * defecto, así que la clave es la misma y no se consulta dos veces.
 */
const SEMANAS_DEL_RITMO = 13

/**
 * El capital comprometido y su semáforo, el de siempre: la pieza vive en
 * `components/admin/resumen/` y aquí se le dan sus lecturas, con las mismas
 * claves que Inicio y el Resumen (entrar desde allí no vuelve a consultar).
 *
 * Es de hoy, no de la semana elegida: el capital comprometido es una foto, y
 * el ritmo son las últimas cuatro semanas cerradas. Con un local no se parte.
 */
export function CapitalComprometido({ local }: { local: string | null }) {
  if (local) {
    return (
      <Seccion titulo="Capital">
        <NoSeParte variante="bloque" motivo={MOTIVO_CAPITAL} />
      </Seccion>
    )
  }
  return <SemaforoConSusLecturas />
}

function SemaforoConSusLecturas() {
  const esSuperAdmin = useIsSuperAdmin()
  const parametros = useParametros()
  const caja = useQuery({ queryKey: ['admin-cash'], queryFn: fetchCashPosition })
  const semanal = useQuery({
    queryKey: ['admin-weekly-summary', SEMANAS_DEL_RITMO],
    queryFn: () => fetchWeeklySummary(SEMANAS_DEL_RITMO),
    placeholderData: keepPreviousData,
  })

  // Sin las semanas no hay ritmo, y el semáforo diría «sin ritmo» como si
  // no hubiera historia: se espera o se dice que falló.
  if (semanal.isPending) {
    return (
      <Seccion titulo="Capital">
        <SkeletonCard />
      </Seccion>
    )
  }

  if (semanal.isError) {
    return (
      <Seccion titulo="Capital">
        <Card>
          <NoSePudoLeer onReintentar={() => void semanal.refetch()} />
        </Card>
      </Seccion>
    )
  }

  return (
    <SemaforoDeCapital
      parametros={parametros}
      caja={caja}
      semanas={semanal.data.rows}
      esSuperAdmin={esSuperAdmin}
    />
  )
}
