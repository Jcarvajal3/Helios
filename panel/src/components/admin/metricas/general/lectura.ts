import type { EstadoCifra } from '@/components/ui'
import type { General } from '@/features/admin/metricas/general/tipos'

/**
 * Lo que recibe cada bloque de General: la misma lectura para todos.
 *
 * `local` es el de los DATOS que se enseñan, no el que se acaba de pedir:
 * mientras llega la respuesta de otro local se ve la anterior, y lo que no se
 * parte tiene que decidirse con el local al que pertenecen esas cifras.
 */
export type LecturaGeneral = {
  datos: General | undefined
  estado: EstadoCifra
  local: string | null
  reintentar: () => void
}
