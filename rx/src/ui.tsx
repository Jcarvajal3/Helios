import { useId } from 'react'
import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode, TextareaHTMLAttributes } from 'react'
import { LoaderCircle } from 'lucide-react'

const CAJA =
  'w-full rounded-medium border bg-surface px-3 text-[16px] text-on-surface placeholder:text-placeholder ' +
  'outline-none transition-colors focus:border-primary focus:ring-2 focus:ring-primary/15 ' +
  'disabled:bg-surface-container-high disabled:text-on-surface-variant'

function Rotulo({ id, texto, obligatorio }: { id: string; texto: string; obligatorio?: boolean }) {
  return (
    <label htmlFor={id} className="mb-1 block text-[14px] font-semibold text-on-surface-variant">
      {texto}
      {obligatorio && <span className="text-error"> *</span>}
    </label>
  )
}

function Nota({ id, error, ayuda }: { id: string; error?: string; ayuda?: string }) {
  if (error) {
    return (
      <p id={id} role="alert" className="mt-1 text-[14px] text-error">
        {error}
      </p>
    )
  }
  if (ayuda) {
    return (
      <p id={id} className="mt-1 text-[14px] text-on-surface-faint">
        {ayuda}
      </p>
    )
  }
  return null
}

interface PropsCampo extends InputHTMLAttributes<HTMLInputElement> {
  etiqueta: string
  error?: string
  ayuda?: string
  obligatorio?: boolean
}

export function Campo({ etiqueta, error, ayuda, obligatorio, className = '', ...resto }: PropsCampo) {
  const id = useId()
  const nota = `${id}-nota`
  return (
    <div className={className}>
      <Rotulo id={id} texto={etiqueta} obligatorio={obligatorio} />
      <input
        id={id}
        aria-invalid={Boolean(error)}
        aria-describedby={error || ayuda ? nota : undefined}
        className={`${CAJA} h-11 ${error ? 'border-error' : 'border-outline-variant'}`}
        {...resto}
      />
      <Nota id={nota} error={error} ayuda={ayuda} />
    </div>
  )
}

interface PropsArea extends TextareaHTMLAttributes<HTMLTextAreaElement> {
  etiqueta: string
  error?: string
  ayuda?: string
}

export function AreaDeTexto({ etiqueta, error, ayuda, className = '', ...resto }: PropsArea) {
  const id = useId()
  const nota = `${id}-nota`
  return (
    <div className={className}>
      <Rotulo id={id} texto={etiqueta} />
      <textarea
        id={id}
        aria-invalid={Boolean(error)}
        aria-describedby={error || ayuda ? nota : undefined}
        className={`${CAJA} resize-y py-2.5 leading-snug ${error ? 'border-error' : 'border-outline-variant'}`}
        {...resto}
      />
      <Nota id={nota} error={error} ayuda={ayuda} />
    </div>
  )
}

interface PropsBoton extends ButtonHTMLAttributes<HTMLButtonElement> {
  variante?: 'primario' | 'secundario' | 'texto' | 'peligro'
  cargando?: boolean
  icono?: ReactNode
}

const VARIANTES = {
  primario: 'bg-primary text-on-primary hover:bg-primary-dim',
  secundario: 'border border-outline-variant bg-surface text-on-surface hover:bg-surface-container-high',
  texto: 'text-primary hover:bg-primary-container',
  peligro: 'text-error hover:bg-error-container',
}

export function Boton({
  variante = 'primario',
  cargando,
  icono,
  children,
  className = '',
  disabled,
  type = 'button',
  ...resto
}: PropsBoton) {
  return (
    <button
      type={type}
      disabled={disabled || cargando}
      className={`inline-flex min-h-11 items-center justify-center gap-2 rounded-full px-5 text-[15px] font-semibold transition-colors disabled:opacity-55 ${VARIANTES[variante]} ${className}`}
      {...resto}
    >
      {cargando ? <LoaderCircle aria-hidden className="size-4 animate-spin" /> : icono}
      {children}
    </button>
  )
}

export function Tarjeta({ titulo, detalle, accion, children, className = '' }: {
  titulo?: string
  detalle?: string
  accion?: ReactNode
  children: ReactNode
  className?: string
}) {
  return (
    <section className={`rounded-large border border-outline-variant/70 bg-surface p-4 sm:p-5 ${className}`}>
      {(titulo || accion) && (
        <div className="mb-4 flex items-start justify-between gap-3">
          <div>
            {titulo && <h2 className="text-[17px] font-semibold leading-tight">{titulo}</h2>}
            {detalle && <p className="mt-1 text-[14px] text-on-surface-variant">{detalle}</p>}
          </div>
          {accion}
        </div>
      )}
      {children}
    </section>
  )
}

export function Aviso({ tono = 'error', children }: { tono?: 'error' | 'exito' | 'info'; children: ReactNode }) {
  const tonos = {
    error: 'bg-error-container text-on-error-container',
    exito: 'bg-success-container text-on-success-container',
    info: 'bg-secondary-container text-on-secondary-container',
  }
  return (
    <div role={tono === 'error' ? 'alert' : 'status'} className={`rounded-medium px-3.5 py-2.5 text-[15px] leading-snug ${tonos[tono]}`}>
      {children}
    </div>
  )
}

export function mensajeDe(e: unknown): string {
  return e instanceof Error && e.message ? e.message : 'Algo salió mal. Intenta de nuevo.'
}
