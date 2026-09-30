import { useQuery } from '@tanstack/react-query'

import { FilterBar, Filtro, InfoDot, Segmented } from '@/components/ui'
import type { Rango } from '@/components/ui'
import { consultaDelTablero } from '@/features/admin/metricas/gente/consultas'
import { OPCIONES_DE_VENTANA, textoDeLaVentana } from '@/features/admin/metricas/gente/ventana'
import type { VentanaGente } from '@/features/admin/metricas/gente/ventana'

const COMO_SE_CUENTA =
  'Todos los importes de Gente son financiado, sin el service fee: la suma de los financiamientos confirmados, y en un financiamiento de grupo la parte de cada paciente. El día es el operativo, de 10 de la mañana a 10 de la mañana. La ventana acaba el domingo de la semana elegida arriba (o hoy, si está en curso).'

/**
 * La ventana de Resumen, Uso y Grupos: cuántas semanas se miran, acabando en
 * la semana elegida arriba. Debajo, los días que USÓ la base (puede haber
 * recortado el «desde» al primer día de Ronda) y contra qué se comparan las
 * flechas, una sola vez.
 *
 * Los días usados salen del tablero, con la misma clave que Resumen y Uso:
 * no es otra consulta.
 */
export function BarraDeVentana({
  ventana,
  rango,
  local,
  comparacion,
  onVentana,
}: {
  ventana: VentanaGente
  rango: Rango
  local: string | null
  comparacion: string | null
  onVentana: (ventana: VentanaGente) => void
}) {
  const tablero = useQuery(consultaDelTablero(rango, local))
  const usado = tablero.data

  return (
    <div className="flex flex-col gap-2">
      <FilterBar>
        <Filtro label="Ventana">
          <Segmented etiqueta="Ventana" options={[...OPCIONES_DE_VENTANA]} value={ventana} onChange={onVentana} />
        </Filtro>
      </FilterBar>
      <p className="flex flex-wrap items-center gap-x-1.5 type-panel-caption text-panel-muted">
        {usado ? textoDeLaVentana({ from: usado.from, to: usado.to }, usado.windowDays) : ' '}
        {comparacion && <span>· {comparacion}</span>}
        <span>· Importes en financiado, sin el service fee</span>
        <InfoDot title="Cómo se cuenta" what={COMO_SE_CUENTA} />
      </p>
    </div>
  )
}
