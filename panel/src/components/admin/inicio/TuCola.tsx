import { ordenarColas, tieneTrabajo } from './colas'
import { FilaDeCola } from './FilaDeCola'
import { useColas } from './useColas'

/**
 * «Tu cola» entera: una fila por cada lista de trabajo de los cuatro equipos,
 * de la más urgente a la que puede esperar, y las vacías al final. Se abre
 * desde «Ver toda la cola» de Inicio, que solo enseña las cuatro primeras
 * con trabajo; aquí están también las que no tienen nada.
 */
export function TuCola() {
  const colas = ordenarColas(useColas())

  const principal = colas.find((c) => tieneTrabajo(c.lectura))?.id

  return (
    <ul aria-label="Colas de trabajo" className="divide-y divide-panel-hairline">
      {colas.map((cola) => (
        <FilaDeCola key={cola.id} cola={cola} principal={cola.id === principal} />
      ))}
    </ul>
  )
}
