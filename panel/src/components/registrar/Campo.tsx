import { useRef } from 'react'
import type { ChangeEvent, ClipboardEvent, KeyboardEvent, ReactNode, Ref } from 'react'

import { CLASE_CAMPO, DataLabel, bordeDeCampo, claseDeBoton } from '@/components/ui'
import type { ButtonVariant } from '@/components/ui'

// ═══════════════════════════════════════════════════════════════════════════
// Los campos del alta.
//
// Son los del kit —misma caja, mismo borde solo en foco o error— con tres
// cosas que el `Input` del panel no tiene y que aquí hacen falta:
//
//   · la referencia al `<input>`, para llevar el foco al primer campo con un
//     problema al pulsar Enter, y al primer campo de cada paso;
//   · el error ESCRITO debajo, enlazado con `aria-describedby`: con el
//     paciente delante no hay tiempo de adivinar qué le pasa a un borde rojo;
//   · el tamaño grande para la cédula y el monto, que se leen de lejos;
//   · el formato mientras se teclea (`formato`): la fecha con sus barras y
//     el teléfono con su guion y sus puntos, sin que el cursor salte al final.
// ═══════════════════════════════════════════════════════════════════════════

/** La caja de un campo, a la letra de las cifras en vez de la de lectura. */
const CAJA_GRANDE = CLASE_CAMPO.replace('type-panel-body', 'type-panel-figure tabular-nums')

export function Campo({
  id,
  label,
  value,
  onChange,
  onBlur,
  onPaste,
  error,
  hint,
  inputRef,
  type = 'text',
  inputMode,
  autoComplete,
  maxLength,
  placeholder,
  list,
  prefijo,
  formato,
  sufijo,
  grande = false,
  opcional = false,
  className = '',
}: {
  id: string
  label: string
  value: string
  onChange: (value: string) => void
  onBlur?: () => void
  onPaste?: (event: ClipboardEvent<HTMLInputElement>) => void
  /** El problema del campo, o nada. Se escribe debajo y pinta el borde. */
  error?: string | null
  /** Una línea de ayuda o de confirmación («36 años»), si no hay error. */
  hint?: ReactNode
  inputRef?: Ref<HTMLInputElement>
  type?: 'text' | 'email' | 'tel'
  inputMode?: 'text' | 'numeric' | 'decimal' | 'tel' | 'email'
  autoComplete?: string
  maxLength?: number
  placeholder?: string
  /** El id de un `<datalist>` con sugerencias. */
  list?: string
  /** Lo que va pegado delante dentro de la caja: el «$» del monto. */
  prefijo?: string
  /**
   * Da forma a lo tecleado en cada pulsación («04141234567» →
   * «0414-123.45.67»). Tiene que ser idempotente y separar solo con lo que no
   * es cifra: el cursor se recoloca contando cifras.
   */
  formato?: (texto: string) => string
  /** Un botón dentro de la caja, a la derecha: el calendario de la fecha. */
  sufijo?: ReactNode
  grande?: boolean
  /** Lo dice en el rótulo: el resto se da por obligatorio. */
  opcional?: boolean
  className?: string
}) {
  const idError = `${id}-error`
  const idAyuda = `${id}-ayuda`
  const describe = error ? idError : hint ? idAyuda : undefined
  const propio = useRef<HTMLInputElement | null>(null)

  function referencia(el: HTMLInputElement | null) {
    propio.current = el
    if (typeof inputRef === 'function') inputRef(el)
    else if (inputRef) inputRef.current = el
  }

  /**
   * Pone `crudo` con su formato y deja el cursor detrás de la misma cifra
   * que tenía delante. Se escribe en el `<input>` antes de avisar: así el
   * valor controlado ya coincide y React no mueve el cursor al final.
   */
  function aplicar(el: HTMLInputElement, crudo: string, cursor: number) {
    if (!formato) return onChange(crudo)
    const nuevo = formato(crudo)
    const posicion =
      cursor >= crudo.length ? nuevo.length : trasCifras(nuevo, cifrasEn(crudo.slice(0, cursor)))
    el.value = nuevo
    if (document.activeElement === el) el.setSelectionRange(posicion, posicion)
    onChange(nuevo)
  }

  function alCambiar(e: ChangeEvent<HTMLInputElement>) {
    const el = e.target
    aplicar(el, el.value, el.selectionStart ?? el.value.length)
  }

  /**
   * Retroceso justo detrás de un separador que el formato volvería a poner
   * («0414-|1»): sin esto la tecla no haría nada. Se borra la cifra de antes.
   */
  function alTeclear(e: KeyboardEvent<HTMLInputElement>) {
    if (!formato || e.key !== 'Backspace') return
    const el = e.currentTarget
    const inicio = el.selectionStart ?? 0
    if (inicio !== el.selectionEnd || inicio === 0) return
    const sinSeparador = value.slice(0, inicio - 1) + value.slice(inicio)
    if (/\d/.test(value[inicio - 1]) || formato(sinSeparador) !== value) return
    let i = inicio - 1
    while (i >= 0 && !/\d/.test(value[i])) i--
    if (i < 0) return
    e.preventDefault()
    aplicar(el, value.slice(0, i) + value.slice(inicio), i)
  }

  return (
    <div className={className}>
      <label htmlFor={id} className="mb-shell-gap-stack block">
        <DataLabel>
          {label}
          {opcional && <span className="font-normal text-panel-muted"> · opcional</span>}
        </DataLabel>
      </label>

      <div className="relative">
        {prefijo && (
          <span
            aria-hidden
            className={`pointer-events-none absolute top-1/2 left-3.5 -translate-y-1/2 text-on-surface-variant ${
              grande ? 'type-panel-figure' : 'type-panel-body'
            }`}
          >
            {prefijo}
          </span>
        )}
        <input
          ref={referencia}
          id={id}
          type={type}
          inputMode={inputMode}
          autoComplete={autoComplete}
          maxLength={maxLength}
          placeholder={placeholder}
          list={list}
          value={value}
          onChange={alCambiar}
          onKeyDown={alTeclear}
          onBlur={onBlur}
          onPaste={onPaste}
          aria-invalid={!!error}
          aria-describedby={describe}
          className={`${grande ? `h-14 ${CAJA_GRANDE}` : `h-panel-control-md ${CLASE_CAMPO}`} ${bordeDeCampo(!!error)} ${
            prefijo ? (grande ? 'pl-9' : 'pl-7') : ''
          } ${sufijo ? 'pr-12' : ''}`}
        />
        {sufijo && <div className="absolute inset-y-0 right-1.5 flex items-center">{sufijo}</div>}
      </div>

      {error ? (
        <p id={idError} className="mt-1.5 type-panel-caption font-semibold text-error">
          {error}
        </p>
      ) : (
        hint && (
          <div id={idAyuda} className="mt-1.5 type-panel-caption text-panel-muted">
            {hint}
          </div>
        )
      )}
    </div>
  )
}

