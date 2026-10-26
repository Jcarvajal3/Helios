import { ArrowRight, Check, ChevronDown, CircleAlert, Plus } from 'lucide-react'
import { useState } from 'react'
import type { InputHTMLAttributes, ReactNode } from 'react'

import {
  NOMBRE_LETRA,
  componerDocumento,
  partirDocumento,
} from '@/lib/documento'
import type { LetraDocumento } from '@/lib/documento'

/**
 * Las piezas del formulario de afiliación, con el aspecto de la portada (y
 * del login): etiqueta arriba, campo alto y redondeado, el error debajo y en
 * palabras, y los botones en píldora.
 *
 * Los campos son nativos a propósito: en el teléfono, el selector, el
 * calendario y el teclado numérico del sistema son los más cómodos.
 */

const ENTRADA =
  'afiliacion-entrada h-[52px] w-full min-w-0 rounded-2xl border bg-white px-4 text-[1rem] tracking-[-0.01em] text-portada-tinta placeholder:text-portada-tinta-3/60 transition-[border-color,box-shadow] duration-300 outline-none focus:shadow-[0_0_0_4px_rgba(4,94,243,0.12)]'

function bordeDe(error: string | null | undefined) {
  return error
    ? 'border-[#E5867C] focus:border-[#C5372C] focus:shadow-[0_0_0_4px_rgba(197,55,44,0.12)]'
    : 'border-portada-linea hover:border-portada-tinta/20 focus:border-portada-azul'
}

/** Los `aria-describedby` de un campo: su ayuda y su error, si los tiene. */
function descritoPor(id: string, ayuda: ReactNode, error?: string | null) {
  const ids = [ayuda ? `${id}-ayuda` : '', error ? `${id}-error` : '']
  return ids.filter(Boolean).join(' ') || undefined
}

/** La etiqueta, el campo, una ayuda opcional y el error. */
export function Campo({
  id,
  etiqueta,
  opcional = false,
  ayuda,
  error,
  children,
  className = '',
}: {
  id: string
  etiqueta: string
  opcional?: boolean
  ayuda?: ReactNode
  error?: string | null
  children: ReactNode
  className?: string
}) {
  return (
    <div className={`min-w-0 ${className}`}>
      <label
        htmlFor={id}
        className="flex items-baseline justify-between gap-3 text-[0.9rem] font-medium tracking-[-0.01em] text-portada-tinta"
      >
        {etiqueta}
        {opcional && (
          <span className="text-[0.8rem] font-normal text-portada-tinta-3">
            Opcional
          </span>
        )}
      </label>
      <div className="relative mt-2">{children}</div>
      {error ? (
        <p
          id={`${id}-error`}
          className="mt-2 flex gap-1.5 text-[0.85rem] leading-snug text-[#B3261E]"
        >
          <CircleAlert aria-hidden className="mt-[0.1rem] size-3.5 shrink-0" />
          {error}
        </p>
      ) : ayuda ? (
        <p
          id={`${id}-ayuda`}
          className="mt-2 text-[0.85rem] leading-snug text-portada-tinta-3"
        >
          {ayuda}
        </p>
      ) : null}
    </div>
  )
}

type AtributosDeEntrada = Omit<
  InputHTMLAttributes<HTMLInputElement>,
  'id' | 'value' | 'onChange' | 'onBlur' | 'className'
>

/**
 * Un campo de texto. `alSalir` avisa al dejar el campo con algo escrito: el
 * error de un campo vacío espera a «Continuar», el de uno mal escrito sale
 * al terminar de escribirlo.
 */
export function CampoDeTexto({
  id,
  etiqueta,
  opcional,
  ayuda,
  error,
  value,
  onChange,
  alSalir,
  className,
  ...resto
}: AtributosDeEntrada & {
  id: string
  etiqueta: string
  opcional?: boolean
  ayuda?: ReactNode
  error?: string | null
  value: string
  onChange: (valor: string) => void
  alSalir?: () => void
  className?: string
}) {
  return (
    <Campo
      id={id}
      etiqueta={etiqueta}
      opcional={opcional}
      ayuda={ayuda}
      error={error}
      className={className}
    >
      <input
        {...resto}
        id={id}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onBlur={(e) => e.target.value.trim() && alSalir?.()}
        aria-invalid={error ? true : undefined}
        aria-describedby={descritoPor(id, ayuda, error)}
        className={`${ENTRADA} ${bordeDe(error)}`}
      />
    </Campo>
  )
}

function Flechita() {
  return (
    <ChevronDown
      aria-hidden
      className="pointer-events-none absolute inset-y-0 right-3.5 my-auto size-4 text-portada-tinta-3"
    />
  )
}

