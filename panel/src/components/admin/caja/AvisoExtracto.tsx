import { useQuery } from '@tanstack/react-query'
import { Upload } from 'lucide-react'

import { Button, Callout } from '@/components/ui'
import { fetchStatementImports } from '@/features/admin/api'
import { extractoViejo } from '@/features/admin/colaDePagos'

/**
 * Una línea encima de la lista cuando el extracto del banco se ha quedado
 * viejo, con el botón para importarlo.
 *
 * Vivía solo dentro de la ventana de importar, que es justo donde no se mira:
 * quien no sabe que el extracto está viejo no abre esa ventana. Sin extracto
 * al día, un pago «no aparece» y la lista de abonos sin dueño sale vacía sin
 * que nada esté bien.
 *
 * Si no se puede leer cuándo se importó, lo dice: callarse ahí sería dar el
 * extracto por bueno.
 */
export function AvisoExtracto({ onImportar }: { onImportar: () => void }) {
  const query = useQuery({
    queryKey: ['statement-imports', 1],
    queryFn: () => fetchStatementImports(1),
  })

  if (query.isError) {
    return (
      <Callout
        tone="warning"
        titulo="No se pudo leer cuándo se importó el extracto"
        accion={
          <Button size="sm" variant="tonal" onClick={() => void query.refetch()}>
            Reintentar
          </Button>
        }
        className="mb-4"
      />
    )
  }

  if (!query.data || !extractoViejo(query.data.daysSinceLast)) return null

  const dias = query.data.daysSinceLast

  return (
    <Callout
      tone="warning"
      titulo={
        dias === null
          ? 'Nunca se ha importado el extracto del banco'
          : `El extracto tiene ${dias} días`
      }
      accion={
        <Button size="sm" variant="tonal" onClick={onImportar}>
          <Upload size={14} aria-hidden /> Importar
        </Button>
      }
      className="mb-4"
    >
      {dias === null
        ? 'Ningún pago se puede cotejar con el banco.'
        : 'Los pagos de después no se pueden cotejar.'}
    </Callout>
  )
}