/** Cuántas cifras hay en un texto. */
function cifrasEn(texto: string): number {
  return texto.replace(/\D/g, '').length
}

/** La posición justo detrás de la cifra número `n` (0: el principio). */
function trasCifras(texto: string, n: number): number {
  if (n === 0) return 0
  let vistas = 0
  for (let i = 0; i < texto.length; i++) {
    if (/\d/.test(texto[i]) && ++vistas === n) return i + 1
  }
  return texto.length
}

/**
 * Un botón del kit que acepta referencia.
 *
 * `Button` no la reenvía, y en el alta el foco salta a «Continuar» en cuanto
 * llega la respuesta: Enter, Enter, Enter, sin buscar el ratón. Mismas
 * clases que `Button` (`claseDeBoton`), así que se ve igual.
 */
export function BotonConFoco({
  children,
  onClick,
  botonRef,
  type = 'button',
  variant = 'filled',
  disabled = false,
}: {
  children: ReactNode
  onClick?: () => void
  botonRef?: Ref<HTMLButtonElement>
  type?: 'button' | 'submit'
  variant?: ButtonVariant
  disabled?: boolean
}) {
  return (
    <button
      ref={botonRef}
      type={type}
      onClick={onClick}
      disabled={disabled}
      className={claseDeBoton(variant, 'md')}
    >
      {children}
    </button>
  )
}

