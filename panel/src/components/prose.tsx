import type { ReactNode } from 'react'

/**
 * Las piezas de texto largo de las páginas públicas —`/legal/privacidad` y
 * `/soporte`.
 *
 * Viven aquí y no dentro de una ruta porque son el mismo párrafo y la misma
 * lista en las dos, y porque un documento legal y su página de soporte que se
 * ven distintos parecen de dos empresas.
 *
 * No es el kit del panel: `components/ui.tsx` es para pantallas de operación
 * —tablas densas, formularios, estados—, y esto es para leer.
 */

export function P({ children }: { children: ReactNode }) {
  return (
    <p className="mt-[var(--spacing-shell-gap-inner)] type-body-medium text-on-surface-variant">
      {children}
    </p>
  )
}

export function Lista({ children }: { children: ReactNode }) {
  return (
    <ul className="mt-[var(--spacing-shell-gap-inner)] flex list-disc flex-col gap-[var(--spacing-shell-gap-stack)] pl-5 type-body-medium text-on-surface-variant marker:text-primary">
      {children}
    </ul>
  )
}

