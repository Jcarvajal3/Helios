import { useLayoutEffect, useRef, useState } from 'react'
import type { CSSProperties, FocusEvent, KeyboardEvent, PointerEvent, ReactNode } from 'react'
import { createPortal } from 'react-dom'

import { calcularPosicion } from '@/components/kit/posicion'
import type { LadoFlotante } from '@/components/kit/posicion'

// ═══════════════════════════════════════════════════════════════════════════
// Cómo se lee un gráfico cuando se señala: qué punto está señalado (ratón,
// dedo o flechas), el globo con todas las series de ese punto y la muestra de
// color que identifica una serie en la leyenda y en el globo.
//
// El globo ayuda y nunca es la única manera de leer un número: la tabla de
// la cabecera (`ChartCard`) los tiene todos.
//
// Dos maneras de pintarlo:
//
// - `Globo`, dentro del lienzo de un gráfico entero (barras, líneas,
//   columnas): va en `absolute` junto a la guía del punto señalado.
// - `GloboFlotante`, para lo demás —una marca suelta, una celda de una
//   rejilla, el segmento de una barra, una chispa dentro de una cifra—: va en
//   un portal a `document.body` y en `position: fixed`, así ninguna caja que
//   recorta (una tabla que se desplaza, un `@container`) lo corta. Encima de
//   él están `useGloboDeMarca`, `MarcaConGlobo` y `useRecorridoDeMarcas`.
//
// Los dos salen AL INSTANTE, sin la espera del `title` del navegador, y
// enseñan lo mismo: un título y una fila por dato (muestra, cifra y rótulo).
// ═══════════════════════════════════════════════════════════════════════════

/** Cómo se dibuja la muestra de una serie: como su marca. */
export type FormaDeMuestra = 'punto' | 'linea' | 'discontinua'

/** La marquita de color que dice de qué serie es algo. */
export function Muestra({ color, forma = 'punto' }: { color: string; forma?: FormaDeMuestra }) {
  if (forma === 'discontinua') {
    return (
      <i
        aria-hidden
        className="w-4 shrink-0 border-t border-dashed"
        style={{ borderColor: color }}
      />
    )
  }
  return (
    <i
      aria-hidden
      className={`shrink-0 rounded-full ${forma === 'linea' ? 'h-0.5 w-3.5' : 'size-2'}`}
      style={{ backgroundColor: color }}
    />
  )
}

/**
 * El punto señalado de un gráfico de `n` puntos, y lo que hay que poner en
 * el lienzo para señalarlo.
 *
 * Un `pointermove` sobre la caja entera, y no un `mouseenter` por barra: así
 * la barra de un píxel se señala igual que la gorda, y en la tablet se
 * recorre el gráfico arrastrando el dedo. Con el teclado, ← → Inicio y Fin
 * lo recorren y Escape lo suelta.
 */
export function useSenalado(n: number, indiceDe: (fraccion: number, n: number) => number) {
  const [punto, setPunto] = useState<number | null>(null)

  function onPointerMove(e: PointerEvent<HTMLElement>) {
    const caja = e.currentTarget.getBoundingClientRect()
    if (caja.width === 0) return
    setPunto(indiceDe((e.clientX - caja.left) / caja.width, n))
  }

  function onKeyDown(e: KeyboardEvent<HTMLElement>) {
    const paso = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0
    if (paso !== 0) {
      e.preventDefault()
      setPunto((actual) => Math.min(n - 1, Math.max(0, (actual ?? (paso > 0 ? -1 : n)) + paso)))
    } else if (e.key === 'Home' || e.key === 'End') {
      e.preventDefault()
      setPunto(e.key === 'Home' ? 0 : n - 1)
    } else if (e.key === 'Escape') {
      setPunto(null)
    }
  }

  return {
    // Si los datos encogen, un índice de antes apuntaría fuera.
    punto: punto !== null && punto < n ? punto : null,
    /** Señala un punto sin ratón ni flechas: el que se elige al entrar con Tab. */
    senalar: (i: number | null) => setPunto(i === null ? null : Math.min(n - 1, Math.max(0, i))),
    lienzo: {
      tabIndex: 0,
      onPointerMove,
      onPointerLeave: () => setPunto(null),
      onKeyDown,
      onBlur: () => setPunto(null),
    },
  }
}

