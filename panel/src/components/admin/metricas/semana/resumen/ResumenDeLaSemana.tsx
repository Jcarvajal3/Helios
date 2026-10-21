import { useQuery } from '@tanstack/react-query'

import { estadoDeConsulta } from '@/components/ui'
import type { BusquedaSemana } from '@/features/admin/metricas/semana/busqueda'
import { consultaDelResumen } from '@/features/admin/metricas/semana/resumen/api'
import { cifrasDelResumen, lineaDeLaComparacion } from '@/features/admin/metricas/semana/resumen/cifras'
import type { PropsPestana } from '@/features/admin/metricas/tipos'
import { CifrasDelResumen } from './CifrasDelResumen'

/**
 * Semana › Resumen: ¿cuánto se facturó esta semana, cuánto hay que cobrar y
 * cuánta gente vino?
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Arriba, el desglose que suma —Total facturado (sin comisión) + Comisión Helios + IVA
 * = Total a cobrar— y los consumos y los usuarios, cada cifra frente a la
 * semana anterior a la misma altura y con su chispa de ocho semanas. Sale de
 * `admin_metricas_semana_resumen`, que respeta la semana y el local de arriba.
 *
 * Pinta lo que usó la base (su semana y su «hoy»), no lo que pidió el
 * navegador.
 */
export function ResumenDeLaSemana({ semana, local }: PropsPestana<BusquedaSemana>) {
  const consulta = useQuery(consultaDelResumen(semana, local))

  const respuesta = consulta.data
  // Mientras llega lo nuevo se queda a la vista lo anterior, atenuado. Si lo
  // anterior es de otro local, no: esas cifras dirían otra cosa que el
  // selector de arriba, y va el esqueleto.
  const deOtroLocal = consulta.isPlaceholderData && respuesta !== undefined && respuesta.local !== local
  const estado = deOtroLocal ? 'cargando' : estadoDeConsulta(consulta)
  const actualizando = consulta.isPlaceholderData && !deOtroLocal
  const reintentar = () => void consulta.refetch()

  const cifras = respuesta && estado === 'listo' ? cifrasDelResumen(respuesta) : null

  return (
    <div className="flex flex-col gap-6">
      <div
        aria-busy={actualizando || undefined}
        className={`transition-opacity duration-[var(--transition-fast)] ${actualizando ? 'opacity-60' : ''}`}
      >
        <CifrasDelResumen
          cifras={cifras}
          estado={estado}
          onReintentar={reintentar}
          linea={respuesta && estado === 'listo' ? lineaDeLaComparacion(respuesta) : null}
        />
      </div>

    </div>
  )
}
