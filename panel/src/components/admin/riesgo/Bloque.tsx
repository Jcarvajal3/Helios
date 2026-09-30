import type { ReactNode } from 'react'

import { Card, NoSePudoLeer, Seccion, SkeletonList } from '@/components/ui'

/** Lo que `Bloque` necesita de un `useQuery`. */
export type ConsultaDeBloque<T> = {
  data: T | undefined
  isError: boolean
  refetch: () => unknown
}

/**
 * Un bloque de una pantalla de cifras: su sección y lo que sale de UNA
 * consulta.
 *
 * Mientras carga, un esqueleto; si falla, «No se pudo leer» con su botón, en
 * el sitio del contenido. Nunca un título suelto sin nada debajo, ni una
 * lista vacía que se lea como «no hay nada». Los controles del bloque (un
 * filtro, un enlace) van a la derecha del título, en la misma línea.
 */
export function Bloque<T>({
  titulo,
  info,
  aside,
  consulta,
  filas = 3,
  className = '',
  children,
}: {
  titulo: string
  /** Qué es y cómo se calcula, en el `InfoDot` junto al título. */
  info?: string
  /** Lo que va a la derecha del título: un filtro, un enlace. */
  aside?: ReactNode
  consulta: ConsultaDeBloque<T>
  /** Cuántas filas tiene el esqueleto. */
  filas?: number
  className?: string
  children: (data: T) => ReactNode
}) {
  return (
    <Seccion titulo={titulo} info={info} controles={aside} className={className}>
      {consulta.isError ? (
        <Card>
          <NoSePudoLeer onReintentar={() => void consulta.refetch()} />
        </Card>
      ) : consulta.data === undefined ? (
        <SkeletonList rows={filas} />
      ) : (
        children(consulta.data)
      )}
    </Seccion>
  )
}
