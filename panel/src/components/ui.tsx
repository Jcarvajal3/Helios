import { useId } from 'react'
import type { KeyboardEvent, MouseEvent, ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import type { RegisteredRouter, ValidateLinkOptions } from '@tanstack/react-router'
import {
  ArrowRight,
  CircleAlert,
  MoveRight,
  Search,
  TrendingDown,
  TrendingUp,
  X,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

import type { Ambito } from '@/features/admin/catalogo'

import { Callout } from './kit/Callout'
import { InfoDot } from './kit/InfoDot'
import { CLASE_CAMPO, bordeDeCampo, claseDeBoton } from './kit/clases'
import type { ButtonSize, ButtonVariant } from './kit/clases'
import { MESES_CORTOS } from './kit/rango'
import { ICONO_DE_TONO, TINTE_DE_TONO } from './kit/tonos'

// ═══════════════════════════════════════════════════════════════════════════
// El kit de UI del panel.
//
// Comparte con la app móvil el COLOR y la TIPOGRAFÍA: los dos salen del bloque
// `shell` de tokens/ronda.tokens.json, emitido a CSS como --color-shell-* y
// --spacing-shell-gap-*. No hay un hex escrito a mano en este archivo, y
// cambiar la paleta en el JSON repinta las dos superficies a la vez.
//
// Lo que NO comparte es la FORMA ni la MEDIDA. Esas salen de la capa de
// escritorio —--radius-panel-*, --spacing-panel-*, .type-panel-*— que vive en
// styles.css y solo lee el panel. `shell` describe una pantalla que se toca
// con el pulgar; aquí se mira con un ratón y se ven cientos de filas a la vez.
//
// Las cuatro reglas que mandan:
//
//   1. FORMA  — `panel-card` (16) para superficies, `panel-hero` (20) para la
//      que manda en su pantalla y `panel-control` (9) para todo lo que se
//      pulsa. La píldora sobrevive donde la forma ES el significado: `Badge`.
//   2. SUPERFICIE — lienzo → `panel-card` con borde `panel-hairline` →
//      `panel-raised` (lo levantado) → `panel-control` (controles, pistas).
//   3. COLOR — cada uno con un trabajo. Lima: SOLO la acción principal y el
//      anillo de foco. El tono del área (`bg-area`, `text-area`) orienta.
//      Verde, ámbar y rojo: solo estado, siempre con icono y rótulo. El
//      número de una cifra va siempre en blanco.
//   4. TIPOGRAFÍA — Montserrat en lo que se mira (.type-panel-page/-section/
//      -figure/-hero/-control), Source Sans en lo que se lee (-body/-label/
//      -caption). Nada en MAYÚSCULAS fuera de las cabeceras del menú.
//
// Las piezas nuevas —Tooltip, Callout, Meter, Menu, Periodo, Checkbox,
// Switch, Textarea, IconoDeArea, Seccion— viven una por archivo en `kit/` y
// se reexportan al final: todo el panel sigue importando de aquí.
//
// La escalera de alturas es 32 / 36 / 40, la del ratón. La de la app —40, 48,
// 56— obligaría a hacer scroll toda la mañana: una barra de cuatro filtros a
// 56 ocupa lo que tres filas de tabla. La excepción tiene dueño y está
// declarada en styles.css: `Stepper` se queda en 44 porque lo maneja el cajero
// de pie y con el dedo.
// ═══════════════════════════════════════════════════════════════════════════

// ── Button ────────────────────────────────────────────────────────────────
//
// Las clases viven en `kit/clases.ts`: el periodo y el menú también dibujan
// botones, y un archivo de `kit/` no puede importar de aquí.

export function Button({
  children,
  onClick,
  type = 'button',
  variant = 'filled',
  size = 'lg',
  disabled = false,
  title,
  motivoApagado,
  className = '',
}: {
  children: ReactNode
  /** Recibe el evento para poder parar la propagación: un botón dentro de una
   *  fila que también se pulsa hace las dos cosas si nadie lo corta. */
  onClick?: (event: MouseEvent<HTMLButtonElement>) => void
  type?: 'button' | 'submit'
  variant?: ButtonVariant
  size?: ButtonSize
  disabled?: boolean
  /**
   * Por qué no se puede pulsar. Un botón apagado sin explicación es un
   * callejón: el operador no sabe si le falta marcar algo o si está roto.
   * Se envuelve en un `span` porque un `<button disabled>` no recibe
   * eventos de ratón y el navegador nunca llega a enseñar su propio title.
   *
   * Solo lo ve quien tiene ratón. Para lo que tiene que leerse en la tablet,
   * `motivoApagado`.
   */
  title?: string
  /**
   * Por qué no se puede pulsar, ESCRITO debajo del botón mientras esté
   * apagado. En una tablet no hay `title` que valga: el motivo o se lee o no
   * existe. Se enlaza con `aria-describedby`.
   *
   * El botón y el motivo van en una columna (`inline-flex flex-col`), con el
   * botón arriba: en una fila de botones alineada por arriba —`flex` a secas
   * o `items-start`— los botones siguen a la misma altura y el motivo cuelga
   * debajo del suyo. En una fila con `items-center` el conjunto se centra
   * entero y el botón baja medio renglón: ahí conviene `items-start`.
   */
  motivoApagado?: string
  className?: string
}) {
  const motivoId = useId()
  const conMotivo = disabled && !!motivoApagado

  const button = (
    <button
      type={type}
      onClick={onClick}
      disabled={disabled}
      aria-describedby={conMotivo ? motivoId : undefined}
      className={`${claseDeBoton(variant, size)} ${className}`}
    >
      {children}
    </button>
  )

  if (conMotivo) {
    return (
      <span
        title={title}
        className={`inline-flex flex-col items-start gap-1 ${size === 'lg' ? 'w-full' : ''}`}
      >
        {button}
        <span id={motivoId} className="max-w-xs type-panel-caption text-on-surface-variant">
          {motivoApagado}
        </span>
      </span>
    )
  }

  if (disabled && title) {
    return (
      <span title={title} className="inline-flex">
        {button}
      </span>
    )
  }

  return button
}

/**
 * El motivo de un botón apagado por falta de permiso, para `motivoApagado`.
 *
 * Vive aquí y no solo en `features/admin/role.ts` para que el kit no tenga
 * que importar la sesión; `role.ts` lo reexporta y los dos nombres son el
 * mismo texto.
 */
export const SOLO_SUPER_ADMIN = 'Solo el super admin puede hacer esto'

// ── IconButton ────────────────────────────────────────────────────────────

/**
 * Cuadrado redondeado del alto de un control.
 *
 * En la app es un disco —el botón de volver—, pero eso es la forma de un
 * objeto que se toca con el pulgar. Aquí vive en barras de herramientas, al
 * lado de botones y campos, y un círculo entre cuadrados redondeados es la
 * pieza que no encaja.
 */
export function IconButton({
  children,
  onClick,
  disabled = false,
  variant = 'tonal',
  label,
  title,
  className = '',
}: {
  children: ReactNode
  onClick?: () => void
  disabled?: boolean
  variant?: 'tonal' | 'text' | 'danger'
  label: string
  /**
   * Por qué no se puede pulsar. Igual que en `Button`, y por lo mismo: un
   * icono apagado sin explicación es peor que uno que falla, porque no hay
   * ni mensaje de error del que tirar.
   */
  title?: string
  className?: string
}) {
  const variants: Record<string, string> = {
    tonal: 'bg-panel-control text-on-surface hover:bg-shell-inset',
    text: 'text-on-surface-variant hover:bg-panel-raised hover:text-on-surface',
    danger: 'text-error hover:bg-error/14',
  }

  const boton = (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-label={label}
      title={disabled ? undefined : title}
      className={`inline-flex size-panel-control-md items-center justify-center rounded-panel-control transition-colors duration-[var(--transition-fast)] disabled:opacity-40 ${variants[variant]} ${className}`}
    >
      {children}
    </button>
  )

  // Un `<button disabled>` no recibe eventos de ratón, así que el navegador
  // nunca llega a enseñar su propio title: hay que colgarlo del envoltorio.
  if (disabled && title) {
    return (
      <span title={title} className="inline-flex">
        {boton}
      </span>
    )
  }

  return boton
}

// ── Card ──────────────────────────────────────────────────────────────────

/**
 * La caja del sistema: `panel-card` con un borde de un pelo que la recorta del
 * lienzo sin sombra.
 *
 *   default  un bloque de contenido
 *   inset    hundida dentro de otra tarjeta — una nota, un dato acotado
 *   brand    se queda por compatibilidad y se pinta como `default`: el lavado
 *            lima gastaba el color de la acción en decorar una caja
 */
export type CardTone = 'default' | 'brand' | 'inset'

/** `hero`: la tarjeta que manda en su pantalla, un paso más redonda. */
export type CardVariant = 'default' | 'hero'

export function Card({
  children,
  className = '',
  tone = 'default',
  variant = 'default',
  area,
  as: Etiqueta = 'div',
}: {
  children: ReactNode
  className?: string
  tone?: CardTone
  variant?: CardVariant
  /**
   * El área a la que pertenece, cuando no es la de la pantalla: una tarjeta
   * de Cobranza en Inicio. Sus iconos y medidores toman ese tono.
   *
   * Se escribe el ámbito tal cual en `data-area`: los que no tienen tono
   * propio (inicio, directorio, ajustes) caen en el neutro de `[data-area]`
   * en styles.css, igual que con `tonoDeAmbito`, y así el kit no arrastra el
   * catálogo entero al panel del comercio.
   */
  area?: Ambito
  as?: 'div' | 'section' | 'article'
}) {
  const tones: Record<CardTone, string> = {
    default: 'border border-panel-hairline bg-panel-card',
    brand: 'border border-panel-hairline bg-panel-card',
    inset: 'bg-panel-raised',
  }

  return (
    <Etiqueta
      data-area={area}
      className={`${variant === 'hero' ? 'rounded-panel-hero' : 'rounded-panel-card'} p-panel-pad-card ${tones[tone]} ${className}`}
    >
      {children}
    </Etiqueta>
  )
}

// ── Títulos y etiquetas ───────────────────────────────────────────────────

/** Título de página. Mismo rol que el `PageHeader` de la app. */
export function PageTitle({
  children,
  className = '',
}: {
  children: ReactNode
  className?: string
}) {
  return (
    <h1 className={`type-panel-page text-on-surface ${className}`}>
      {children}
    </h1>
  )
}

/** Rótulo de una zona de la vista. Un paso por debajo del título de página. */
export function SectionTitle({
  children,
  className = '',
}: {
  children: ReactNode
  className?: string
}) {
  return (
    <h2 className={`type-panel-section text-on-surface ${className}`}>
      {children}
    </h2>
  )
}

/**
 * El rótulo de un DATO —una cifra, un filtro, un campo—, nunca de una sección.
 *
 * En minúscula de frase: las MAYÚSCULAS en cada tarjeta, filtro y cabecera
 * eran la textura dominante del panel. Va en `on-surface-variant` y no en
 * `faint`, porque el gris #6E6E6E no llega al contraste mínimo.
 */
export function DataLabel({
  children,
  className = '',
}: {
  children: ReactNode
  className?: string
}) {
  return (
    <p
      className={`type-panel-label text-on-surface-variant ${className}`}
    >
      {children}
    </p>
  )
}

// ── Divider ───────────────────────────────────────────────────────────────

export function Divider({ className = '' }: { className?: string }) {
  return <hr className={`border-0 border-t border-panel-hairline ${className}`} />
}

// ── Badge ─────────────────────────────────────────────────────────────────

/**
 * Los cinco tonos de una insignia: los cuatro tipos de feedback que existen
 * —neutro, aviso, error, éxito— más `brand`, que se queda por compatibilidad
 * y se pinta como neutro (era violeta y chocaba con el tono de Riesgo). Si un
 * estado no cabe en estos, el problema es el estado.
 */
export type BadgeTone = 'neutral' | 'warning' | 'error' | 'success' | 'brand'

/** La pastilla de estado junto a una cifra: `Stat senal`, `senalPorUmbral`. */
export type SenalDeCifra = { tone: BadgeTone; texto: string }

/**
 * La pastilla: un estado, una cuenta, una etiqueta corta.
 *
 * `icono` pone el icono de su tono —success ✓, warning ⚠, error ⓘ— o el que
 * se le pase. Un estado va SIEMPRE con icono: se tiene que poder leer sin
 * distinguir el color.
 */
export function Badge({
  children,
  tone = 'neutral',
  icono = false,
  className = '',
}: {
  children: ReactNode
  tone?: BadgeTone
  icono?: boolean | LucideIcon
  className?: string
}) {
  const Icono = icono === true ? ICONO_DE_TONO[tone] : icono === false ? undefined : icono

  return (
    <span
      className={`inline-flex h-6 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 type-panel-caption font-bold ${TINTE_DE_TONO[tone]} ${className}`}
    >
      {Icono && <Icono size={12} strokeWidth={2.25} aria-hidden className="shrink-0" />}
      {children}
    </span>
  )
}

// ── Chip ──────────────────────────────────────────────────────────────────

/**
 * Píldora que se pulsa: insertar una variable, una sugerencia. `selected` la
 * enciende en blanco y no en lima: una píldora no es la acción principal.
 */
export function Chip({
  children,
  onClick,
  selected = false,
  className = '',
}: {
  children: ReactNode
  onClick?: () => void
  selected?: boolean
  className?: string
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={selected}
      className={`inline-flex h-panel-control-sm items-center gap-2 whitespace-nowrap rounded-panel-control px-3.5 type-panel-control transition-colors duration-[var(--transition-fast)] ${
        selected
          ? 'bg-on-surface text-shell-canvas'
          : 'bg-panel-control text-on-surface-variant hover:text-on-surface'
      } ${className}`}
    >
      {children}
    </button>
  )
}

// ── Input ─────────────────────────────────────────────────────────────────

/**
 * Campo de texto. Píldora, alto de control y superficie de control — el mismo
 * contrato que el `TextInputField` de la app.
 *
 * El borde solo aparece en foco y en error: sobre el lienzo profundo la
 * superficie ya separa el campo del fondo, y un borde permanente en un
 * formulario de doce campos es doce líneas de ruido.
 */
export function Input({
  id,
  label,
  value,
  onChange,
  onFocus,
  onBlur,
  placeholder,
  type = 'text',
  inputMode,
  autoComplete,
  autoFocus = false,
  min,
  max,
  error = false,
  hint,
  className = '',
}: {
  id: string
  label?: string
  value: string
  onChange: (value: string) => void
  /**
   * Para un campo que se guarda solo al salir de él, no a cada tecla. Es lo
   * que quiere una lista larga de campos cortos —una nota por fila—, donde
   * guardar en cada pulsación es una escritura por letra.
   */
  onFocus?: () => void
  onBlur?: () => void
  placeholder?: string
  type?: string
  inputMode?: 'text' | 'numeric' | 'decimal' | 'tel'
  /**
   * Qué puede rellenar solo el navegador.
   *
   * Hace falta `"off"` en un campo que contiene la credencial de OTRA
   * persona: sin él, el gestor de contraseñas del operador se ofrece a
   * guardar en SU bóveda la clave del cajero al que se la acaba de poner.
   */
  autoComplete?: string
  autoFocus?: boolean
  /** Solo para `type="date"` y `type="number"`: los extremos elegibles. */
  min?: string
  max?: string
  error?: boolean
  /**
   * UNA línea debajo del campo: qué pasa si se deja vacío, qué se hace con
   * lo escrito. Lo que no cabe en una línea va al `info` de la sección.
   */
  hint?: string
  className?: string
}) {
  const idAyuda = `${id}-ayuda`

  return (
    <div className={className}>
      {label && (
        <label htmlFor={id} className="mb-shell-gap-stack block">
          <DataLabel>{label}</DataLabel>
        </label>
      )}
      <input
        id={id}
        type={type}
        inputMode={inputMode}
        autoComplete={autoComplete}
        autoFocus={autoFocus}
        min={min}
        max={max}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onFocus={onFocus}
        onBlur={onBlur}
        placeholder={placeholder}
        aria-invalid={error}
        aria-describedby={hint ? idAyuda : undefined}
        className={`h-panel-control-md ${CLASE_CAMPO} ${bordeDeCampo(error)}`}
      />
      {hint && (
        <span id={idAyuda} className="mt-1.5 block type-panel-caption text-panel-muted">
          {hint}
        </span>
      )}
    </div>
  )
}

// ── SearchInput ───────────────────────────────────────────────────────────

/**
 * El buscador de UNA lista. No el de la barra de arriba, que busca en todo el
 * panel.
 *
 * Es un `Input` con dos cosas que un campo de texto normal no tiene y que en
 * un buscador se dan por supuestas: la lupa, que dice qué hace este campo sin
 * leer el rótulo, y la equis, que lo vacía de un toque. Sin la equis, quitar
 * un filtro de búsqueda en la tablet del local es mantener el borrado pulsado
 * mirando cómo desaparecen las letras de una en una.
 *
 * `type="search"` a propósito: el navegador ofrece el historial de búsquedas
 * del campo y en iOS cambia la tecla de entrar por «Buscar». La equis nativa
 * de WebKit se esconde en styles.css — la nuestra es del tamaño del dedo.
 */
export function SearchInput({
  id,
  label,
  value,
  onChange,
  placeholder,
  autoFocus = false,
  className = '',
}: {
  id: string
  label?: string
  value: string
  onChange: (value: string) => void
  placeholder?: string
  autoFocus?: boolean
  className?: string
}) {
  return (
    <div className={className}>
      {label && (
        <label htmlFor={id} className="mb-shell-gap-stack block">
          <DataLabel>{label}</DataLabel>
        </label>
      )}
      <div className="relative">
        <Search
          size={16}
          aria-hidden
          className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-panel-muted"
        />
        <input
          id={id}
          type="search"
          autoFocus={autoFocus}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder={placeholder}
          // El relleno de los lados lo ponen la lupa y la equis, así que
          // pisan al de `CLASE_CAMPO`.
          className={`h-panel-control-md ${CLASE_CAMPO} ${bordeDeCampo(false)} pl-9 pr-10`}
        />
        {value !== '' && (
          <button
            type="button"
            aria-label="Borrar la búsqueda"
            onClick={() => onChange('')}
            // `en-linea`: es una marca DENTRO de su propio campo, no un objeto
            // suelto. Inflada a los 44 del dedo se saldría de un campo de 40.
            // El tamaño sale del alto del campo menos su aire: así crece
            // sola en la escala táctil del local en vez de quedarse en 32
            // dentro de un campo de 44.
            className="en-linea absolute right-1 top-1/2 flex size-[calc(var(--spacing-panel-control-md)-0.5rem)] -translate-y-1/2 items-center justify-center rounded-panel-control text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:bg-shell-inset hover:text-on-surface"
          >
            <X size={15} />
          </button>
        )}
      </div>
    </div>
  )
}

// ── Select ────────────────────────────────────────────────────────────────

/**
 * Desplegable.
 *
 * Aquí SÍ es un `<select>` nativo, al revés que en la app, donde hubo que
 * montar una hoja flotante. El motivo es la plataforma: el desplegable nativo
 * del navegador ya flota sobre la página —no empuja el layout, que era el
 * problema en móvil—, se maneja con teclado y lo lee cualquier lector de
 * pantalla. Reimplementarlo con divs sería perder todo eso para ganar el
 * control del chevron.
 */
export function Select<T extends string>({
  id,
  label,
  value,
  options,
  onChange,
  placeholder,
  className = '',
}: {
  id: string
  label?: string
  value: T | ''
  options: Array<{ value: T; label: string }>
  onChange: (value: T) => void
  placeholder?: string
  className?: string
}) {
  return (
    <div className={className}>
      {label && (
        <label htmlFor={id} className="mb-shell-gap-stack block">
          <DataLabel>{label}</DataLabel>
        </label>
      )}
      <select
        id={id}
        value={value}
        onChange={(e) => onChange(e.target.value as T)}
        className={`h-panel-control-md appearance-none bg-[length:15px] bg-[position:right_12px_center] bg-no-repeat ${CLASE_CAMPO} ${bordeDeCampo(false)}`}
        style={{
          // Chevron dibujado como data-URI: un `<select>` nativo no admite un
          // hijo posicionado, y la flecha del sistema se ve de otra época.
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='%23B9B9B9'%3E%3Cpath d='M12 15.4 6.6 10l1.4-1.4 4 4 4-4L17.4 10z'/%3E%3C/svg%3E\")",
          paddingRight: 34,
        }}
      >
        {placeholder && <option value="">{placeholder}</option>}
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </div>
  )
}

// ── Skeleton ──────────────────────────────────────────────────────────────

/**
 * Esqueletos de carga: el hueco que va a ocupar el contenido, latiendo.
 *
 * Reemplazan a la ruedita. Un spinner dice "espera"; un esqueleto dice además
 * QUÉ se espera y cuánto va a ocupar, así que al llegar el dato no hay salto
 * de layout. En un panel con tablas de ocho columnas ese salto es la
 * diferencia entre leer y volver a buscar dónde estabas.
 */
export function SkeletonBlock({
  className = '',
  style,
}: {
  className?: string
  style?: React.CSSProperties
}) {
  return (
    <div
      aria-hidden
      className={`animate-pulse rounded-panel-control bg-panel-control motion-reduce:animate-none ${className}`}
      style={style}
    />
  )
}

/** Tarjeta con un rótulo, una cifra y un pie. La silueta de un `Stat`. */
export function SkeletonCard({ className = '' }: { className?: string }) {
  return (
    <Card className={`flex flex-col gap-2 ${className}`}>
      <SkeletonBlock className="h-3.5 w-2/5" />
      <SkeletonBlock className="h-8 w-3/5" />
      <SkeletonBlock className="mt-shell-gap-stack h-3 w-4/5" />
    </Card>
  )
}

/**
 * Esqueleto de una tabla. `rows` y `columns` deben ser los de la tabla real:
 * si no coinciden, el contenido salta al llegar y el esqueleto no sirve de
 * nada.
 */
export function SkeletonTable({
  rows = 6,
  columns = 5,
}: {
  rows?: number
  columns?: number
}) {
  return (
    <div className="overflow-hidden rounded-panel-card border border-panel-hairline bg-panel-card">
      <div className="flex gap-4 border-b border-panel-hairline px-4 py-2.5">
        {Array.from({ length: columns }, (_, i) => (
          <SkeletonBlock key={i} className="h-3 flex-1" />
        ))}
      </div>
      {Array.from({ length: rows }, (_row, r) => (
        <div
          key={r}
          className="flex gap-4 border-b border-panel-hairline px-4 py-3 last:border-0"
        >
          {Array.from({ length: columns }, (_col, c) => (
            <SkeletonBlock
              key={c}
              className="h-4 flex-1"
              // Las columnas no miden todas lo mismo en una tabla real: si el
              // esqueleto sale perfectamente regular, se lee como una rejilla.
              style={{ opacity: 1 - ((r + c) % 3) * 0.15 }}
            />
          ))}
        </div>
      ))}
    </div>
  )
}

/**
 * Fila de tarjetas de cifra. La silueta de una cabecera de panel.
 *
 * `count` debe ser el número real de `Stat` que va a llegar: un esqueleto de
 * cuatro seguido de un contenido de tres es el salto que el esqueleto existía
 * para evitar.
 */
export function SkeletonStats({
  count = 4,
  cols,
  className = '',
}: {
  count?: number
  /** Las mismas `cols` que el `StatGrid` que va a llegar. */
  cols?: ColumnasDeCifras
  className?: string
}) {
  // La misma rejilla que `StatGrid`, y no una copia con otros umbrales: el
  // esqueleto existe para que al llegar el dato no se mueva nada, y con dos
  // rejillas distintas el contenido aterrizaba en otro número de columnas.
  return (
    <StatGrid cols={cols} className={className}>
      {Array.from({ length: count }, (_stat, i) => (
        <SkeletonCard key={i} />
      ))}
    </StatGrid>
  )
}

/** Lista de tarjetas apiladas. Para lo que no es tabla ni cifras. */
export function SkeletonList({
  rows = 4,
  className = '',
}: {
  rows?: number
  className?: string
}) {
  return (
    <div className={`flex flex-col gap-shell-gap-list ${className}`}>
      {Array.from({ length: rows }, (_row, i) => (
        <div
          key={i}
          className="flex items-center gap-4 rounded-panel-card border border-panel-hairline bg-panel-card p-panel-pad-row"
        >
          <SkeletonBlock className="size-11 shrink-0" />
          <div className="flex flex-1 flex-col gap-2">
            <SkeletonBlock className="h-3.5 w-2/5" />
            <SkeletonBlock className="h-2.5 w-1/4" />
          </div>
          <SkeletonBlock className="h-4 w-16" />
        </div>
      ))}
    </div>
  )
}
/**
 * Esqueleto de la pantalla completa: barra lateral + contenido.
 *
 * Para los guardas de sesión, que corren antes de saber quién eres. Lo que
 * viene detrás en el caso normal es el panel entero, así que dibujarlo evita
 * el salto de una ruedita centrada a un layout de dos zonas.
 */
export function SkeletonScreen() {
  return (
    <div className="flex min-h-dvh">
      {/* Mismo umbral que el marco de verdad: por debajo de lg la barra es un
          cajón y no ocupa sitio, así que aquí tampoco puede ocuparlo. Cuando
          el esqueleto decía `md` y el marco decía otra cosa, la pantalla daba
          un salto lateral justo al terminar de cargar. */}
      <aside className="hidden w-[var(--sidebar-width)] shrink-0 flex-col gap-2 bg-panel-bar px-3 py-4 lg:flex">
        <SkeletonBlock className="h-11 w-full" />
        <div className="mt-4 flex flex-col gap-1">
          {Array.from({ length: 6 }, (_item, i) => (
            <SkeletonBlock key={i} className="h-10 w-full" />
          ))}
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        {/* La barra de arriba: el título a la izquierda y el buscador a la
            derecha, en el mismo sitio donde van a llegar. */}
        <div className="flex h-[var(--topbar-height)] shrink-0 items-center gap-3 border-b border-panel-hairline px-4 lg:px-6">
          <SkeletonBlock className="size-9 shrink-0" />
          <SkeletonBlock className="h-5 w-36" />
          <SkeletonBlock className="ml-auto hidden h-9 w-full max-w-md md:block" />
        </div>

        <main className="flex-1 px-4 py-5 lg:px-6 lg:py-6">
          <div className="mx-auto w-full max-w-[var(--panel-measure-wide)]">
            <SkeletonStats />
            <SkeletonList rows={4} className="mt-6" />
          </div>
        </main>
      </div>
    </div>
  )
}


/**
 * @deprecated No queda ni un uso en el panel: todo estado de carga dibuja la
 * silueta de lo que va a llegar. Se conserva solo por si aparece una espera
 * SIN forma predecible —un trabajo del servidor, no una pantalla—, que es el
 * único caso donde un esqueleto mentiría.
 */
export function Spinner({ className = '' }: { className?: string }) {
  return (
    <div className={`flex justify-center py-12 ${className}`}>
      <div className="size-8 animate-spin rounded-full border-2 border-outline-variant border-t-primary" />
    </div>
  )
}

// ── ErrorBox ──────────────────────────────────────────────────────────────

/**
 * Un fallo, con la causa delante. Es un `Callout` de error.
 *
 * `title` dice qué operación se cayó ("No se pudo crear el comercio") y
 * `detail` dice POR QUÉ ("Ya hay un comercio dado de alta con el RIF
 * J-123456789"). Lo segundo es lo único que se puede accionar, así que va
 * entero y a contraste de lectura, no en gris pequeño.
 *
 * Antes la causa iba en gris pequeño bajo una insignia grande, y un RIF
 * duplicado se leyó como "el alta de comercios está rota" y se fue un rato a
 * buscar el fallo en la base. Un mensaje que existe pero no se lee cuesta lo
 * mismo que no tenerlo.
 */
export function ErrorBox({ title, detail }: { title: string; detail?: string }) {
  return (
    <Callout tone="error" titulo={title}>
      {detail}
    </Callout>
  )
}

// ── EmptyState ────────────────────────────────────────────────────────────

/**
 * Sección vacía. Lo importante es `action`: un vacío que solo explica deja al
 * usuario en un callejón.
 */
export function EmptyState({
  icon,
  title,
  description,
  action,
}: {
  icon?: ReactNode
  title: string
  description?: string
  action?: ReactNode
}) {
  return (
    <Card className="flex flex-col items-center py-10 text-center">
      {icon && <div className="mb-shell-gap-inner text-panel-muted">{icon}</div>}
      <h3 className="type-panel-body font-semibold text-on-surface">{title}</h3>
      {description && (
        <p className="mt-shell-gap-tight max-w-sm type-panel-body text-on-surface-variant">
          {description}
        </p>
      )}
      {action && <div className="mt-shell-gap-group">{action}</div>}
    </Card>
  )
}

// ── Stat ──────────────────────────────────────────────────────────────────

/**
 * LA FILA DE CIFRAS, MEDIDA POR EL HUECO Y NO POR LA VENTANA.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Todas las filas de tarjetas del panel decían `grid-cols-2 xl:grid-cols-4`,
 * y eso está mal por dos motivos a la vez.
 *
 * El primero es que `xl` mide la VENTANA, y lo que decide cuántas tarjetas
 * caben es el hueco: el mismo iPad apaisado tiene 892 px de contenido con la
 * barra lateral desplegada y 1068 con ella plegada. Con un umbral de ventana,
 * plegar la barra no cambiaba nada y la tablet del gerente se quedaba en dos
 * columnas gordas hasta 1280, que es una medida que una tablet no alcanza
 * nunca.
 *
 * El segundo es que el número de columnas estaba escrito a mano en cada
 * pantalla —2/4 aquí, 2/5 allá— y no tenía por qué: lo único que hay que
 * decir es cuánto mide de ancho una tarjeta legible. `auto-fit` con un
 * `minmax` pone las que quepan y estira las que haya, sin un solo umbral y
 * sin que ninguna pantalla tenga que saber en qué tablet la están mirando.
 *
 * 13rem es la medida mínima: por debajo, un rótulo como «Tu venta en el
 * rango» parte en tres líneas y la fila deja de leerse de un vistazo. El
 * `min(...,100%)` de dentro es el seguro de los contenedores estrechos —sin
 * él, una tarjeta de 13rem desborda una columna de 10.
 *
 * Pero `auto-fit` deja huérfanas: reparte ocho cifras en 5 + 3 y seis en
 * 5 + 1. Con `cols` la pantalla dice cuántas quiere por fila (cuatro como
 * mucho) y la rejilla baja por pasos que no dejan ninguna sola: 1 → 2 →
 * `cols`. Los pasos miden el HUECO con una container query, así que el cajón
 * del asistente abierto (736 px útiles) baja a dos sin que la pantalla lo
 * sepa. Cada paso llega cuando caben esas tarjetas a 13rem. Tres por fila no
 * pasan por dos: tres cifras en dos columnas son 2 + 1.
 */
const REJILLA_CIFRAS = 'grid gap-4 grid-cols-[repeat(auto-fit,minmax(min(13rem,100%),1fr))]'

export type ColumnasDeCifras = 2 | 3 | 4

const COLUMNAS: Record<ColumnasDeCifras, string> = {
  2: 'grid-cols-1 @md:grid-cols-2',
  3: 'grid-cols-1 @2xl:grid-cols-3',
  4: 'grid-cols-1 @md:grid-cols-2 @4xl:grid-cols-4',
}

export function StatGrid({
  cols,
  children,
  className = '',
}: {
  /** Cuántas por fila en ancho completo. Sin esto, el reparto automático de siempre. */
  cols?: ColumnasDeCifras
  children: ReactNode
  className?: string
}) {
  if (cols === undefined) return <div className={`${REJILLA_CIFRAS} ${className}`}>{children}</div>

  // La consulta mide al padre, así que la rejilla va dentro de su contenedor.
  return (
    <div className={`@container ${className}`}>
      <div className={`grid gap-4 ${COLUMNAS[cols]}`}>{children}</div>
    </div>
  )
}

/** El cambio de una cifra frente al periodo anterior. Se pinta con `Tendencia`. */
export type StatTrend = {
  /** Lo que se escribe al lado de la flecha: '35 % más', '12 menos'. */
  label: string
  direction: 'up' | 'down' | 'flat'
  /**
   * Si SUBIR es la buena noticia.
   *
   * No se puede deducir de la dirección: más registros es bueno y más
   * expulsados es malo, y las dos son flechas hacia arriba.
   *
   * `null`: ni buena ni mala (lo que vencía, lo transferido): la flecha sale
   * en gris.
   */
  upIsGood?: boolean | null
}

/** En qué punto está la cifra de un `Stat`. */
export type EstadoCifra = 'listo' | 'cargando' | 'error'

/**
 * El estado de una consulta de TanStack Query, en el vocabulario de `Stat`.
 *
 * <Stat estado={estadoDeConsulta(query)} onReintentar={() => void query.refetch()} … />
 *
 * El error manda sobre los datos que hubiera: una cifra que no se pudo
 * refrescar no se enseña como si estuviera al día. Una consulta con
 * `enabled: false` se queda en `cargando`; ahí el estado lo decide la pantalla.
 */
export function estadoDeConsulta(query: { isError: boolean; isPending: boolean }): EstadoCifra {
  if (query.isError) return 'error'
  if (query.isPending) return 'cargando'
  return 'listo'
}

/**
 * El estado de una cifra que sale de VARIAS consultas: basta una fallida para
 * que no se pueda dar, y basta una cargando para que todavía no se sepa. El
 * error manda sobre la carga: esperar a las demás no va a dar un veredicto.
 *
 * Mira `isLoading` y no `isPending`: una consulta apagada (`enabled: false`,
 * porque todavía no hace falta) no deja la cifra cargando para siempre.
 */
export function estadoDeConsultas(
  consultas: ReadonlyArray<{ isError: boolean; isLoading: boolean }>,
): EstadoCifra {
  if (consultas.some((c) => c.isError)) return 'error'
  if (consultas.some((c) => c.isLoading)) return 'cargando'
  return 'listo'
}

export type StatProps<TRouter extends RegisteredRouter = RegisteredRouter, TOptions = unknown> = {
  label: string
  /** La cifra ya formateada. Con `estado` en `cargando` o `error` no se pinta. */
  value: string
  /**
   * El pie: UNA línea, que se corta con puntos suspensivos si no cabe. Con
   * `estado` en `cargando` o `error` no se pinta: suele llevar cifras. Lo que
   * necesite más de una línea va al `info`.
   */
  hint?: ReactNode
  /** El cambio frente al periodo anterior: una pastilla al lado de la cifra. */
  trend?: StatTrend
  /**
   * @deprecated El número va siempre en blanco y esto ya no lo pinta. El
   * estado va en `senal`, y sale de un umbral (`senalPorUmbral`), no de
   * elegir un color a mano.
   */
  tone?: BadgeTone
  /**
   * La pastilla de estado junto al número, con icono y rótulo: «Alerta ·
   * desde 7 %». Solo cuando la cifra cruza un umbral: la sacan
   * `senalPorUmbral` y `senalPorUmbralAlto` de `features/admin/umbrales`.
   */
  senal?: SenalDeCifra
  /** Una forma debajo de la cifra: `Meter`, `Sparkline`, `MiniBarras`. */
  visual?: ReactNode
  /** A la derecha del número, a la altura de la tarjeta: un `Ring`. */
  lateral?: ReactNode
  /** `hero`: la cifra titular de la pantalla, a 40 y un paso más redonda. Una por pantalla. */
  variant?: 'default' | 'hero'
  /**
   * La lista que resume esta cifra, ya filtrada. La tarjeta entera pasa a ser
   * la puerta, y la flecha sale al pasar el ratón.
   *
   * Tipado contra las rutas como un `<Link>`: `{ to: '/admin/cobranza',
   * search: { tramo: 'congelado' } }`. Fuera del JSX se arma con
   * `linkOptions({...})` de TanStack Router.
   */
  link?: ValidateLinkOptions<TRouter, TOptions>
  /** Qué es la cifra y cómo se calcula, en el `InfoDot` junto al rótulo. */
  info?: string
  /**
   * `cargando` pinta un esqueleto donde va la cifra; `error`, «No se pudo
   * leer» con su botón de reintentar. Nunca un cero que no se ha leído.
   */
  estado?: EstadoCifra
  /** Lo que hace «Reintentar» con `estado="error"`. Sin él no hay botón. */
  onReintentar?: () => void
}

/**
 * Una cifra del tablero.
 *
 * La anatomía, de arriba abajo: el rótulo con su `InfoDot`, el número —en
 * blanco, siempre— con la pastilla de estado o de variación al lado, la forma
 * (`visual`) y un pie de una línea. El `InfoDot` se ve atenuado y se enciende
 * al pasar por la tarjeta o al enfocarlo: dos iconos a plena luz en cada
 * tarjeta eran lo primero que se leía de la fila.
 *
 * Con `link`, la tarjeta es un enlace «estirado»: el rótulo es el `<a>` y un
 * `::after` lo extiende a toda la tarjeta. Así el `InfoDot` y «Reintentar»
 * —botones, que no pueden ir dentro de un enlace— quedan por encima y se
 * pulsan sin navegar.
 */
export function Stat<TRouter extends RegisteredRouter, TOptions>(
  props: StatProps<TRouter, TOptions>,
): ReactNode
export function Stat({
  label,
  value,
  hint,
  trend,
  senal,
  visual,
  lateral,
  variant = 'default',
  link,
  info,
  estado = 'listo',
  onReintentar,
}: StatProps): ReactNode {
  const hero = variant === 'hero'
  const listo = estado === 'listo'

  const rotulo = link ? (
    <Link
      {...link}
      // El anillo de foco lo lleva el `::after`, que mide la tarjeta entera.
      // En línea porque el anillo global de styles.css va sin capa y ganaría
      // a cualquier utilidad: sin esto salían dos anillos, uno en el rótulo.
      style={{ outline: 'none' }}
      className={`after:absolute after:inset-0 focus-visible:after:ring-2 focus-visible:after:ring-primary ${
        hero ? 'after:rounded-panel-hero' : 'after:rounded-panel-card'
      }`}
    >
      {label}
    </Link>
  ) : (
    label
  )

  const pastillas =
    listo && (senal || trend) ? (
      <span className="flex flex-wrap items-center gap-1.5">
        {senal && (
          <Badge tone={senal.tone} icono>
            {senal.texto}
          </Badge>
        )}
        {trend && <Tendencia {...trend} />}
      </span>
    ) : null

  const numero = (
    <div
      className={`flex flex-wrap items-center gap-x-2.5 gap-y-1.5 ${hero ? 'min-h-11.5' : 'min-h-8.5'}`}
    >
      {estado === 'cargando' && <SkeletonBlock className={hero ? 'h-10 w-40' : 'h-8 w-28'} />}
      {estado === 'error' && <NoSePudoLeer onReintentar={onReintentar} className="relative z-10" />}
      {listo && (
        <p className={`${hero ? 'type-panel-hero' : 'type-panel-figure'} text-on-surface`}>
          {value}
        </p>
      )}
      {!lateral && pastillas}
    </div>
  )

  return (
    <div
      aria-busy={estado === 'cargando' || undefined}
      className={`group/stat relative flex h-full flex-col gap-2 border border-panel-hairline bg-panel-card p-panel-pad-card ${
        hero ? 'rounded-panel-hero' : 'rounded-panel-card'
      } ${
        link
          ? 'transition-colors duration-[var(--transition-fast)] hover:border-panel-hairline-strong hover:bg-panel-raised'
          : ''
      }`}
    >
      <div className="flex min-w-0 items-center gap-1.5">
        <DataLabel
          className={`min-w-0 ${link ? 'transition-colors group-hover/stat:text-on-surface' : ''}`}
        >
          {rotulo}
        </DataLabel>
        {info && (
          <span className="relative z-10 inline-flex opacity-60 transition-opacity duration-[var(--transition-fast)] group-hover/stat:opacity-100 focus-within:opacity-100 motion-reduce:transition-none">
            <InfoDot title={label} what={info} />
          </span>
        )}
        {link && (
          <ArrowRight
            size={15}
            aria-hidden
            className="ml-auto shrink-0 text-on-surface-variant opacity-0 transition-opacity duration-[var(--transition-fast)] group-hover/stat:opacity-100 group-focus-within/stat:opacity-100 motion-reduce:transition-none"
          />
        )}
      </div>

      {lateral && listo ? (
        <div className="flex flex-1 items-center gap-3">
          <div className="flex min-w-0 flex-1 flex-col gap-2">
            {numero}
            {pastillas}
          </div>
          <div className="shrink-0">{lateral}</div>
        </div>
      ) : (
        numero
      )}

      {visual && listo && <div className="mt-auto pt-1">{visual}</div>}
      {estado === 'cargando' && hint && <SkeletonBlock className="mt-auto h-3 w-40" />}
      {hint && listo && (
        <p
          title={typeof hint === 'string' ? hint : undefined}
          className={`truncate type-panel-caption text-panel-muted ${visual ? '' : 'mt-auto'}`}
        >
          {hint}
        </p>
      )}
    </div>
  )
}

/**
 * Una cifra que no se pudo leer, dicho en su sitio.
 *
 * Es lo contrario de un cero: si la consulta falla, la pantalla no puede
 * pintar «€0,00» ni una lista vacía, porque eso se lee como una respuesta.
 * Pequeño y en línea, para ir donde iba la cifra —una tarjeta, una celda, el
 * resumen de una tabla— sin mover lo de alrededor.
 */
export function NoSePudoLeer({
  onReintentar,
  className = '',
}: {
  /** Sin esto no hay botón: solo el aviso. */
  onReintentar?: () => void
  className?: string
}) {
  return (
    <span className={`inline-flex flex-wrap items-center gap-x-2.5 gap-y-1 ${className}`}>
      <span className="inline-flex items-center gap-1.5 type-panel-body font-semibold text-error">
        <CircleAlert size={15} aria-hidden className="shrink-0" />
        No se pudo leer
      </span>
      {onReintentar && (
        <button
          type="button"
          onClick={(event) => {
            // Puede vivir dentro de una fila o una tarjeta que se pulsan.
            event.stopPropagation()
            onReintentar()
          }}
          // `en-linea`: va en el renglón de la cifra. Con el mínimo táctil de
          // 44 px empujaría la tarjeta entera.
          className="en-linea inline-flex h-7 items-center rounded-panel-control bg-panel-control px-2.5 type-panel-caption font-semibold text-on-surface transition-colors duration-[var(--transition-fast)] hover:bg-shell-inset"
        >
          Reintentar
        </button>
      )}
    </span>
  )
}

/**
 * El cambio, en una pastilla AL LADO de la cifra y no debajo.
 *
 * Debajo estaba escrito entero —«+34 (35 %) frente a los 30 anteriores»— y eso
 * tiene dos problemas: hay que leer la frase para saber si sube o baja, y en
 * una fila de cuatro tarjetas la que tiene la frase más larga se parte en tres
 * renglones y descuadra la fila entera. Una flecha con color se lee sin leer.
 *
 * El color sale de cruzar la dirección con `upIsGood`, porque la flecha sola
 * no dice si es buena noticia: más registros y más expulsados suben igual. El
 * sentido va escrito en `label` («35 % más»): un lector de pantalla que dijera
 * «flecha arriba» obliga a saber de antemano si arriba es bueno.
 */
export function Tendencia({ label, direction, upIsGood = true }: StatTrend) {
  const tono: BadgeTone =
    direction === 'flat' || upIsGood === null
      ? 'neutral'
      : (direction === 'up') === upIsGood
        ? 'success'
        : 'error'
  const icono = direction === 'up' ? TrendingUp : direction === 'down' ? TrendingDown : MoveRight

  return (
    <Badge tone={tono} icono={icono}>
      {label}
    </Badge>
  )
}

// ── Table ─────────────────────────────────────────────────────────────────

/**
 * Tabla del super admin. El panel del comercio no usa ninguna —sus listas son
 * cortas y caben en tarjetas—, pero aquí se miran cientos de filas con ocho
 * columnas y una tarjeta por fila obligaría a hacer scroll toda la mañana.
 */
/**
 * Una cabecera de columna. La forma larga lleva además la regla de esa
 * columna, colgada del rótulo.
 *
 * Es lo que sustituye a los bloques de «Cómo se lee» del pie de la tabla: un
 * párrafo que explica cuatro columnas se lee una vez y estorba las otras
 * doscientas, y encima está lejos de la columna que explica. `DataTable`
 * tiene lo mismo en su `Column.info`.
 */
export type TableHeader = string | { label: string; info: string }

export function Table({
  headers,
  children,
  className = '',
}: {
  headers: Array<TableHeader>
  children: ReactNode
  className?: string
}) {
  return (
    // `overscroll-x-contain`: una tabla de siete columnas no cabe en una
    // tablet y se lee arrastrándola de lado. Sin esto, el arrastre que llega
    // al final de la tabla lo hereda el navegador y dispara el gesto de
    // «atrás» — o sea, que consultar la última columna de las ventas te
    // saca de la pantalla.
    <div
      className={`overflow-x-auto overscroll-x-contain rounded-panel-card border border-panel-hairline bg-panel-card ${className}`}
    >
      <table className="w-full min-w-max border-collapse">
        <thead>
          <tr className="border-b border-panel-hairline">
            {headers.map((h) => {
              const label = typeof h === 'string' ? h : h.label
              return (
                <th key={label} className="px-4 py-2.5 text-left">
                  {/* A 12 y 600, en minúscula de frase: la cabecera rotula la
                      columna sin gritarle a las filas. */}
                  <span className="inline-flex items-center gap-1 type-panel-caption font-semibold text-on-surface-variant">
                    {label}
                    {typeof h !== 'string' && <InfoDot title={h.label} what={h.info} />}
                  </span>
                </th>
              )
            })}
          </tr>
        </thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  )
}

export function Td({
  children,
  className = '',
  colSpan,
}: {
  children?: ReactNode
  className?: string
  colSpan?: number
}) {
  return (
    <td
      colSpan={colSpan}
      className={`px-4 py-2.5 align-middle type-panel-body text-on-surface ${className}`}
    >
      {children}
    </td>
  )
}

/**
 * Una fila de `Table`. Con `onClick` se pulsa y, como en `DataTable`, se
 * enfoca con Tab y se abre con Enter o Espacio. La tecla solo cuenta con el
 * foco en la fila misma: un Enter en un botón de dentro es de ese botón.
 */
export function Tr({
  children,
  onClick,
  className = '',
}: {
  children: ReactNode
  onClick?: () => void
  className?: string
}) {
  function alTeclear(event: KeyboardEvent<HTMLTableRowElement>) {
    if (!onClick || event.target !== event.currentTarget) return
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault()
      onClick()
    }
  }

  return (
    <tr
      onClick={onClick}
      tabIndex={onClick ? 0 : undefined}
      onKeyDown={onClick ? alTeclear : undefined}
      className={`border-b border-panel-hairline last:border-0 ${
        onClick
          ? 'cursor-pointer outline-none hover:bg-panel-raised focus-visible:bg-panel-raised focus-visible:shadow-[inset_2px_0_0_var(--color-primary)]'
          : ''
      } ${className}`}
    >
      {children}
    </tr>
  )
}

// ── Pestañas, filtros y la barra que los junta ────────────────────────────
//
// Tres trabajos distintos que antes hacía una sola pieza, `FilterPills`, con
// la misma pastilla lima para todos. En Consumos había tres filas de pastillas
// idénticas: una cambiaba de vista, otra filtraba por estado, otra por local.
// No se distinguían ni por forma, ni por color, ni por sitio, y el operador no
// tenía manera de saber cuál era navegación y cuál un filtro.
//
// Cada trabajo tiene ahora su forma, y las tres se pueden nombrar de un
// vistazo:
//
//   Tabs        navegación entre las vistas de UNA pantalla. Texto subrayado
//               en blanco sobre una regla, arriba del todo: «estás aquí». Ya
//               no es lima: el lima es solo la acción principal.
//   Segmented   un filtro de pocas opciones fijas. Caja hundida en el lienzo,
//               opción activa levantada. Nunca lima: un filtro no es una
//               acción ni un lugar.
//   FilterBar   la fila donde viven TODOS los filtros de una lista, cada uno
//               con su rótulo encima. Una fila, no cuatro. Con el buscador de
//               la lista dentro, para que no compita con el de la barra de
//               arriba, que busca en todo el panel.
//
// El lima con relleno queda para lo que hace algo: el botón principal.

/** Navegación entre las vistas de una pantalla. */
export function Tabs<T extends string>({
  options,
  value,
  onChange,
  className,
}: {
  /** `insignia`: lo que espera en esa pestaña, con la misma forma que las
   *  insignias del menú. Un cero o `undefined` no pinta nada. */
  options: Array<{ value: T; label: string; insignia?: number }>
  value: T
  onChange: (value: T) => void
  /** Sustituye el margen de abajo (`mb-6`) cuando la pestaña vive dentro de
   *  una pila que ya pone su propio hueco. */
  className?: string
}) {
  return (
    // `flex-wrap` y NO `overflow-x-auto`.
    //
    // 🐛 Con `overflow-x-auto` el CSS obliga a `overflow-y` a pasar de
    // `visible` a `auto` —lo dice la especificación: si un eje deja de ser
    // visible, el otro también—. Y el `-mb-px` con el que el subrayado de la
    // pestaña activa tapa la regla de abajo desborda exactamente 1 px. Uno.
    // Resultado: una barra de scroll vertical, inútil y de un píxel de
    // recorrido, colgada de una tira de 42 px en todas las pantallas que
    // tienen pestañas.
    //
    // Envolviendo no hay contenedor de scroll, así que ese píxel se pinta
    // fuera y ya está. Y cuando no quepan —Ajustes tiene doce— se parten en
    // dos renglones, que además es lo correcto: desplazar esconde pestañas
    // sin avisar de que existen.
    <div
      role="tablist"
      className={`flex flex-wrap gap-x-6 border-b border-panel-hairline ${className ?? 'mb-6'}`}
    >
      {options.map((o) => {
        const seleccionada = o.value === value
        return (
          <button
            key={o.value}
            type="button"
            role="tab"
            aria-selected={seleccionada}
            // El nombre limpio, sin la insignia: lo lee el «volver» de las
            // fichas para decir a qué pestaña regresa.
            data-rotulo={o.label}
            onClick={() => onChange(o.value)}
            // Sin relleno a los lados: el subrayado mide lo que mide la palabra.
            className={`-mb-px inline-flex h-11 shrink-0 items-center gap-2 whitespace-nowrap border-b-2 type-panel-body font-semibold transition-colors duration-[var(--transition-fast)] ${
              seleccionada
                ? 'border-on-surface text-on-surface'
                : 'border-transparent text-panel-muted hover:text-on-surface'
            }`}
          >
            {o.label}
            {!!o.insignia && (
              // Neutra: lo que espera en una pestaña es trabajo, no una alarma.
              <span
                className="flex h-5 min-w-5 items-center justify-center rounded-full bg-panel-control px-1.5 type-panel-caption font-bold text-on-surface"
                aria-label={`${o.insignia} por revisar`}
              >
                {o.insignia > 99 ? '99+' : o.insignia}
              </span>
            )}
          </button>
        )
      })}
    </div>
  )
}

/** Un filtro de pocas opciones fijas. Vive dentro de un `Filtro`, que le pone el rótulo. */
export function Segmented<T extends string>({
  options,
  value,
  onChange,
  etiqueta,
  className = '',
}: {
  options: Array<{ value: T; label: string }>
  value: T
  onChange: (value: T) => void
  /**
   * El nombre del grupo para el lector de pantalla, cuando no hay un `Filtro`
   * que lo rotule: en la cabecera de una sección («Ventana») o junto a un
   * rótulo que no es un `<label>`. Sin él, «7 días · 30 días» no dice de qué.
   */
  etiqueta?: string
  className?: string
}) {
  return (
    <div
      role="group"
      aria-label={etiqueta}
      className={`inline-flex max-w-full flex-wrap gap-0.5 rounded-panel-control border border-panel-hairline bg-shell-canvas p-0.5 ${className}`}
    >
      {options.map((o) => {
        const activa = o.value === value
        return (
          <button
            key={o.value}
            type="button"
            aria-pressed={activa}
            onClick={() => onChange(o.value)}
            // El radio interior es el exterior menos el relleno: si fueran
            // iguales, la opción asomaría por las esquinas de la caja. El
            // alto es el del control menos el relleno y el borde. Escrito así
            // sigue a la escala: 36 con ratón, 40 en la tablet del local.
            className={`h-[calc(var(--spacing-panel-control-sm)-6px)] whitespace-nowrap rounded-[calc(var(--radius-panel-control)-2px)] px-3 type-panel-label transition-colors duration-[var(--transition-fast)] ${
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
  )
}

/** La fila de filtros de una lista. Los hijos se alinean por abajo, que es
 *  donde está el control: los rótulos de arriba pueden medir distinto. */
export function FilterBar({
  children,
  className = '',
}: {
  children: ReactNode
  className?: string
}) {
  return (
    <div className={`mb-6 flex flex-wrap items-end gap-x-5 gap-y-3 ${className}`}>
      {children}
    </div>
  )
}

/**
 * Un filtro con su rótulo encima. Es lo que hace que una fila de controles se
 * lea: sin el rótulo, «Todos» no dice todos QUÉ.
 *
 * `Input` y `Select` ya llevan su propio rótulo y no necesitan esto; es para
 * `Segmented` y para cualquier grupo de controles que compartan uno.
 */
export function Filtro({
  label,
  children,
  className = '',
}: {
  label: string
  children: ReactNode
  className?: string
}) {
  return (
    <div className={`flex flex-col gap-shell-gap-stack ${className}`}>
      <DataLabel>{label}</DataLabel>
      {children}
    </div>
  )
}

/**
 * @deprecated Es `Segmented`. El nombre se queda para lo que todavía no ha
 * decidido si es una pestaña o un filtro; cuando lo decida, cambia de nombre.
 */
export const FilterPills = Segmented

// ── El rango de fechas ────────────────────────────────────────────────────
//
// `Rango` y sus cuentas —`sumarDias`, `atajosDeRango`, `describirRango`…—
// viven en `kit/rango.ts`, porque `Periodo` las usa, y se reexportan al final.

// ── Formato ───────────────────────────────────────────────────────────────

/**
 * La zona del negocio.
 *
 * Ronda opera en Venezuela y todo se calcula ahí: el día operativo de 10 AM a
 * 10 AM, la vigencia de las cotizaciones, los cierres de ciclo (docs/05 §1).
 * El panel se abre desde el navegador de quien sea —un gerente de viaje, un
 * admin en otro país—, así que la zona se fija aquí y no se hereda del
 * sistema: si no, dos personas mirando la misma fila leerían horas distintas.
 *
 * Venezuela está fija en UTC−4, sin horario de verano.
 */
export const TIME_ZONE = 'America/Caracas'

/**
 * '$150,00' — un importe con sus céntimos, en dólares.
 *
 * **El dólar BCV es la moneda del sistema** (plan §1): la deuda del paciente,
 * los límites de nivel y la liquidación a la clínica viven en dólares. El
 * bolívar es la capa de presentación, a la tasa BCV del dólar del día en que
 * se paga. El formato es el de Ronda con el euro: símbolo pegado y coma
 * decimal de aquí ('$1.234,50').
 *
 * Un negativo lleva el signo DELANTE del símbolo y es el signo menos de
 * verdad (U+2212): '−$16,70'. Con el guion pegado a la cifra, en «capital
 * libre» se leía como un guion de separación.
 */
export function formatUsd(amount: number): string {
  const cifra = Math.abs(amount).toLocaleString('es-VE', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })
  return `${signo(amount, cifra)}$${cifra}`
}

/**
 * El signo de un importe ya escrito: '−' solo si es negativo Y queda alguna
 * cifra distinta de cero. `-0` —una cuenta del ledger en cero, negada— y
 * `-0,001` —que se redondea a cero— salen sin signo: '−$0,00' no existe.
 */
function signo(amount: number, cifra: string): string {
  return amount < 0 && /[1-9]/.test(cifra) ? '−' : ''
}

/**
 * '$450', '$1,3 k', '$2,4 M' — un importe donde no caben sus céntimos.
 *
 * Es para el eje de un gráfico y para la etiqueta pegada a una barra, y solo
 * para eso. Ahí el número no se copia ni se cuadra con nada: se usa para
 * estimar una altura a ojo, y '$1.284,50' escrito en vertical cada cuarenta
 * píxeles convierte el eje en una pared de dígitos.
 *
 * En cualquier sitio donde la cifra sea el dato —una tarjeta, una fila, el
 * renglón de lectura del propio gráfico— va `formatUsd` con sus céntimos.
 */
export function formatUsdShort(amount: number): string {
  const cifra = cifraCorta(Math.abs(amount))
  return `${signo(amount, cifra)}$${cifra}`
}

function cifraCorta(abs: number): string {
  if (abs >= 1_000_000) return `${corto(abs / 1_000_000, 1)} M`
  if (abs >= 1_000) return `${corto(abs / 1_000, 1)} k`
  // Los decimales no son un capricho por debajo de cien: la escala de un
  // gráfico con poco movimiento se mide en pasos de 2,5 o de 1,5, y
  // redondeando a entero el eje diría «€3 / €5 / €8 / €10» donde las líneas
  // están en 2,5 / 5 / 7,5 / 10. Un eje que miente es peor que no tenerlo.
  if (abs >= 100) return corto(abs, 0)
  if (abs >= 10) return corto(abs, 1)
  return corto(abs, 2)
}

/** Sin el ',0' de los redondos: '1,3' pero '2'. */
function corto(value: number, decimales: number): string {
  return value.toLocaleString('es-VE', { maximumFractionDigits: decimales })
}

/**
 * "2 cuotas de €3,08" — cómo va a pagar el cliente lo que se le acaba de
 * cobrar.
 *
 * El céntimo impar se parte igual que en la base (`helios_assign_debt`, que
 * hace `round(total / 2, 2)` y le da el resto a la segunda): si las dos
 * cuotas no salen iguales se nombran las dos, porque una sola cifra ahí
 * prometería un céntimo que no es. Lo usará `/registrar` (fase 2).
 */
export function describeInstallments(payableUsd: number): string {
  const first = Math.round((payableUsd / 2) * 100) / 100
  const second = Math.round((payableUsd - first) * 100) / 100

  return first === second
    ? `2 cuotas de ${formatUsd(first)}`
    : `2 cuotas: ${formatUsd(first)} y ${formatUsd(second)}`
}

export function formatVes(amount: number): string {
  return `${amount.toLocaleString('es-VE', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })} Bs.`
}

/**
 * La tasa del día con su unidad: 'Tasa BCV 36,52 Bs/$'.
 *
 * La unidad va completa —bolívares POR DÓLAR—: el BCV publica varias tasas el
 * mismo día. Sin el "/$" al lado, quien lee no puede distinguir si la cifra
 * que le enseña el panel es la que esperaba o la de otra moneda.
 *
 * Se imprime con los seis decimales con los que se guarda
 * (`exchange_rates.rate` es numeric(18,6)), porque es la tasa con la que se
 * convirtió el importe que ve el paciente: recortarla a dos deja un comprobante
 * cuyas cuentas no cuadran si alguien las rehace con la cifra impresa.
 */
export function formatBcvRate(rate: number): string {
  return `Tasa BCV ${rate.toLocaleString('es-VE', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 6,
  })} Bs/$`
}

/**
 * Fecha de una columna `date` de Postgres — `business_date`, `due_date`,
 * `birth_date`.
 *
 * No vale `formatDateTime` para esto. `new Date('2026-08-22')` se interpreta
 * como medianoche **UTC**, que en Caracas (UTC−4) son las 8 de la noche del
 * día **21**: la fecha sale un día antes. Con un vencimiento eso es la
 * diferencia entre "vence hoy" y "vencido", y no da ningún error — solo un
 * número mal.
 *
 * Aquí no hay zona horaria que convertir: un `date` ya es el día, sin hora.
 * Y por eso mismo no lleva hora al lado: la que le tocaría es la del instante
 * que lo originó, que vive en otra columna (`confirmed_at`, `created_at`) y
 * se pinta con `formatTime`.
 */
export function formatDay(value: string | null): string {
  if (!value) return '—'
  const [year = '', month = '', day = ''] = value.slice(0, 10).split('-')
  return `${day}/${month}/${year.slice(2)}`
}

/**
 * '21 ago' — el día sin el año, para el eje de una serie corta.
 *
 * En una tira de treinta barras solo caben siete fechas, y '21/08/26' gasta
 * ocho caracteres en decir dos cosas que el lector ya sabe: que es de este año
 * y que el separador es una barra. El mes en letra además quita la duda de si
 * 08/09 es septiembre u agosto.
 */
export function formatDayShort(value: string | null): string {
  if (!value) return '—'
  const [, month = '', day = ''] = value.slice(0, 10).split('-')
  return `${Number(day)} ${MESES_CORTOS[Number(month) - 1] ?? month}`
}

/**
 * Un número para leer, con la coma decimal de aquí.
 *
 * `toFixed` es de JavaScript y escribe '3.1': un punto decimal inglés al lado
 * de un '$42,01' formateado en castellano, en la misma tarjeta. Para cualquier
 * cifra que se PINTA —medias, veces, personas por consumo— se usa esto.
 */
export function formatNumero(value: number, decimales = 1): string {
  return value.toLocaleString('es-VE', {
    minimumFractionDigits: decimales,
    maximumFractionDigits: decimales,
  })
}

/** '35 %' con la coma de aquí si lleva decimales. */
export function formatPorcentaje(value: number, decimales = 0): string {
  return `${formatNumero(value, decimales)} %`
}

/**
 * Hoy en Caracas, con la forma de una columna `date` — que es la que espera
 * un `<input type="date">`.
 *
 * No vale `new Date().toISOString().slice(0, 10)`: eso es hoy en UTC, y a
 * partir de las 8 de la noche en Caracas ya es mañana. Con una fecha de
 * vigencia o de pago, ese día de más no da ningún error — solo una fecha mal.
 *
 * Es el día de CALENDARIO. El del dinero es `diaOperativo`.
 */
export function hoyCaracas(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TIME_ZONE }).format(new Date())
}

/**
 * El día operativo de un instante (por defecto, ahora): de medianoche a
 * medianoche en Caracas, el mismo corte que `helios_business_date`.
 *
 * En Ronda el día iba de 10:00 a 10:00 porque la madrugada era de la noche que
 * se cerraba; una consulta médica no tiene madrugada, y en Helios el día
 * operativo es el de calendario (plan H2). Se deja la función, y no se cambia
 * por `hoyCaracas`, para que el corte viva en un solo sitio si algún día
 * vuelve a moverse (`business_day_offset_hours` en la base).
 *
 * Se calcula en el navegador para que lo que depende de él —«Recordar hoy», el
 * mes que se cierra por defecto— no se quede sin día si otra consulta falla.
 */
export function diaOperativo(instante: Date = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TIME_ZONE }).format(instante)
}

/**
 * Solo la hora de Caracas de un instante: '21:41'.
 *
 * Para las tablas que ya llevan el DÍA OPERATIVO en otra columna (el
 * `business_date`). Ahí la fecha la pone `formatDay` con
 * el `business_date` y la hora sale de aquí, con el `confirmed_at`.
 */
export function formatTime(value: string | null): string {
  if (!value) return '—'
  return new Date(value).toLocaleTimeString('es-VE', {
    hour: '2-digit',
    minute: '2-digit',
    timeZone: TIME_ZONE,
  })
}

/**
 * Fecha Y HORA de un instante (`timestamptz`), en la zona del negocio:
 * '25/08/26, 21:41'.
 *
 * No hay una versión "solo el día" de esto, y es a propósito. Todo movimiento
 * de dinero se enseña con su hora (docs/05 §1): sin ella, dos consumos de la
 * misma noche en el mismo local son indistinguibles, y un pago reportado a
 * las 11 PM no se puede cotejar contra el estado de cuenta del banco. La
 * versión sin hora existió y su único efecto fue esconder el dato justo en
 * las pantallas de conciliación.
 *
 * Para columnas `date` —que no son instantes— está `formatDay`.
 */
export function formatDateTime(value: string | null): string {
  if (!value) return '—'
  return new Date(value).toLocaleString('es-VE', {
    day: '2-digit',
    month: '2-digit',
    year: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    timeZone: TIME_ZONE,
  })
}

/**
 * '15,8 %' — un porcentaje con el formato de Venezuela.
 *
 * Coma decimal y espacio antes del signo. Lo hacía cada pantalla con
 * `.toFixed(1) + '%'`, que imprime punto decimal: en un panel donde el dinero
 * lleva coma, el mismo número se escribía de dos maneras en la misma fila.
 */
export function formatPct(value: number, decimals = 1): string {
  return `${value.toLocaleString('es-VE', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })} %`
}

/**
 * '6 d', '3 h', '45 min' — cuánto lleva esperando algo.
 *
 * Nunca '158,1 h'. Una cola que lleva seis días parada tiene que leerse como
 * seis días: en horas, el número es grande pero no dice nada.
 */
export function formatWaiting(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return 'ahora'
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${Math.max(1, minutes)} min`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} h`
  return `${Math.floor(hours / 24)} d`
}

/** Las horas que devuelve el servidor, con el mismo vocabulario. */
export function formatWaitingHours(hours: number): string {
  return formatWaiting(hours * 3600)
}

/**
 * '0424-2581359' — el teléfono como lo marca la gente.
 *
 * Se guarda en E.164 ('584242581359') porque es lo que necesitan WhatsApp y
 * el proveedor de push, pero nadie en Venezuela dicta su número así. Lo que
 * no encaje con el patrón se devuelve tal cual: inventar un formato sobre un
 * dato raro esconde justo el dato que hay que mirar.
 */
export function formatPhone(value: string | null): string {
  if (!value) return '—'
  const digits = value.replace(/\D/g, '')
  const local = digits.startsWith('58') ? digits.slice(2) : digits
  if (local.length !== 10) return value
  return `0${local.slice(0, 3)}-${local.slice(3)}`
}

/** El teléfono en el formato que pide wa.me: dígitos, con el 58 delante. */
export function whatsappNumber(value: string | null): string {
  const digits = (value ?? '').replace(/\D/g, '')
  if (!digits) return ''
  return digits.startsWith('58') ? digits : `58${digits.replace(/^0/, '')}`
}

/**
 * 'V-26.484.675' — la cédula con su letra y sus puntos de millar.
 *
 * Llega de Didit de varias formas ('V26484675', '26484675', 'V-26484675') y
 * se coteja a ojo contra lo que dice el pagador en una transferencia. Sin
 * puntos, dos cédulas que difieren en un dígito se leen iguales.
 */
export function formatDocument(value: string | null): string {
  if (!value) return '—'
  const raw = value.trim().toUpperCase()
  const match = raw.match(/^([VEJGP])?-?\s*(\d{6,9})$/)
  if (!match) return value
  // El grupo de la letra es opcional: sin ella se asume V, que es el 99 % de
  // los casos y lo que la propia cédula lleva impreso.
  const letter = match.at(1)
  const digits = Number(match[2]).toLocaleString('es-VE')
  return `${letter ?? 'V'}-${digits}`
}

export { Modal, ConfirmDialog } from './overlays'
export type { NivelConfirmacion } from './overlays'

export { HeliosIsotipo, HeliosLogo } from './HeliosLogo'

// ── Las piezas de `kit/` ──────────────────────────────────────────────────
//
// Una por archivo. Se reexportan aquí para que el panel siga importando todo
// de `@/components/ui`.

// Las clases de un botón y de un campo, para lo que se pinta como botón sin
// serlo: un enlace de la ficha, un `<label>` que abre un archivo.
export { CLASE_CAMPO, bordeDeCampo, claseDeBoton } from './kit/clases'
export type { ButtonSize, ButtonVariant } from './kit/clases'
export { Callout } from './kit/Callout'
export type { TonoDeCallout } from './kit/Callout'
export { CampoDeRango } from './kit/CampoDeRango'
export { Checkbox } from './kit/Checkbox'
export { IconoDeArea } from './kit/IconoDeArea'
export { InfoDot } from './kit/InfoDot'
export { Menu } from './kit/Menu'
export type { ItemDeMenu } from './kit/Menu'
export { Meter } from './kit/Meter'
export { Periodo } from './kit/Periodo'
export { SelectorDeFechas } from './kit/SelectorDeFechas'
export type { OpcionDeFecha, Paso } from './kit/SelectorDeFechas'
export {
  MESES_LARGOS,
  atajosDeRango,
  describirRango,
  diasDelRango,
  escribirFecha,
  leerFecha,
  primeroDelMes,
  rangoCorto,
  rangoDeAlLado,
  sumarDias,
} from './kit/rango'
export type { Rango } from './kit/rango'
export { Seccion } from './kit/Seccion'
export { Switch } from './kit/Switch'
export { Tecla } from './kit/Tecla'
export { Textarea } from './kit/Textarea'
export { Tooltip } from './kit/Tooltip'

