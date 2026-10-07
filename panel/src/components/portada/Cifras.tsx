import { useEffect, useRef } from 'react'

import type { CSSProperties } from 'react'
import { LIMITE } from './datos'
import { Cifra, Lienzo, Revelar, Rotulo } from './piezas'

/**
 * EN CIFRAS y EL MANIFIESTO — lo que sigue a la primera pantalla.
 *
 * Cuatro números grandes que cuentan al aparecer, y una frase que se va
 * encendiendo palabra a palabra conforme se baja.
 */

const CIFRAS = [
  {
    valor: 0,
    formato: (n: number) => `$${Math.round(n)}`,
    pie: 'pagas hoy, en la consulta',
  },
  {
    valor: 2,
    formato: (n: number) => String(Math.max(1, Math.round(n))),
    pie: 'cuotas, a los 7 y a los 14 días',
  },
  {
    valor: 100,
    formato: (n: number) => `${Math.round(n)}%`,
    pie: 'de la consulta para el médico, a los 8 y a los 15 días',
  },
  {
    valor: LIMITE,
    formato: (n: number) => `$${Math.round(n)}`,
    pie: 'de límite inicial para el paciente',
  },
]

export function Cifras() {
  return (
    <section id="cifras" className="relative bg-white">
      <Lienzo className="py-20 sm:py-24">
        <div className="grid grid-cols-2 gap-x-6 gap-y-12 lg:grid-cols-4">
          {CIFRAS.map((c, i) => (
            <Revelar
              key={c.pie}
              retraso={i * 90}
              className="border-t border-portada-linea pt-6"
            >
              <p className="portada-etiqueta text-portada-tinta-3">0{i + 1}</p>
              <p className="portada-cifra mt-5 text-portada-tinta">
                {c.valor === 0 ? (
                  c.formato(0)
                ) : (
                  <Cifra valor={c.valor} formato={c.formato} />
                )}
              </p>
              <p className="mt-3 max-w-[24ch] text-[0.95rem] leading-snug text-portada-tinta-2">
                {c.pie}
              </p>
            </Revelar>
          ))}
        </div>
      </Lienzo>
    </section>
  )
}

/** Las palabras, con `*` alrededor de las que van en cursiva. */
const FRASE =
  'Atenderse no debería esperar a fin de mes. Con Helios, el paciente paga su consulta en *dos cuotas* y el médico la cobra *completa.*'

export function Manifiesto() {
  const ref = useRef<HTMLParagraphElement>(null)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      el.style.setProperty('--p', '1')
      return
    }
    let raf = 0
    const medir = () => {
      raf = 0
      const r = el.getBoundingClientRect()
      const vh = window.innerHeight
      const p = (vh * 0.82 - r.top) / (r.height + vh * 0.3)
      el.style.setProperty('--p', String(Math.min(Math.max(p, 0), 1)))
    }
    const pedir = () => {
      if (!raf) raf = requestAnimationFrame(medir)
    }
    medir()
    window.addEventListener('scroll', pedir, { passive: true })
    window.addEventListener('resize', pedir)
    return () => {
      cancelAnimationFrame(raf)
      window.removeEventListener('scroll', pedir)
      window.removeEventListener('resize', pedir)
    }
  }, [])

  const palabras: Array<{ texto: string; cursiva: boolean }> = []
  for (const trozo of FRASE.split(/(\*[^*]+\*)/)) {
    const cursiva = trozo.startsWith('*')
    for (const p of trozo.replace(/\*/g, '').split(' ').filter(Boolean)) {
      palabras.push({ texto: p, cursiva })
    }
  }

  return (
    <section className="relative bg-white">
      <Lienzo className="pb-28 pt-8 sm:pb-36">
        <Rotulo>Por qué Helios</Rotulo>
        <p
          ref={ref}
          className="portada-manifiesto mt-8 max-w-[22ch] text-portada-tinta"
          style={{ '--n': palabras.length, '--p': 1 } as CSSProperties}
        >
          {palabras.map((p, i) => (
            <span
              key={i}
              className={
                p.cursiva ? 'portada-serif text-portada-azul' : undefined
              }
              style={{ '--i': i } as CSSProperties}
            >
              {p.texto}{' '}
            </span>
          ))}
        </p>
      </Lienzo>
    </section>
  )
}
