import type { ReactNode } from 'react'

import { Table, Td, Tr } from '@/components/ui'
import type { TableHeader } from '@/components/ui'

/**
 * Los números de un gráfico, plegados debajo de él en un `<details>`: la
 * lectura que no depende del ratón ni del color. Todo gráfico de Métricas
 * lleva la suya (un globo nunca es la única manera de leer un número).
 *
 * La primera columna es el rótulo de la fila; las demás son cifras y van a la
 * derecha, con dígitos de ancho fijo para que se comparen en vertical.
 */
export function NumerosEnDetalles({
  cabeceras,
  filas,
  resumen = 'Ver los números',
  className = '',
}: {
  cabeceras: Array<TableHeader>
  /** Cada fila, con una celda por cabecera y las cifras ya escritas. */
  filas: ReadonlyArray<{ clave: string; celdas: ReadonlyArray<ReactNode> }>
  /** Lo que se lee plegado. */
  resumen?: string
  className?: string
}) {
  return (
    <details className={`group ${className}`}>
      <summary className="inline-flex cursor-pointer items-center gap-1.5 rounded-panel-control py-1 type-panel-caption font-semibold text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:text-on-surface">
        {resumen}
      </summary>
      <Table headers={cabeceras} className="mt-2">
        {filas.map((fila) => (
          <Tr key={fila.clave}>
            {fila.celdas.map((celda, i) => (
              <Td key={i} className={i === 0 ? '' : 'text-right tabular-nums'}>
                {celda}
              </Td>
            ))}
          </Tr>
        ))}
      </Table>
    </details>
  )
}
