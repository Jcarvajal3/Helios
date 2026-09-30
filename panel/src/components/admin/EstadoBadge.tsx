import { Badge } from '@/components/ui'
import { estadoDe } from '@/features/admin/estados'
import type { TipoEstado } from '@/features/admin/estados'

/**
 * La insignia de un estado, con la etiqueta y el tono de `estados.ts`.
 *
 * <EstadoBadge tipo="consumo" valor={charge.status} />
 *
 * Un estado que la tabla no conoce sale con su nombre crudo y en gris, nunca
 * en blanco. Los de color llevan su icono: un «Vencido» se lee también sin
 * distinguir el rojo. Si el estado tiene definición (`que`), va en el `title`: es un
 * extra para el ratón; la regla que se tiene que poder leer sin él va en el
 * `info` de la columna.
 */
export function EstadoBadge({
  tipo,
  valor,
  className = '',
}: {
  tipo: TipoEstado
  valor: string
  className?: string
}) {
  const estado = estadoDe(tipo, valor)
  const insignia = (
    <Badge tone={estado.tone} icono className={className}>
      {estado.label}
    </Badge>
  )

  if (!estado.que) return insignia
  return (
    <span className="inline-flex" title={estado.que}>
      {insignia}
    </span>
  )
}
