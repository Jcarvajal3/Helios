import { Link } from '@tanstack/react-router'
import { ArrowRight, ArrowUpRight } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'

import type { CSSProperties, ElementType, ReactNode } from 'react'

/**
 * Las piezas pequeñas de la portada: botones, rótulos, la aparición al
 * desplazarse y las cifras que cuentan solas.
 */

// ── Ver si algo está en pantalla ───────────────────────────────────────────

/**
 * `true` desde que el elemento entra en pantalla (y, con `continuo`, solo
 * mientras se vea). El SSR lo pinta como visto, para que sin JavaScript
 * todo se lea.
 */
export function useEnVista<T extends Element>({
  umbral = 0.2,
  continuo = false,
  margen = '0px 0px -8% 0px',
}: { umbral?: number; continuo?: boolean; margen?: string } = {}) {
  const ref = useRef<T>(null)
  const [visto, setVisto] = useState(false)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    const io = new IntersectionObserver(
      ([e]) => {
        if (e.isIntersecting) {
          setVisto(true)
          if (!continuo) io.disconnect()
        } else if (continuo) {
          setVisto(false)
        }
      },
      { threshold: umbral, rootMargin: margen },
    )
    io.observe(el)
    return () => io.disconnect()
  }, [umbral, continuo, margen])

  return [ref, visto] as const
}

/** `true` con «reducir movimiento». En el servidor, `false`. */
export function useQuieto() {
  const [quieto, setQuieto] = useState(false)
  useEffect(() => {
    const mq = window.matchMedia('(prefers-reduced-motion: reduce)')
    setQuieto(mq.matches)
    const alCambiar = () => setQuieto(mq.matches)
    mq.addEventListener('change', alCambiar)
    return () => mq.removeEventListener('change', alCambiar)
  }, [])
  return quieto
}

/**
 * Un contador que avanza de 0 a `pasos - 1` cada `ms` mientras `activo`, y
 * vuelve a empezar. Mueve las miniaturas de las tarjetas.
 */
export function useCiclo(
  pasos: number,
  ms: number | ((paso: number) => number),
  activo: boolean,
) {
  const [paso, setPaso] = useState(0)
  useEffect(() => {
    if (!activo) return
    const espera = typeof ms === 'function' ? ms(paso) : ms
    const t = window.setTimeout(() => setPaso((p) => (p + 1) % pasos), espera)
    return () => window.clearTimeout(t)
  }, [activo, paso, pasos, ms])
  return paso
}

// ── Aparecer al desplazarse ────────────────────────────────────────────────

/**
 * Sube y se enfoca la primera vez que entra en pantalla. El estado lo lleva
 * `data-revelar`: `listo` en el servidor (se ve), `espera` mientras está
 * abajo y `visto` cuando entra.
 */
export function Revelar({
  children,
  retraso = 0,
  como: Etiqueta = 'div',
  className = '',
  style,
}: {
  children: ReactNode
  retraso?: number
  como?: ElementType
  className?: string
  style?: CSSProperties
}) {
  const ref = useRef<HTMLElement>(null)
  const [estado, setEstado] = useState<'listo' | 'espera' | 'visto'>('listo')

  useEffect(() => {
    const el = ref.current
    if (!el) return
    // Lo que ya está en pantalla al hidratar no se esconde: no parpadea.
    if (el.getBoundingClientRect().top < window.innerHeight * 0.92) return
    setEstado('espera')
    const io = new IntersectionObserver(
      ([e]) => {
        if (e.isIntersecting) {
          setEstado('visto')
          io.disconnect()
        }
      },
      { threshold: 0.12, rootMargin: '0px 0px -6% 0px' },
    )
    io.observe(el)
    return () => io.disconnect()
  }, [])

  return (
    <Etiqueta
      ref={ref}
      data-revelar={estado}
      className={className}
      style={{ ...style, '--retraso': `${retraso}ms` } as CSSProperties}
    >
      {children}
    </Etiqueta>
  )
}

// ── Cifras que cuentan ─────────────────────────────────────────────────────

/**
 * Un número que cuenta desde 0 cuando aparece. `formato` lo escribe (con su
 * símbolo); el servidor pinta el valor final.
 */
