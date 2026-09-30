import { Badge } from '@/components/ui'
import type { Pastilla } from '@/features/admin/metricas/cohortes/estados'

/**
 * En qué está una semana o una cuota: «Aún no vence», «11 % vencido»,
 * «Cobrada». La neutra va sin icono (no avisa de nada); las demás, con el de
 * su tono, para que se lean sin distinguir el color.
 */
export function PastillaDeEstado({ pastilla }: { pastilla: Pastilla }) {
  return (
    <Badge tone={pastilla.tono} icono={pastilla.tono !== 'neutral'}>
      {pastilla.texto}
    </Badge>
  )
}
