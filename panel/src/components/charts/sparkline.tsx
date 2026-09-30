import { useState } from 'react'
import type { FocusEvent } from 'react'

import { formatNumero } from '@/components/ui'
import {
  indiceCercano,
  limpio,
  puntosSueltos,
  trazo,
  ultimoConDato,
  xDe,
} from '@/components/charts/geometria'
import { GloboFlotante, lecturaDelPunto, useSenalado } from '@/components/charts/lectura'
import type { ContenidoDelGlobo } from '@/components/charts/lectura'
import { SERIE, colorDeTono } from '@/components/charts/tonos'

export type SparklineProps = {
  /** En orden, del más viejo al de hoy. `null` es un hueco: corta la línea. */
  values: Array<number | null>
  /**
   * Lo que dice la línea, para quien no la ve: «Mora de las últimas ocho
   * semanas, del 4 % al 6 %». Es lo único que lee un lector de pantalla.
   */
  label: string
  /** El nombre de cada punto, para el globo: «14–20 sep». Sin él, «3 de 8». */
  etiquetas?: ReadonlyArray<string>
  /** Cómo se escribe cada valor en el globo. Sin él, un número con un decimal como mucho. */
  formato?: (n: number) => string
  /** El nombre corto de la serie en el globo, junto a la cifra: «Cura». */
  serie?: string
  /** Alto en px. El ancho es el de la caja. */
  height?: number
  /** Una meta o un umbral, discontinuo. Entra en la escala. */
  reference?: number
  /**
   * El color de la línea. Por defecto el tono del área; el de estado solo
   * cuando la serie entera ES un estado (la cura de un tramo). `primary` se
   * pinta como `area`: el lima es de la acción principal, no de un dato.
   */
  tone?: 'area' | 'neutral' | 'primary' | 'success' | 'warning' | 'error'
  className?: string
}

function colorDeLinea(tone: NonNullable<SparklineProps['tone']>): string {
  if (tone === 'primary' || tone === 'area') return SERIE.principal
  if (tone === 'neutral') return SERIE.contexto
  return colorDeTono(tone)
}

/** Un número sin unidad: entero si lo es, y con un decimal si no. */
function numero(v: number): string {
  return formatNumero(v, Number.isInteger(v) ? 0 : 1)
}

/**
 * La forma de una serie, sin nada más: para la ranura `visual` de un `Stat`
 * o una celda. Sin eje ni tabla; si la cifra exacta importa, va en un
 * `LineChart`. Cada punto se lee en su globo al pasar el ratón, o con las
 * flechas después de llegar con Tab.
 *
 * La escala arranca en cero y no en el mínimo de la serie. Un sparkline de
 * 3,9 a 4,3 escalado al mínimo dibuja un salto de pared a pared por cuatro
 * décimas; desde cero se ve como lo que es, casi plano. Con negativos, la
 * escala baja hasta el más bajo.
 */
export function Sparkline({
  values,
  label,
  etiquetas,
  formato = numero,
  serie = '',
  height = 32,
  reference,
  tone = 'area',
  className = '',
}: SparklineProps) {
  const valores = values.map(limpio)
  const conDato = valores.filter((v): v is number => v !== null)
  const ref = reference !== undefined && Number.isFinite(reference) ? reference : undefined
  const n = valores.length
  const { punto, senalar, lienzo } = useSenalado(n, indiceCercano)
  const [caja, setCaja] = useState<HTMLDivElement | null>(null)

  const bajo = Math.min(0, ...conDato, ref ?? 0)
  const alto = Math.max(0, ...conDato, ref ?? 0)
  // Todo a cero: una raya por la base, que es lo que es.
  const rango = alto - bajo || 1
  const y = (v: number) => ((v - bajo) / rango) * 100

  const color = colorDeLinea(tone)
  const ultimo = ultimoConDato(valores)
  // El último siempre lleva su punto: es «hoy», y es lo que se lee primero.
  const puntos = [...new Set([...puntosSueltos(valores), ...(ultimo >= 0 ? [ultimo] : [])])]

  const globo = (i: number): ContenidoDelGlobo => {
    const v = valores[i] ?? null
    return {
      titulo: etiquetas?.[i] ?? `${i + 1} de ${n}`,
      filas: [
        {
          key: 'valor',
          rotulo: serie,
          valor: v === null ? 'Sin dato' : formato(v),
          color: v === null ? SERIE.tenue : color,
          forma: 'linea',
        },
      ],
    }
  }
  const activo = punto === null ? null : globo(punto)
  const valorActivo = punto === null ? null : (valores[punto] ?? null)

  function alEnfocar(e: FocusEvent<HTMLDivElement>) {
    if (punto === null && ultimo >= 0 && e.currentTarget.matches(':focus-visible')) senalar(ultimo)
  }

  return (
    <>
      <div
        ref={setCaja}
        role="img"
        aria-label={label}
        {...lienzo}
        onFocus={alEnfocar}
        className={`relative z-10 w-full touch-pan-y rounded-extra-small ${className}`}
        style={{ height }}
      >
        {conDato.length > 0 && (
          <>
            <svg
              viewBox="0 0 100 100"
              preserveAspectRatio="none"
              aria-hidden
              className="absolute inset-0 size-full overflow-visible"
            >
              <path
                d={trazo(valores, y)}
                fill="none"
                strokeWidth={1.5}
                strokeLinejoin="round"
                strokeLinecap="round"
                vectorEffect="non-scaling-stroke"
                style={{ stroke: color }}
              />
            </svg>

            {ref !== undefined && (
              <span
                aria-hidden
                className="absolute inset-x-0 -mb-px border-t border-dashed"
                style={{ bottom: `${y(ref)}%`, borderColor: SERIE.contexto }}
              />
            )}

            {puntos.map((i) => {
              const v = valores[i] ?? null
              if (v === null) return null
              return (
                <span
                  key={i}
                  aria-hidden
                  className={`absolute -translate-x-1/2 translate-y-1/2 rounded-full ${
                    i === ultimo ? 'size-1.5' : 'size-1'
                  }`}
                  style={{ left: `${xDe(i, n)}%`, bottom: `${y(v)}%`, backgroundColor: color }}
                />
              )
            })}

            {/* El punto señalado, más grande y con aro: se ve cuál lee el globo. */}
            {punto !== null && valorActivo !== null && (
              <span
                aria-hidden
                className="absolute size-2 -translate-x-1/2 translate-y-1/2 rounded-full ring-2 ring-panel-card"
                style={{ left: `${xDe(punto, n)}%`, bottom: `${y(valorActivo)}%`, backgroundColor: color }}
              />
            )}
          </>
        )}
      </div>

      {activo && punto !== null && <GloboFlotante ancla={caja} x={xDe(punto, n)} {...activo} />}
      <span aria-live="polite" className="sr-only">
        {activo ? lecturaDelPunto(activo.titulo, activo.filas) : ''}
      </span>
    </>
  )
}
