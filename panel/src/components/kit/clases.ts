// ═══════════════════════════════════════════════════════════════════════════
// Las clases de un botón y de un campo.
//
// Viven aquí y no dentro de `Button` e `Input` porque las piezas de `kit/`
// —el periodo, el menú— dibujan botones y campos y no pueden importar valores
// de ui.tsx sin cerrar un ciclo. Así hay un solo botón, lo pinte quien lo
// pinte.
// ═══════════════════════════════════════════════════════════════════════════

/** Los nombres de M3, iguales que en la app. */
export type ButtonVariant = 'filled' | 'tonal' | 'outlined' | 'text' | 'danger'
export type ButtonSize = 'sm' | 'md' | 'lg'

// El peso lo pone `type-panel-control` (600). El `font-medium` que llevaba la
// base lo pisaba y los botones salían a 500.
const BASE =
  'inline-flex items-center justify-center gap-2 rounded-panel-control transition-colors duration-[var(--transition-fast)] disabled:pointer-events-none disabled:opacity-40'

// El lima es SOLO `filled`: la acción principal de la pantalla. Un botón de
// texto en lima se leía como enlace y como acción a la vez.
const VARIANTES: Record<ButtonVariant, string> = {
  filled: 'bg-primary text-on-primary hover:bg-primary-bright',
  tonal: 'bg-panel-control text-on-surface hover:bg-shell-inset',
  outlined:
    'border border-panel-hairline-strong text-on-surface hover:border-outline hover:bg-panel-raised',
  text: 'text-on-surface-variant hover:bg-panel-raised hover:text-on-surface',
  danger: 'bg-error text-on-error hover:bg-error-dim',
}

const TAMANOS: Record<ButtonSize, string> = {
  sm: 'h-panel-control-sm px-3.5 type-panel-control',
  md: 'h-panel-control-md px-4 type-panel-control',
  lg: 'h-panel-control w-full px-5 type-panel-control',
}

export function claseDeBoton(variant: ButtonVariant, size: ButtonSize): string {
  return `${BASE} ${VARIANTES[variant]} ${TAMANOS[size]}`
}

/**
 * La caja de un campo de texto, sin el alto: `Input` lleva el de un control y
 * `Textarea` el de sus filas. El borde solo aparece en foco y en error: sobre
 * la superficie del control ya se ve dónde está el campo.
 */
export const CLASE_CAMPO =
  'w-full rounded-panel-control border bg-panel-control px-panel-pad-control type-panel-body text-on-surface outline-none transition-colors duration-[var(--transition-fast)] placeholder:text-placeholder'

export function bordeDeCampo(error: boolean): string {
  return error ? 'border-error' : 'border-transparent focus:border-primary'
}