export function Cifra({
  valor,
  formato = (n) => String(Math.round(n)),
  duracion = 1600,
  className = '',
}: {
  valor: number
  formato?: (n: number) => string
  duracion?: number
  className?: string
}) {
  const [ref, visto] = useEnVista<HTMLSpanElement>({ umbral: 0.6 })
  const [actual, setActual] = useState(valor)
  const quieto = useQuieto()
  const empezo = useRef(false)

  useEffect(() => {
    const el = ref.current
    if (!el || quieto) return
    // Solo cuenta lo que estaba fuera de pantalla al cargar.
    if (el.getBoundingClientRect().top > window.innerHeight * 0.9) setActual(0)
    else empezo.current = true
  }, [ref, quieto])

  useEffect(() => {
    if (!visto || quieto || empezo.current) return
    empezo.current = true
    let raf = 0
    const inicio = performance.now()
    const paso = (ahora: number) => {
      const t = Math.min((ahora - inicio) / duracion, 1)
      const e = t === 1 ? 1 : 1 - Math.pow(2, -10 * t)
      setActual(valor * e)
      if (t < 1) raf = requestAnimationFrame(paso)
    }
    raf = requestAnimationFrame(paso)
    return () => cancelAnimationFrame(raf)
  }, [visto, quieto, valor, duracion])

  return (
    <span ref={ref} className={`tabular-nums ${className}`}>
      {formato(actual)}
    </span>
  )
}

// ── Textos ─────────────────────────────────────────────────────────────────

/** El rótulo de una sección: un punto que late y el texto en monoespaciada. */
export function Rotulo({
  children,
  tono = 'claro',
  className = '',
}: {
  children: ReactNode
  tono?: 'claro' | 'oscuro'
  className?: string
}) {
  return (
    <p
      className={`portada-etiqueta inline-flex items-center gap-2.5 ${
        tono === 'claro' ? 'text-portada-azul' : 'text-portada-cielo-2'
      } ${className}`}
    >
      <span className="portada-latido relative inline-block size-1.5 rounded-full bg-current" />
      {children}
    </p>
  )
}

// ── Botones ────────────────────────────────────────────────────────────────

type Tono = 'tinta' | 'contorno' | 'claro' | 'vidrio'

const TONOS: Record<Tono, string> = {
  tinta:
    'bg-portada-tinta text-white hover:bg-portada-marino shadow-[0_10px_30px_-12px_rgba(0,39,112,0.55)]',
  contorno:
    'border border-portada-linea bg-white/70 text-portada-tinta backdrop-blur hover:border-portada-tinta/25 hover:bg-white',
  claro: 'bg-white text-portada-tinta hover:bg-portada-cielo-3',
  vidrio:
    'border border-white/20 bg-white/5 text-white backdrop-blur hover:bg-white/12',
}

export function Boton({
  children,
  to,
  href,
  externo = false,
  tono = 'tinta',
  flecha = 'derecha',
  className = '',
}: {
  children: ReactNode
  to?: string
  href?: string
  externo?: boolean
  tono?: Tono
  flecha?: 'derecha' | 'fuera' | 'ninguna'
  className?: string
}) {
  const forma = `portada-boton group inline-flex h-12 items-center justify-center gap-2 rounded-full pl-6 ${
    flecha === 'ninguna' ? 'pr-6' : 'pr-2'
  } text-[0.95rem] font-medium tracking-[-0.01em] transition-[background-color,border-color,transform,box-shadow] duration-300 active:scale-[0.98] ${TONOS[tono]} ${className}`

  const Icono = flecha === 'fuera' ? ArrowUpRight : ArrowRight
  const contenido = (
    <>
      <span>{children}</span>
      {flecha === 'ninguna' ? null : (
        <span
          aria-hidden
          className={`ml-1 grid size-8 place-items-center overflow-hidden rounded-full ${
            tono === 'tinta' || tono === 'vidrio'
              ? 'bg-white/12'
              : 'bg-portada-tinta text-white'
          }`}
        >
          <span className="portada-boton-flecha relative block size-4">
            <Icono className="absolute inset-0 size-4" strokeWidth={2} />
            <Icono className="absolute inset-0 size-4" strokeWidth={2} />
          </span>
        </span>
      )}
    </>
  )

  if (to) {
    return (
      <Link to={to} className={forma}>
        {contenido}
      </Link>
    )
  }
  return (
    <a
      href={href}
      className={forma}
      {...(externo ? { target: '_blank', rel: 'noopener noreferrer' } : {})}
    >
      {contenido}
    </a>
  )
}

/** «Quiero afiliarme»: al formulario de solicitud (`/afiliacion`). */
export function BotonAfiliarme({
  tono = 'tinta',
  className = '',
}: {
  tono?: Tono
  className?: string
}) {
  return (
    <Boton to="/afiliacion" tono={tono} className={className}>
      Quiero afiliarme
    </Boton>
  )
}

/** El ancho de la portada y sus márgenes. */
export function Lienzo({
  children,
  className = '',
}: {
  children: ReactNode
  className?: string
}) {
  return (
    <div
      className={`mx-auto w-full max-w-[var(--portada-ancho)] px-5 sm:px-8 ${className}`}
    >
      {children}
    </div>
  )
}
