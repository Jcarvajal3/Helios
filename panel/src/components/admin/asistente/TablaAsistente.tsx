import { Table, Td, Tr } from '@/components/ui'
import type { Tabla } from '@/features/admin/asistente/protocolo'
import { esColumnaDeCifras, formatearCelda } from '@/features/admin/asistente/unidades'

/**
 * Una tabla que pide el asistente, con la `Table` del kit. Las columnas con
 * unidad se escriben con su formato y se alinean a la derecha, como las
 * cifras de cualquier tabla del panel. Una celda sin dato es una raya.
 */
export function TablaAsistente({ tabla }: { tabla: Tabla }) {
  return (
    <div className="flex min-w-0 flex-col gap-2">
      <p className="type-panel-body font-semibold text-on-surface">{tabla.titulo}</p>
      {tabla.filas.length === 0 ? (
        <p className="type-panel-body text-on-surface-variant">La consulta no devolvió filas.</p>
      ) : (
        <Table headers={tabla.columnas.map((c) => c.rotulo)}>
          {tabla.filas.map((fila, i) => (
            <Tr key={i}>
              {tabla.columnas.map((c) => (
                <Td
                  key={c.clave}
                  className={esColumnaDeCifras(c.unidad) ? 'text-right tabular-nums' : ''}
                >
                  {formatearCelda(fila[c.clave], c.unidad)}
                </Td>
              ))}
            </Tr>
          ))}
        </Table>
      )}
    </div>
  )
}
