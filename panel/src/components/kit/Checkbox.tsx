import { Check } from 'lucide-react'
import type { ReactNode } from 'react'

/**
 * Una casilla con su rótulo al lado; se pulsa en cualquiera de los dos.
 *
 * Es un `<input type="checkbox">` de verdad, con el aspecto quitado: el
 * teclado, el formulario y el lector de pantalla siguen funcionando como en
 * cualquier casilla. Marcada va en blanco y no en lima: una casilla no es la
 * acción principal de nada.
 */
export function Checkbox({
  id,
  label,
  checked,
  onChange,
  disabled = false,
}: {
  id: string
  label: ReactNode
  checked: boolean
  onChange: (marcada: boolean) => void
  disabled?: boolean
}) {
  return (
    <label
      htmlFor={id}
      className={`inline-flex items-start gap-2.5 ${disabled ? 'cursor-not-allowed opacity-50' : 'cursor-pointer'}`}
    >
      <span className="relative mt-px inline-flex size-4.5 shrink-0">
        <input
          id={id}
          type="checkbox"
          checked={checked}
          disabled={disabled}
          onChange={(e) => onChange(e.target.checked)}
          className="peer size-4.5 cursor-pointer appearance-none rounded-extra-small border border-outline bg-panel-control transition-colors duration-[var(--transition-fast)] checked:border-on-surface checked:bg-on-surface disabled:cursor-not-allowed"
        />
        <Check
          size={13}
          strokeWidth={3}
          aria-hidden
          className="pointer-events-none absolute inset-0 m-auto text-shell-canvas opacity-0 peer-checked:opacity-100"
        />
      </span>
      <span className="type-panel-body text-on-surface">{label}</span>
    </label>
  )
}
