import type { ReactNode } from 'react'

/**
 * Un interruptor: algo que se enciende o se apaga y surte efecto al momento.
 *
 * Para lo que se guarda al enviar un formulario va `Checkbox`; esto es para
 * un ajuste que cambia en cuanto se pulsa. Encendido va en blanco y no en
 * lima, por lo mismo que la casilla.
 */
export function Switch({
  id,
  label,
  checked,
  onChange,
  disabled = false,
}: {
  id: string
  label: ReactNode
  checked: boolean
  onChange: (encendido: boolean) => void
  disabled?: boolean
}) {
  return (
    <div className={`inline-flex items-center gap-3 ${disabled ? 'opacity-50' : ''}`}>
      <button
        id={id}
        type="button"
        role="switch"
        aria-checked={checked}
        disabled={disabled}
        onClick={() => onChange(!checked)}
        // `en-linea`: el rótulo de al lado también lo acciona, así que el
        // objetivo del dedo es la fila entera y no hace falta inflar la pista.
        className={`en-linea relative inline-flex h-6 w-10 shrink-0 items-center rounded-full border transition-colors duration-[var(--transition-fast)] disabled:cursor-not-allowed ${
          checked ? 'border-on-surface bg-on-surface' : 'border-outline bg-panel-control'
        }`}
      >
        <span
          aria-hidden
          className={`size-4 rounded-full transition-transform duration-[var(--transition-fast)] motion-reduce:transition-none ${
            checked ? 'translate-x-4.75 bg-shell-canvas' : 'translate-x-0.75 bg-on-surface-variant'
          }`}
        />
      </button>
      <label
        htmlFor={id}
        className={`type-panel-body text-on-surface ${disabled ? 'cursor-not-allowed' : 'cursor-pointer'}`}
      >
        {label}
      </label>
    </div>
  )
}
