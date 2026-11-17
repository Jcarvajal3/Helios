import { Badge } from '@/components/ui'
import { estadoDe, estadoDeLaOrden } from '@/features/admin/estados'
import type { EstadoVisual, TipoEstado } from '@/features/admin/estados'

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
  return <Insignia estado={estadoDe(tipo, valor)} className={className} />
}

/**
 * La insignia del estado de una orden. Igual que `<EstadoBadge tipo="consumo">`,
 * salvo la que se anuló sola por no pagar la inicial, que sale «Anulado: sin
 * inicial» y no «Revertido» (docs/07): quien la lee tiene que saber que nadie
 * la revirtió a mano.
 */
export function EstadoDeLaOrdenBadge({
  orden,
  className = '',
}: {
  orden: { status: string; downPaymentExpiredAt?: string | null }
  className?: string
}) {
  return <Insignia estado={estadoDeLaOrden(orden)} className={className} />
}

function Insignia({ estado, className }: { estado: EstadoVisual; className: string }) {
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