export type FilaDelGlobo = {
  key: string
  rotulo: string
  /** Ya formateado. Es lo que manda en el globo: la serie ya se sabe. */
  valor: string
  color: string
  forma?: FormaDeMuestra
}

/** Lo que dice un globo: el título, una fila por dato y, si hace falta, una nota. */
export type ContenidoDelGlobo = {
  titulo: string
  filas: ReadonlyArray<FilaDelGlobo>
  nota?: string
}

/** La caja del globo, la misma en el lienzo y flotando. */
const CAJA_DEL_GLOBO =
  'anim-globo pointer-events-none whitespace-nowrap rounded-panel-control border border-panel-hairline bg-panel-control px-3 py-2 shadow-lg'

/** Lo de dentro del globo: título, filas ordenadas y nota. */
function CuerpoDelGlobo({ titulo, filas, nota }: ContenidoDelGlobo) {
  return (
    <>
      <p className="type-panel-caption text-on-surface-variant">{titulo}</p>
      <ul className="mt-1 flex flex-col gap-0.5">
        {filas.map((f) => (
          <li key={f.key} className="flex items-center gap-2">
            <Muestra color={f.color} forma={f.forma ?? 'linea'} />
            <span className="type-panel-label tabular-nums text-on-surface">{f.valor}</span>
            <span className="type-panel-caption text-on-surface-variant">{f.rotulo}</span>
          </li>
        ))}
      </ul>
      {/* La nota puede ser una frase entera: se parte en líneas y no estira el globo. */}
      {nota && <p className="mt-1 max-w-72 whitespace-normal type-panel-caption text-panel-muted">{nota}</p>}
    </>
  )
}

/**
 * El globo del punto señalado, al lado de la guía: a su derecha mientras
 * quepa y a su izquierda pasada la mitad, para no tapar lo que se señala.
 * `x` es la posición de la guía en % del ancho del lienzo.
 */
export function Globo({
  x,
  titulo,
  filas,
  nota,
}: {
  x: number
  titulo: string
  filas: ReadonlyArray<FilaDelGlobo>
  nota?: string
}) {
  const lado: CSSProperties =
    x <= 55 ? { left: `calc(${x}% + 12px)` } : { right: `calc(${100 - x}% + 12px)` }

  return (
    <div aria-hidden className={`absolute top-0 z-20 ${CAJA_DEL_GLOBO}`} style={lado}>
      <CuerpoDelGlobo titulo={titulo} filas={filas} nota={nota} />
    </div>
  )
}

/** Lo que el lector de pantalla canta al recorrer el gráfico con las flechas. */
export function lecturaDelPunto(
  titulo: string,
  filas: ReadonlyArray<FilaDelGlobo>,
  nota?: string,
): string {
  const valores = filas.map((f) => (f.rotulo ? `${f.rotulo}: ${f.valor}` : f.valor)).join(', ')
  return `${titulo}. ${valores}${nota ? `. ${nota}` : ''}`
}

// ── El globo que flota ─────────────────────────────────────────────────────

/**
 * El globo de algo que no es el lienzo de un gráfico entero: encima (o
 * debajo, si arriba no cabe) de `ancla`, centrado en su guía.
 *
 * Va en un portal y en `position: fixed`: una celda de una tabla que se
 * desplaza o una chispa dentro de un `@container` no lo recortan. Por eso
 * copia de `ancla` el tono del área (`--area`), que en `document.body` ya no
 * se hereda: sin eso, la muestra de la serie principal saldría gris.
 *
 * Sin `ancla` no pinta nada. `x` es la guía, en % del ancho de `ancla`: el
 * centro por defecto, o el de la barra señalada dentro de una caja.
 */
