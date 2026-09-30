import { Split } from 'lucide-react'

import { InfoDot } from '@/components/ui'

/** El motivo por defecto: por qué una cifra no tiene local. */
const MOTIVO =
  'Esta cifra es de todo Helios y no de una clínica: no se puede partir por la clínica elegida. Quita la clínica de arriba para verla.'

/**
 * Lo que va en lugar de una cifra que no se parte por local cuando hay un
 * local elegido (los registros, la caja). Nunca un cero: un cero diría que
 * ese local no tuvo registros, y lo cierto es que los registros no son de
 * ningún local.
 *
 * `cifra`: en el renglón de un número (una tarjeta, una celda). `bloque`: en
 * lugar de una sección entera, con el porqué escrito.
 */
export function NoSeParte({
  motivo = MOTIVO,
  variante = 'cifra',
  className = '',
}: {
  /** Por qué no se parte, en una frase. Va al `InfoDot` o, en un bloque, escrito. */
  motivo?: string
  variante?: 'cifra' | 'bloque'
  className?: string
}) {
  if (variante === 'bloque') {
    return (
      <div
        role="note"
        className={`flex items-start gap-3 rounded-panel-card border border-dashed border-panel-hairline-strong p-panel-pad-card ${className}`}
      >
        <Split size={18} aria-hidden className="mt-px shrink-0 text-panel-muted" />
        <div className="flex min-w-0 flex-col gap-1">
          <p className="type-panel-body font-semibold text-on-surface">No se parte por clínica</p>
          <p className="type-panel-body text-on-surface-variant">{motivo}</p>
        </div>
      </div>
    )
  }

  return (
    <span className={`inline-flex items-center gap-1.5 ${className}`}>
      <Split size={15} aria-hidden className="shrink-0 text-panel-muted" />
      <span className="type-panel-body font-semibold text-on-surface-variant">No se parte por clínica</span>
      {/* Relativo y encima: puede vivir en una tarjeta que es un enlace estirado. */}
      <span className="relative z-10 inline-flex">
        <InfoDot title="No se parte por clínica" what={motivo} />
      </span>
    </span>
  )
}
