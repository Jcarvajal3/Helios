import { useEffect, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { CalendarDays, ChevronDown } from 'lucide-react'

import { formatPct } from '@/components/ui'

/**
 * Las piezas de las pantallas propias de Lite, todas con las clases de la
 * maqueta (`estilos/maqueta.css`): la cabecera con su periodo, las vistas en
 * píldoras, la franja de cuatro cifras y el menú del periodo.
 */

// ── El periodo ─────────────────────────────────────────────────────────────

export type Periodo = 'hoy' | '7d' | '30d'

export const PERIODOS: ReadonlyArray<{ id: Periodo; rotulo: string; dias: number }> = [
  { id: 'hoy', rotulo: 'Hoy', dias: 1 },
  { id: '7d', rotulo: 'Últimos 7 días', dias: 7 },
  { id: '30d', rotulo: 'Últimos 30 días', dias: 30 },
]

export function diasDe(periodo: Periodo): number {
  return PERIODOS.find((p) => p.id === periodo)?.dias ?? 7
}

/** Un menú que se cierra al pulsar fuera o con Escape. */
export function useMenu() {
  const [abierto, setAbierto] = useState(false)
  const caja = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!abierto) return
    const fuera = (e: PointerEvent) => {
      if (!caja.current?.contains(e.target as Node)) setAbierto(false)
    }
    const alTeclear = (e: KeyboardEvent) => e.key === 'Escape' && setAbierto(false)
    document.addEventListener('pointerdown', fuera)
    document.addEventListener('keydown', alTeclear)
    return () => {
      document.removeEventListener('pointerdown', fuera)
      document.removeEventListener('keydown', alTeclear)
    }
  }, [abierto])

  return { abierto, setAbierto, caja }
}

/** El periodo, en el menú de vidrio de la maqueta. */
export function SelectorDePeriodo({ periodo, onCambio }: { periodo: Periodo; onCambio: (p: Periodo) => void }) {
  const { abierto, setAbierto, caja } = useMenu()

  return (
    <div ref={caja} className="lt-periodo">
      <button
        type="button"
        className="lt-boton"
        aria-haspopup="menu"
        aria-expanded={abierto}
        onClick={() => setAbierto((v) => !v)}
      >
        <CalendarDays size={15} aria-hidden />
        {PERIODOS.find((p) => p.id === periodo)?.rotulo}
        <ChevronDown size={13} aria-hidden />
      </button>
      {abierto && (
        <div className="lt-periodo-menu" role="menu" aria-label="Periodo">
          {PERIODOS.map((p) => (
            <button
              key={p.id}
              type="button"
              role="menuitemradio"
              aria-checked={p.id === periodo}
              onClick={() => {
                onCambio(p.id)
                setAbierto(false)
              }}
            >
              {p.rotulo}
              <span aria-hidden>{p.id === periodo ? '✓' : ''}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

// ── La cabecera y las vistas ───────────────────────────────────────────────

/** El título de la pantalla, lo que hay en ella y, a la derecha, su control (el periodo). */
export function CabeceraLite({
  titulo,
  descripcion,
  derecha,
}: {
  titulo: string
  descripcion: string
  derecha?: ReactNode
}) {
  return (
    <div className="lt-cabecera">
      <div>
        <h1>{titulo}</h1>
        <p>{descripcion}</p>
      </div>
      {derecha}
    </div>
  )
}

/** Las vistas de una pantalla, en píldoras, cuando no son rutas. */
export function Pildoras<T extends string>({
  opciones,
  valor,
  onCambio,
  etiqueta,
}: {
  opciones: ReadonlyArray<{ id: T; rotulo: string }>
  valor: T
  onCambio: (v: T) => void
  etiqueta: string
}) {
  return (
    <div className="lt-pestanas" role="group" aria-label={etiqueta}>
      {opciones.map((o) => (
        <button
          key={o.id}
          type="button"
          className="lt-pestana"
          aria-pressed={o.id === valor}
          onClick={() => onCambio(o.id)}
        >
          {o.rotulo}
        </button>
      ))}
    </div>
  )
}

// ── Las cifras ─────────────────────────────────────────────────────────────

/** El cambio contra el periodo anterior, en %. `undefined` si antes fue cero. */
export function cambio(ahora: number, antes: number): number | undefined {
  if (antes <= 0) return undefined
  return ((ahora - antes) / antes) * 100
}

export function textoDeCambio(pct: number): string {
  return `${pct >= 0 ? '↑' : '↓'} ${formatPct(Math.abs(pct))}`
}

/** La franja de cuatro cifras de la maqueta. */
export function Franja({ children }: { children: ReactNode }) {
  return <div className="lt-franja">{children}</div>
}

export function CifraDeFranja({
  rotulo,
  valor,
  destacado,
  pie,
  a,
  fallo,
  reintentar,
}: {
  rotulo: string
  /** `undefined` (o `null`) mientras llega. */
  valor: string | null | undefined
  /** Lo que va delante del pie, en azul: «3», «↑ 12 %». */
  destacado?: string
  pie?: string
  /** Adónde lleva el rótulo, si lleva a algún sitio. */
  a?: string
  fallo?: boolean
  reintentar?: () => void
}) {
  return (
    <div className="lt-franja-cifra">
      {a ? (
        <Link to={a} className="lt-cifra-rotulo">
          {rotulo} <span aria-hidden>↗</span>
        </Link>
      ) : (
        <span className="lt-cifra-rotulo">{rotulo}</span>
      )}
      {fallo ? (
        <button type="button" className="lt-reintentar" onClick={reintentar}>
          No se pudo leer · reintentar
        </button>
      ) : (
        <div className="lt-franja-valor">{valor ?? <span className="lt-cargando" />}</div>
      )}
      {(destacado || pie) && (
        <div className="lt-cifra-pie">
          {destacado && <b>{destacado}</b>}
          {pie}
        </div>
      )}
    </div>
  )
}

/** Las iniciales de un médico para su avatar, sin el «Dr./Dra.» delante. */
export function inicialesDeMedico(nombre: string): string {
  const limpio = nombre.replace(/^(Dra?\.|Lcd[ao]\.)\s+/i, '').trim()
  const partes = limpio.split(/\s+/).filter(Boolean)
  return ((partes[0]?.[0] ?? '') + (partes[1]?.[0] ?? '')).toUpperCase() || '·'
}

/** Las barritas de la maqueta: los clics de cada uno de los últimos siete días. */
export function Barritas({ serie }: { serie: number[] }) {
  const tope = Math.max(1, ...serie)
  return (
    <span className="lt-barritas" aria-hidden>
      {serie.map((n, i) => (
        <i key={i} style={{ height: `${Math.max(3, (n / tope) * 22)}px` }} />
      ))}
    </span>
  )
}

