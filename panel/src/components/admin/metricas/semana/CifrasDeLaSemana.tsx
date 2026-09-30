import { CifraConTendencia } from '@/components/admin/metricas/kit'
import type { EstadoCifra } from '@/components/ui'
import type { BusquedaComun } from '@/features/admin/metricas/busqueda'
import { ORDEN_DE_CIFRAS, TITULOS_DE_CIFRAS } from '@/features/admin/metricas/semana/cifras'
import type { CifraDeLaSemana } from '@/features/admin/metricas/semana/cifras'
import { busquedaDeDestino } from '@/features/admin/metricas/semana/filas'

/**
 * Los títulos mientras no hay datos: el esqueleto tiene la misma forma que
 * las cifras, y los mismos nombres (salen de `cifras.ts`, no se repiten aquí).
 */
const TITULOS_EN_ESPERA = ORDEN_DE_CIFRAS.map((id) => ({ id, titulo: TITULOS_DE_CIFRAS[id] }))

/**
 * Las cinco cifras de la semana, cada una con su cambio frente a la anterior,
 * su chispa de ocho semanas y una línea. La tarjeta entera lleva a la pestaña
 * que la explica, con la misma semana y el mismo local.
 *
 * Cinco en fila cuando caben a 13rem cada una (la medida legible de un
 * `Stat`); antes, tres y dos (nunca cuatro y una sola debajo); en un móvil,
 * una debajo de otra. Mide su contenedor, no la ventana: el menú lateral
 * abierto no las aprieta.
 */
export function CifrasDeLaSemana({
  cifras,
  estado,
  onReintentar,
  comun,
}: {
  /** `null` mientras no hay respuesta (o si falló): van los títulos con su estado. */
  cifras: ReadonlyArray<CifraDeLaSemana> | null
  estado: EstadoCifra
  onReintentar: () => void
  comun: BusquedaComun
}) {
  return (
    <div className="@container">
      <div className="grid grid-cols-1 gap-4 @min-[41rem]:grid-cols-3 @min-[69rem]:grid-cols-5">
        {cifras && estado === 'listo'
          ? cifras.map((c) => (
              // `contents`: la tarjeta sigue siendo la celda de la rejilla, y
              // su chispa toma el tono de su área (el cobro en azul).
              <div key={c.id} data-area={c.tono} className="contents">
                <CifraConTendencia
                  titulo={c.titulo}
                  valor={c.valor}
                  delta={c.delta}
                  senal={c.senal}
                  pie={c.pie}
                  info={c.info}
                  chispa={c.chispa}
                  link={{ to: '/admin/metricas', search: busquedaDeDestino(c.destino, comun) }}
                />
              </div>
            ))
          : TITULOS_EN_ESPERA.map((c) => (
              <CifraConTendencia
                key={c.id}
                titulo={c.titulo}
                valor=""
                estado={estado}
                onReintentar={onReintentar}
              />
            ))}
      </div>
    </div>
  )
}