export function GloboFlotante({
  ancla,
  x = 50,
  lado = 'arriba',
  titulo,
  filas,
  nota,
}: ContenidoDelGlobo & {
  ancla: HTMLElement | null
  x?: number
  lado?: LadoFlotante
}) {
  const capaRef = useRef<HTMLDivElement>(null)
  const [posicion, setPosicion] = useState<{ top: number; left: number } | null>(null)
  const [area, setArea] = useState('')

  useLayoutEffect(() => {
    if (!ancla) return

    function colocar() {
      const capa = capaRef.current
      if (!ancla || !capa) return
      const caja = ancla.getBoundingClientRect()
      const p = calcularPosicion({
        ancla: { top: caja.top, left: caja.left + (caja.width * x) / 100, width: 0, height: caja.height },
        capa: { ancho: capa.offsetWidth, alto: capa.offsetHeight },
        vista: { ancho: document.documentElement.clientWidth, alto: window.innerHeight },
        lado,
        alineacion: 'centro',
        separacion: 8,
      })
      setPosicion({ top: p.top, left: p.left })
    }

    setArea(getComputedStyle(ancla).getPropertyValue('--area').trim())
    colocar()
    // Se vuelve a medir al desplazar cualquier contenedor, al cambiar la
    // ventana y cuando el propio globo cambia de tamaño (otro punto, otras
    // cifras).
    const observador = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(colocar)
    if (capaRef.current) observador?.observe(capaRef.current)
    window.addEventListener('resize', colocar)
    window.addEventListener('scroll', colocar, true)
    return () => {
      observador?.disconnect()
      window.removeEventListener('resize', colocar)
      window.removeEventListener('scroll', colocar, true)
    }
  }, [ancla, x, lado])

  if (!ancla) return null

  return createPortal(
    <div
      ref={capaRef}
      aria-hidden
      data-flotante=""
      className={`fixed z-60 ${CAJA_DEL_GLOBO}`}
      style={{
        top: posicion?.top ?? 0,
        left: posicion?.left ?? 0,
        // Hasta medirse no se enseña: si no, asomaría un instante en la esquina.
        visibility: posicion ? undefined : 'hidden',
        ...(area ? ({ '--area': area } as CSSProperties) : {}),
      }}
    >
      <CuerpoDelGlobo titulo={titulo} filas={filas} nota={nota} />
    </div>,
    document.body,
  )
}

// ── Una marca suelta ───────────────────────────────────────────────────────

/** Lo que se reparte sobre el elemento que dispara el globo de una marca. */
export type DisparadorDelGlobo<TElemento extends HTMLElement> = {
  ref: (elemento: TElemento | null) => void
  onPointerEnter: (e: PointerEvent<TElemento>) => void
  onPointerLeave: (e: PointerEvent<TElemento>) => void
  onPointerDown: (e: PointerEvent<TElemento>) => void
  onFocus: (e: FocusEvent<TElemento>) => void
  onBlur: () => void
  onKeyDown: (e: KeyboardEvent<TElemento>) => void
}

/**
 * El globo de UNA marca (un anillo, una fila de un embudo, una pastilla),
 * para ponérselo a un elemento que ya existe —un `<Link>`, una fila—:
 *
 *   const { disparador, globo } = useGloboDeMarca({ titulo, filas })
 *   return <><Link {...disparador} …>…</Link>{globo}</>
 *
 * Sale al instante con el ratón encima y con el foco del TECLADO
 * (`:focus-visible`); con el dedo, un toque lo abre y otro fuera lo cierra.
 * Escape lo cierra. Un clic con el ratón no lo deja fijo: si no, al pasar a
 * la marca de al lado quedarían dos abiertos.
 *
 * Con `contenido` en `null` no hay globo (una marca sin dato todavía).
 */
export function useGloboDeMarca<TElemento extends HTMLElement = HTMLElement>(
  contenido: ContenidoDelGlobo | null,
  opciones: { lado?: LadoFlotante; x?: number } = {},
): {
  abierto: boolean
  disparador: DisparadorDelGlobo<TElemento>
  globo: ReactNode
  /**
   * Para colgar el globo de OTRO elemento que el que recibe el ratón y el
   * foco (una fila entera que se señala y una barrita de la que cuelga).
   * Por defecto cuelga de `disparador.ref`.
   */
  anclar: (elemento: HTMLElement | null) => void
} {
  const [ancla, setAncla] = useState<TElemento | null>(null)
  const [encima, setEncima] = useState(false)
  const [enfocada, setEnfocada] = useState(false)
  const [tocada, setTocada] = useState(false)

  const abierto = contenido !== null && (encima || enfocada || tocada)

  const disparador: DisparadorDelGlobo<TElemento> = {
    ref: setAncla,
    onPointerEnter: (e) => {
      if (e.pointerType !== 'touch') setEncima(true)
    },
    onPointerLeave: (e) => {
      if (e.pointerType !== 'touch') setEncima(false)
    },
    onPointerDown: (e) => {
      if (e.pointerType === 'touch') setTocada((v) => !v)
    },
    onFocus: (e) => {
      // Lo que recibió el foco: la marca, o un enlace de dentro de ella.
      const enfocado = e.target instanceof HTMLElement ? e.target : e.currentTarget
      if (enfocado.matches(':focus-visible')) setEnfocada(true)
    },
    onBlur: () => {
      setEnfocada(false)
      setTocada(false)
    },
    onKeyDown: (e) => {
      if (e.key !== 'Escape') return
      setEncima(false)
      setEnfocada(false)
      setTocada(false)
    },
  }

  return {
    abierto,
    disparador,
    anclar: setAncla as (elemento: HTMLElement | null) => void,
    globo: abierto ? (
      <GloboFlotante ancla={ancla} lado={opciones.lado} x={opciones.x} {...contenido} />
    ) : null,
  }
}

