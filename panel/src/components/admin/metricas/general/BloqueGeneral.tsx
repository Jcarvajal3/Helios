import type { ReactNode } from 'react'

import { NoSePudoLeer, Seccion } from '@/components/ui'
import type { LecturaGeneral } from './lectura'

/**
 * Un bloque de General: su título con el InfoDot y sus cifras.
 *
 * Si la lectura falla, el bloque lo dice en una línea con «Reintentar» en vez
 * de pintar sus tarjetas: todas sus cifras salen de la misma respuesta, y
 * veinte «No se pudo leer» seguidos no dicen más que uno. El mensaje entero
 * del error va una vez, arriba de la pestaña.
 */
export function BloqueGeneral({
  titulo,
  info,
  lectura,
  children,
}: {
  titulo: string
  info?: string
  lectura: LecturaGeneral
  children: ReactNode
}) {
  return (
    <Seccion titulo={titulo} info={info}>
      {lectura.estado === 'error' ? (
        <div className="rounded-panel-card border border-panel-hairline bg-panel-card p-panel-pad-card">
          <NoSePudoLeer onReintentar={lectura.reintentar} />
        </div>
      ) : (
        children
      )}
    </Seccion>
  )
}
