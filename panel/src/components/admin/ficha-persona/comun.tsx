import type { ReactNode } from 'react'

/*
 * Lo que comparten varias pestañas de la ficha de una persona: el par
 * rótulo-valor de los datos de la identidad y del aparato.
 *
 * El tono de cada estado de la cuenta ya no vive aquí: sale de `estados.ts`
 * con `EstadoBadge`, igual que en el resto del panel.
 */

export function Campo({
  label,
  value,
  hint,
}: {
  label: string
  value: ReactNode
  /** Una segunda línea pequeña: de cuánto, desde cuándo. */
  hint?: ReactNode
}) {
  return (
    <div>
      <dt className="type-panel-label text-on-surface-variant">{label}</dt>
      <dd className="mt-0.5 text-on-surface">{value}</dd>
      {hint && <dd className="mt-0.5 type-panel-caption text-on-surface-variant">{hint}</dd>}
    </div>
  )
}