/**
 * Una marca suelta que enseña un dato, con su globo: se enfoca con Tab, el
 * lector de pantalla la canta entera y el ratón la lee al pasar.
 *
 *   <MarcaConGlobo titulo="Semana del 14" filas={[{ key: 'c', rotulo: 'Cobrado',
 *     valor: '€120,00', color: SERIE.principal }]} className="…">
 *     <span className="…" />
 *   </MarcaConGlobo>
 *
 * Es lo que sustituye al `title` del navegador en una marca de datos: sale
 * al instante y con las cifras ordenadas. Para muchas marcas en una misma
 * caja (una escalera, los segmentos de una barra) mejor `useRecorridoDeMarcas`,
 * que deja UNA parada de Tab y las recorre con las flechas.
 */
export function MarcaConGlobo({
  titulo,
  filas,
  nota,
  lado,
  x,
  como = 'span',
  enfocable = true,
  className = '',
  style,
  children,
}: ContenidoDelGlobo & {
  lado?: LadoFlotante
  /** De qué punto de la marca cuelga el globo, en % de su ancho. Por defecto, el centro. */
  x?: number
  /** `div` dentro de un bloque; `span` (por defecto) dentro de una línea. */
  como?: 'span' | 'div'
  /**
   * Con `false` la marca no entra en el orden del tabulador: el foco lo
   * lleva algo de dentro (un enlace), y el globo sale igual al enfocarlo.
   */
  enfocable?: boolean
  className?: string
  style?: CSSProperties
  children?: ReactNode
}) {
  const { disparador, globo } = useGloboDeMarca<HTMLElement>({ titulo, filas, nota }, { lado, x })
  const comun = {
    ...disparador,
    ...(enfocable ? { tabIndex: 0, role: 'img', 'aria-label': lecturaDelPunto(titulo, filas, nota) } : {}),
    className,
    style,
  }

  return (
    <>
      {como === 'div' ? <div {...comun}>{children}</div> : <span {...comun}>{children}</span>}
      {globo}
    </>
  )
}

// ── Muchas marcas en una caja ──────────────────────────────────────────────

/** Las teclas que mueven entre marcas, y cuánto. */
function pasoDeTecla(tecla: string, columnas: number | undefined): number | 'inicio' | 'fin' | null {
  switch (tecla) {
    case 'ArrowRight':
      return 1
    case 'ArrowLeft':
      return -1
    case 'ArrowDown':
      return columnas ?? 1
    case 'ArrowUp':
      return -(columnas ?? 1)
    case 'Home':
      return 'inicio'
    case 'End':
      return 'fin'
    default:
      return null
  }
}

/**
 * Varias marcas en una misma caja —los segmentos de una barra, los escalones
 * de un embudo, las celdas de una rejilla, los peldaños de una escalera—
 * con UNA parada de Tab: la caja. Con el ratón se señala la marca que hay
 * debajo; con las flechas, la de al lado (↑ ↓ saltan `columnas` si es una
 * rejilla), Inicio y Fin van a los extremos y Escape suelta.
 *
 *   const r = useRecorridoDeMarcas(n, { saltar: (i) => valores[i] === 0 })
 *   <div {...r.caja} role="img" aria-label="…">
 *     {valores.map((v, i) => <span key={i} {...r.marca(i)} … />)}
 *   </div>
 *   {r.senalada !== null && <GloboFlotante ancla={r.ancla} {...contenidoDe(r.senalada)} />}
 *
 * `saltar` deja fuera las marcas que no se pueden señalar (un cero que no
 * ocupa barra, el hueco del futuro en una rejilla). Al entrar con Tab se
 * señala `alEnfocar` (por defecto, la primera que se puede).
 */