/** Un selector nativo con el aspecto de los campos. */
export function CampoDeSeleccion<T extends string>({
  id,
  etiqueta,
  opcional,
  error,
  value,
  vacio,
  opciones,
  onChange,
  className,
}: {
  id: string
  etiqueta: string
  opcional?: boolean
  error?: string | null
  value: T | ''
  /** El texto de la opción vacía. */
  vacio: string
  opciones: ReadonlyArray<{ value: T; label: string }>
  onChange: (valor: T | '') => void
  className?: string
}) {
  return (
    <Campo
      id={id}
      etiqueta={etiqueta}
      opcional={opcional}
      error={error}
      className={className}
    >
      <select
        id={id}
        value={value}
        onChange={(e) => onChange(e.target.value as T | '')}
        aria-invalid={error ? true : undefined}
        aria-describedby={descritoPor(id, null, error)}
        className={`${ENTRADA} ${bordeDe(error)} appearance-none pr-10 ${value ? '' : 'text-portada-tinta-3'}`}
      >
        <option value="">{vacio}</option>
        {opciones.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      <Flechita />
    </Campo>
  )
}

/**
 * Una cédula, un pasaporte o un RIF, como `CampoDocumento` del panel: la
 * letra en un selector y el número aparte. El valor es la letra pegada al
 * número (`V12345678`).
 */
export function CampoDeDocumento({
  id,
  etiqueta,
  opcional,
  ayuda,
  error,
  value,
  onChange,
  alSalir,
  letras,
  placeholder = '12345678',
}: {
  id: string
  etiqueta: string
  opcional?: boolean
  ayuda?: ReactNode
  error?: string | null
  value: string
  onChange: (valor: string) => void
  alSalir?: () => void
  letras: ReadonlyArray<LetraDocumento>
  placeholder?: string
}) {
  const { letra, numero } = partirDocumento(value, letras)
  return (
    <Campo
      id={id}
      etiqueta={etiqueta}
      opcional={opcional}
      ayuda={ayuda}
      error={error}
    >
      <div className="flex gap-2">
        <div className="relative w-[4.75rem] shrink-0">
          <select
            id={`${id}-letra`}
            aria-label="Tipo de documento"
            title={NOMBRE_LETRA[letra]}
            value={letra}
            onChange={(e) =>
              onChange(
                componerDocumento(e.target.value as LetraDocumento, numero),
              )
            }
            className={`${ENTRADA} ${bordeDe(null)} appearance-none pr-8`}
          >
            {letras.map((l) => (
              <option key={l} value={l}>
                {l}
              </option>
            ))}
          </select>
          <Flechita />
        </div>
        <input
          id={id}
          value={numero}
          onChange={(e) => {
            // Pegar «V-12.345.678» también vale: si trae su letra, se elige.
            const texto = e.target.value
            const pegado = partirDocumento(texto, letras)
            const conLetra =
              /^[A-Za-z]/.test(texto.trim()) &&
              pegado.numero !== '' &&
              letra !== 'P'
            onChange(
              conLetra
                ? componerDocumento(pegado.letra, pegado.numero)
                : componerDocumento(letra, texto),
            )
          }}
          onBlur={(e) => e.target.value.trim() && alSalir?.()}
          inputMode={letra === 'P' ? 'text' : 'numeric'}
          autoComplete="off"
          enterKeyHint="next"
          placeholder={letra === 'P' ? 'Número de pasaporte' : placeholder}
          aria-invalid={error ? true : undefined}
          aria-describedby={descritoPor(id, ayuda, error)}
          className={`${ENTRADA} ${bordeDe(error)} flex-1`}
        />
      </div>
    </Campo>
  )
}

/**
 * Lo opcional, plegado: un botón «Añadir…» que lo despliega. Empieza
 * abierto si ya tiene algo escrito, y una vez abierto no se vuelve a
 * esconder: nada se manda sin que se vea.
 */
export function Opcionales({
  texto,
  conDatos,
  children,
}: {
  texto: string
  conDatos: boolean
  children: ReactNode
}) {
  const [abierto, setAbierto] = useState(conDatos)
  if (abierto) {
    return <div className="flex flex-col gap-5">{children}</div>
  }
  return (
    <button
      type="button"
      onClick={() => setAbierto(true)}
      className="group flex w-full items-center gap-3 rounded-2xl border border-dashed border-portada-linea px-4 py-3.5 text-left text-[0.95rem] tracking-[-0.01em] text-portada-tinta-2 transition-colors duration-300 hover:border-portada-azul/40 hover:bg-portada-cielo-3/50 hover:text-portada-tinta"
    >
      <span
        aria-hidden
        className="grid size-7 shrink-0 place-items-center rounded-full bg-portada-niebla text-portada-azul transition-colors group-hover:bg-white"
      >
        <Plus className="size-4" />
      </span>
      <span className="min-w-0 flex-1">{texto}</span>
      <span className="text-[0.8rem] text-portada-tinta-3">Opcional</span>
    </button>
  )
}

/** Una opción grande, de las que se tocan con el pulgar (radio o casilla). */
export function Opcion({
  tipo,
  nombre,
  marcada,
  onChange,
  titulo,
  nota,
}: {
  tipo: 'radio' | 'checkbox'
  nombre: string
  marcada: boolean
  onChange: (marcada: boolean) => void
  titulo: ReactNode
  nota?: ReactNode
}) {
  return (
    <label
      className={`flex cursor-pointer items-start gap-3 rounded-2xl border px-4 py-3.5 transition-[border-color,background-color,box-shadow] duration-300 has-[:focus-visible]:shadow-[0_0_0_4px_rgba(4,94,243,0.12)] ${
        marcada
          ? 'border-portada-azul bg-portada-cielo-3/60'
          : 'border-portada-linea bg-white hover:border-portada-tinta/20'
      }`}
    >
      <input
        type={tipo}
        name={nombre}
        checked={marcada}
        onChange={(e) => onChange(e.target.checked)}
        className="peer sr-only"
      />
      <span
        aria-hidden
        className={`mt-0.5 grid size-5 shrink-0 place-items-center border-2 transition-colors duration-300 ${
          tipo === 'radio' ? 'rounded-full' : 'rounded-md'
        } ${
          marcada
            ? 'border-portada-azul bg-portada-azul text-white'
            : 'border-portada-tinta/25 bg-white'
        }`}
      >
        {marcada &&
          (tipo === 'radio' ? (
            <span className="size-1.5 rounded-full bg-white" />
          ) : (
            <Check className="size-3.5" strokeWidth={3} />
          ))}
      </span>
      <span className="min-w-0 flex-1">
        <span className="block text-[0.97rem] font-medium tracking-[-0.01em] text-portada-tinta">
          {titulo}
        </span>
        {nota && (
          <span className="mt-0.5 block break-words text-[0.85rem] leading-snug text-portada-tinta-3">
            {nota}
          </span>
        )}
      </span>
    </label>
  )
}

/** Una sugerencia que rellena el campo de un toque. */
export function Sugerencia({
  activa,
  onClick,
  children,
}: {
  activa: boolean
  onClick: () => void
  children: ReactNode
}) {
  return (
    <button
      type="button"
      aria-pressed={activa}
      onClick={onClick}
      className={`rounded-full border px-3.5 py-1.5 text-[0.88rem] tracking-[-0.01em] transition-colors duration-300 ${
        activa
          ? 'border-portada-azul bg-portada-azul text-white'
          : 'border-portada-linea bg-white text-portada-tinta hover:border-portada-tinta/25'
      }`}
    >
      {children}
    </button>
  )
}

/** El botón principal de cada paso: «Continuar» o «Enviar solicitud». */
export function BotonPrincipal({
  children,
  ocupado = false,
  className = '',
}: {
  children: ReactNode
  ocupado?: boolean
  className?: string
}) {
  return (
    <button
      type="submit"
      disabled={ocupado}
      className={`portada-boton group inline-flex h-[52px] items-center justify-center gap-2 rounded-full bg-portada-tinta pl-6 pr-2 text-[0.98rem] font-medium tracking-[-0.01em] text-white shadow-[0_10px_30px_-12px_rgba(0,39,112,0.55)] transition-[background-color,transform,box-shadow,opacity] duration-300 hover:bg-portada-marino active:scale-[0.99] disabled:cursor-wait disabled:opacity-60 ${className}`}
    >
      <span className="flex-1 text-center">{children}</span>
      <span
        aria-hidden
        className="grid size-9 place-items-center overflow-hidden rounded-full bg-white/12"
      >
        <span className="portada-boton-flecha relative block size-4">
          <ArrowRight className="absolute inset-0 size-4" strokeWidth={2} />
          <ArrowRight className="absolute inset-0 size-4" strokeWidth={2} />
        </span>
      </span>
    </button>
  )
}

/** Dónde va el formulario: «Paso 1 de 3» y una barra por paso. */
export function Progreso({
  pasos,
  actual,
}: {
  pasos: ReadonlyArray<string>
  actual: number
}) {
  return (
    <div>
      <p className="portada-etiqueta text-portada-tinta-3">
        Paso {actual + 1} de {pasos.length}
      </p>
      <ol
        className="mt-3 grid gap-2"
        style={{
          gridTemplateColumns: `repeat(${pasos.length}, minmax(0, 1fr))`,
        }}
      >
        {pasos.map((p, i) => (
          <li key={p} aria-current={i === actual ? 'step' : undefined}>
            <span
              aria-hidden
              className={`block h-1 rounded-full transition-colors duration-500 ${
                i <= actual ? 'bg-portada-azul' : 'bg-portada-linea'
              }`}
            />
            <span
              className={`mt-2 flex items-center gap-1 truncate text-[0.8rem] tracking-[-0.01em] ${
                i === actual
                  ? 'font-medium text-portada-tinta'
                  : 'text-portada-tinta-3'
              }`}
            >
              {i < actual && (
                <Check
                  aria-hidden
                  className="size-3.5 shrink-0 text-portada-azul"
                  strokeWidth={2.5}
                />
              )}
              <span className="truncate">{p}</span>
              {i < actual && <span className="sr-only">(hecho)</span>}
            </span>
          </li>
        ))}
      </ol>
    </div>
  )
}
