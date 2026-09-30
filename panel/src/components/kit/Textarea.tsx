import { CLASE_CAMPO, bordeDeCampo } from './clases'

/**
 * Un texto de varias líneas: una nota, un motivo, un mensaje.
 *
 * Debajo va UNA línea: el error si lo hay, si no la ayuda, y a la derecha la
 * cuenta de caracteres cuando hay tope. Un tope que no se ve se descubre al
 * teclear la letra que ya no entra.
 */
export function Textarea({
  id,
  label,
  value,
  onChange,
  rows = 4,
  hint,
  error,
  maxLength,
  placeholder,
}: {
  id: string
  label: string
  value: string
  onChange: (valor: string) => void
  rows?: number
  hint?: string
  error?: string
  maxLength?: number
  placeholder?: string
}) {
  const idAyuda = `${id}-ayuda`
  const linea = error ?? hint
  const conPie = !!linea || maxLength !== undefined

  return (
    <div className="flex flex-col gap-2">
      <label htmlFor={id} className="type-panel-label text-on-surface-variant">
        {label}
      </label>
      <textarea
        id={id}
        rows={rows}
        value={value}
        maxLength={maxLength}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        aria-invalid={!!error}
        aria-describedby={conPie ? idAyuda : undefined}
        className={`resize-y py-2.5 ${CLASE_CAMPO} ${bordeDeCampo(!!error)}`}
      />
      {conPie && (
        <div id={idAyuda} className="flex gap-3 type-panel-caption">
          {linea && <span className={error ? 'text-error' : 'text-panel-muted'}>{linea}</span>}
          {maxLength !== undefined && (
            <span className="ml-auto tabular-nums text-panel-muted">
              {value.length}/{maxLength}
            </span>
          )}
        </div>
      )}
    </div>
  )
}