/** Un desplegable nativo con el mismo contrato que `Campo`. */
export function CampoLista({
  id,
  label,
  value,
  opciones,
  onChange,
  onBlur,
  error,
  selectRef,
  placeholder = 'Elige…',
  className = '',
}: {
  id: string
  label: string
  value: string
  opciones: ReadonlyArray<string>
  onChange: (value: string) => void
  onBlur?: () => void
  error?: string | null
  selectRef?: Ref<HTMLSelectElement>
  placeholder?: string
  className?: string
}) {
  const idError = `${id}-error`

  return (
    <div className={className}>
      <label htmlFor={id} className="mb-shell-gap-stack block">
        <DataLabel>{label}</DataLabel>
      </label>
      <select
        ref={selectRef}
        id={id}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onBlur={onBlur}
        aria-invalid={!!error}
        aria-describedby={error ? idError : undefined}
        className={`h-panel-control-md appearance-none bg-[length:15px] bg-[position:right_12px_center] bg-no-repeat pr-9 ${CLASE_CAMPO} ${bordeDeCampo(!!error)}`}
        style={{
          // El mismo chevron que el `Select` del kit.
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='%23B9B9B9'%3E%3Cpath d='M12 15.4 6.6 10l1.4-1.4 4 4 4-4L17.4 10z'/%3E%3C/svg%3E\")",
        }}
      >
        <option value="">{placeholder}</option>
        {opciones.map((o) => (
          <option key={o} value={o}>
            {o}
          </option>
        ))}
      </select>
      {error && (
        <p id={idError} className="mt-1.5 type-panel-caption font-semibold text-error">
          {error}
        </p>
      )}
    </div>
  )
}

/**
 * Elegir una de pocas opciones fijas con botones (V/E, F/M), como un grupo de
 * radios: Tab entra al grupo y las flechas cambian la opción.
 */
export function Opciones<T extends string>({
  id,
  label,
  value,
  opciones,
  onChange,
  error,
  primeraRef,
  grande = false,
}: {
  id: string
  label: string
  value: T | ''
  opciones: ReadonlyArray<{ value: T; label: string }>
  onChange: (value: T) => void
  error?: string | null
  /** El botón que recibe el foco cuando el grupo tiene un problema. */
  primeraRef?: Ref<HTMLButtonElement>
  grande?: boolean
}) {
  const idRotulo = `${id}-rotulo`
  const idError = `${id}-error`

  function mover(desde: number, paso: number) {
    const siguiente = (desde + paso + opciones.length) % opciones.length
    onChange(opciones[siguiente].value)
    document.getElementById(`${id}-${opciones[siguiente].value}`)?.focus()
  }

  return (
    <div>
      <p id={idRotulo} className="mb-shell-gap-stack">
        <DataLabel>{label}</DataLabel>
      </p>
      <div
        role="radiogroup"
        aria-labelledby={idRotulo}
        aria-describedby={error ? idError : undefined}
        className={`inline-flex gap-0.5 rounded-panel-control border bg-shell-canvas p-0.5 ${
          error ? 'border-error' : 'border-panel-hairline'
        }`}
      >
        {opciones.map((o, i) => {
          const activa = o.value === value
          // Solo una opción entra en el recorrido de Tab: la elegida, o la
          // primera si no hay ninguna. Las demás, con las flechas.
          const tabulable = activa || (value === '' && i === 0)
          return (
            <button
              key={o.value}
              id={`${id}-${o.value}`}
              ref={i === 0 ? primeraRef : undefined}
              type="button"
              role="radio"
              aria-checked={activa}
              tabIndex={tabulable ? 0 : -1}
              onClick={() => onChange(o.value)}
              onKeyDown={(e) => {
                if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
                  e.preventDefault()
                  mover(i, 1)
                } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
                  e.preventDefault()
                  mover(i, -1)
                }
              }}
              className={`${grande ? 'h-[calc(3.5rem-6px)] min-w-14 px-4 type-panel-figure' : 'h-[calc(var(--spacing-panel-control-md)-6px)] px-4 type-panel-control'} rounded-[calc(var(--radius-panel-control)-2px)] whitespace-nowrap transition-colors duration-[var(--transition-fast)] ${
                activa
                  ? 'bg-panel-control text-on-surface'
                  : 'text-panel-muted hover:text-on-surface'
              }`}
            >
              {o.label}
            </button>
          )
        })}
      </div>
      {error && (
        <p id={idError} className="mt-1.5 type-panel-caption font-semibold text-error">
          {error}
        </p>
      )}
    </div>
  )
}
