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
  'inline-flex items-center justify-center gap-2 rounded-full transition-[background-color,color,border-color,transform,box-shadow] duration-200 active:scale-[0.97] disabled:pointer-events-none disabled:opacity-40'

// `filled` es la acción principal de la pantalla: en la tinta marina, como
// «Agendar cita» en el directorio (rediseño del 2026-11-12). El azul queda
// para los acentos: un enlace, una cifra, lo elegido.
const VARIANTES: Record<ButtonVariant, string> = {
  filled:
    'bg-on-surface text-shell-canvas shadow-[0_10px_24px_-12px_rgb(2_11_36/0.55)] hover:bg-primary-bright hover:text-white hover:shadow-[0_0_0_5px_rgb(21_126_253/0.14),0_14px_30px_-12px_rgb(4_94_243/0.6)]',
  tonal: 'bg-panel-control text-on-surface hover:bg-shell-inset',
  outlined:
    'border border-panel-hairline-strong text-on-surface hover:border-outline hover:bg-panel-raised',
  text: 'text-on-surface-variant hover:bg-panel-raised hover:text-on-surface',
  danger: 'bg-error text-on-error hover:bg-error-dim',
}

// El alto es un mínimo y no una medida: con una línea sale el mismo (20 de
// letra más el relleno), pero cuando una fila aprieta el botón en el teléfono
// y la etiqueta se parte en dos, el botón crece con ella. Con `h-*` el
// segundo renglón se salía por abajo, encima de lo que hubiera debajo.
const TAMANOS: Record<ButtonSize, string> = {
  sm: 'min-h-panel-control-sm py-2 px-3.5 text-center type-panel-control [&>svg]:shrink-0',
  md: 'min-h-panel-control-md py-2.5 px-4 text-center type-panel-control [&>svg]:shrink-0',
  lg: 'min-h-panel-control w-full py-3 px-5 text-center type-panel-control [&>svg]:shrink-0',
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
  'w-full rounded-full border bg-panel-control px-panel-pad-control type-panel-body text-on-surface outline-none transition-colors duration-[var(--transition-fast)] placeholder:text-placeholder'

export function bordeDeCampo(error: boolean): string {
  return error ? 'border-error' : 'border-transparent focus:border-primary'
}