export function useRecorridoDeMarcas(
  n: number,
  opciones: { saltar?: (i: number) => boolean; columnas?: number; alEnfocar?: number } = {},
) {
  const { saltar = () => false, columnas, alEnfocar } = opciones
  const elementos = useRef<Array<HTMLElement | null>>([])
  const [senal, setSenal] = useState<{ i: number; ancla: HTMLElement | null } | null>(null)

  const vale = (i: number) => i >= 0 && i < n && !saltar(i)

  function ir(i: number | null, { mostrar = false }: { mostrar?: boolean } = {}) {
    const ancla = i === null || !vale(i) ? null : (elementos.current[i] ?? null)
    setSenal(i === null || !vale(i) ? null : { i, ancla })
    // Con las flechas, la marca se trae a la vista: la columna 10 de una
    // rejilla que se desplaza a lo ancho no se ve sin mover la tabla.
    if (mostrar) ancla?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
  }

  /** La siguiente que se puede señalar desde `desde`, en pasos de `paso`. */
  function siguiente(desde: number, paso: number): number | null {
    // En una rejilla, si la de abajo es un hueco, la última de su fila que
    // no lo es: el borde escalonado de unas cohortes.
    if (columnas && Math.abs(paso) === columnas) {
      const destino = desde + paso
      if (destino < 0 || destino >= n) return null
      const inicioDeFila = destino - (destino % columnas)
      for (let j = destino; j >= inicioDeFila; j--) if (vale(j)) return j
      return null
    }
    for (let j = desde + paso; j >= 0 && j < n; j += paso) if (vale(j)) return j
    return null
  }

  const primera = () => siguiente(-1, 1)
  const ultima = () => siguiente(n, -1)

  function onKeyDown(e: KeyboardEvent<HTMLElement>) {
    if (e.key === 'Escape') {
      setSenal(null)
      return
    }
    const paso = pasoDeTecla(e.key, columnas)
    if (paso === null) return
    e.preventDefault()
    const actual = senal?.i ?? null
    if (paso === 'inicio' || paso === 'fin') {
      ir(paso === 'inicio' ? primera() : ultima(), { mostrar: true })
      return
    }
    if (actual === null) {
      ir(paso > 0 ? primera() : ultima(), { mostrar: true })
      return
    }
    const destino = siguiente(actual, paso)
    if (destino !== null) ir(destino, { mostrar: true })
  }

  function onFocus(e: FocusEvent<HTMLElement>) {
    if (e.target !== e.currentTarget || senal !== null) return
    if (!e.currentTarget.matches(':focus-visible')) return
    ir(alEnfocar !== undefined && vale(alEnfocar) ? alEnfocar : primera())
  }

  const i = senal !== null && vale(senal.i) ? senal.i : null

  return {
    /** El índice de la marca señalada, o `null`. */
    senalada: i,
    /** El elemento de la marca señalada: el `ancla` de su `GloboFlotante`. */
    ancla: i === null ? null : (senal?.ancla ?? null),
    /** Señala una marca desde fuera (`null` suelta). */
    senalar: (indice: number | null) => ir(indice),
    /** Para la caja: la parada de Tab y las teclas. */
    caja: {
      tabIndex: 0,
      onKeyDown,
      onFocus,
      onBlur: (e: FocusEvent<HTMLElement>) => {
        if (!(e.relatedTarget instanceof Node && e.currentTarget.contains(e.relatedTarget))) setSenal(null)
      },
      onPointerLeave: (e: PointerEvent<HTMLElement>) => {
        if (e.pointerType !== 'touch') setSenal(null)
      },
    },
    /** Para cada marca: su elemento y el ratón (o el dedo) encima. */
    marca: (indice: number) => ({
      ref: (el: HTMLElement | null) => {
        elementos.current[indice] = el
      },
      onPointerEnter: (e: PointerEvent<HTMLElement>) => {
        if (vale(indice)) setSenal({ i: indice, ancla: e.currentTarget })
      },
    }),
  }
}
