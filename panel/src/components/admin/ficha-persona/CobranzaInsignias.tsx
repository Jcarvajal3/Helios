import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { Badge } from '@/components/ui'
import { RESULTADO } from '@/features/admin/cobranza/gestion'
import type { Resultado } from '@/features/admin/cobranza/gestion'
import type { EstadoPromesa } from '@/features/admin/estados'

/*
 * Las insignias de Cobranza: qué pasó en una gestión y en qué quedó una
 * promesa. Se pintan igual en la lista, en las promesas y en el caso.
 */

/** Qué pasó en la gestión. Las anteriores al resultado no llevan insignia. */
export function InsigniaResultado({ resultado }: { resultado: Resultado | null }) {
  if (!resultado) return null
  const r = RESULTADO[resultado]
  return (
    <Badge tone={r.tone} icono>
      {r.label}
    </Badge>
  )
}

/** En qué quedó la promesa. Sin promesa, nada. */
export function InsigniaPromesa({ estado }: { estado: EstadoPromesa | null }) {
  if (!estado) return null
  return <EstadoBadge tipo="promesa" valor={estado} />
}
