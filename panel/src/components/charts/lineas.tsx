import type { ReactNode } from 'react'

import {
  TablaDelGrafico,
  anclajeEn,
  escalaConSigno,
  indicesEspaciados,
} from '@/components/charts/comun'
import type { ChartSeries, LinePoint } from '@/components/charts/comun'
import {
  indiceCercano,
  limpio,
  puntosSueltos,
  relleno,
  trazo,
  ultimoConDato,
  xDe,
} from '@/components/charts/geometria'
import { Globo, lecturaDelPunto, useSenalado } from '@/components/charts/lectura'
import type { FilaDelGlobo } from '@/components/charts/lectura'
import { ChartCard } from '@/components/charts/tarjeta'
import type { EntradaDeLeyenda } from '@/components/charts/tarjeta'
import { SERIE, tonoDeSerie } from '@/components/charts/tonos'

// ═══════════════════════════════════════════════════════════════════════════
// Series en el tiempo, en una tarjeta entera. Para la esquina de una cifra
// está `Sparkline` (charts/sparkline.tsx).
//
// Las reglas son las de `BarChart`: eje con marcas redondas, rejilla de un
// pelo, la tabla a un clic y colores que salen de charts/tonos. Lo que cambia
// es la lectura: una barra dice «cuánto ese día»; una línea dice «hacia dónde
// va», así que la cifra escrita es la del ÚLTIMO punto de cada serie, al
// final de su línea.
//
// Un `null` es un hueco: la línea se corta ahí. Un día sin dato no es un día
// a cero, y bajar la línea a la base para cruzarlo dibujaría un desplome que
// no pasó.
// ═══════════════════════════════════════════════════════════════════════════

export type LineChartProps = {
  title: string
  /** Lo que va a la derecha de la cabecera: un dato del periodo, un enlace. */
  aside?: ReactNode
  /** La línea de resumen bajo el título. */
  summary?: ReactNode
  series: Array<ChartSeries>
  /** Un valor por serie; `null` es un hueco y corta la línea. */
  points: Array<LinePoint>
  /**
   * El índice de la serie protagonista, que va en el tono del área. Por
   * defecto la primera. Con dos series la otra va en gris; con más, se
   * apagan según lo lejos que estén de ella.
   */
  principal?: number
  /** Un lavado del tono del área bajo la protagonista, hasta el cero. */
  area?: boolean
  /** Líneas en escalón: para acumulados, que suben el día en que entra algo. */
  escalon?: boolean
  /** La cifra completa: '€1.284,50'. Va en el globo y en la tabla. */
  format: (value: number) => string
  /** La cifra corta: '€1,3 k'. Va en el eje y al final de cada línea. */
  formatShort: (value: number) => string
  /** Cómo se llama el eje de abajo en la tabla: 'Día', 'Semana'. */
  ejeLabel: string
  /** Cómo se llama la columna de `note` en la tabla. */
  unidadLabel?: string
  /** El eje cuenta cosas y no dinero: marcas enteras. Ver `escalaBonita`. */
  enteros?: boolean
  /** Una meta o un umbral: línea horizontal discontinua. Entra en la escala. */
  reference?: { value: number; label: string }
  height?: number
  /** Si es texto, va al InfoDot de la cabecera; si es otra cosa, debajo. */
  footnote?: ReactNode
  empty?: string
}

/** Por debajo de esta distancia (px) dos cifras al final de sus líneas se pisan. */
const SEPARACION_ROTULOS = 16

/**
 * Una o varias series en el tiempo.
 *
 * Con el ratón o el dedo encima, una guía vertical marca el punto y el globo
 * lo lee entero, todas las series; con el teclado, ← y → lo recorren. Sin
 * tocar nada, cada línea lleva escrita su última cifra.
 */
export function LineChart({
  title,
  aside,
  summary,
  series,
  points,
  principal = 0,
  area = false,
  escalon = false,
  format,
  formatShort,
  ejeLabel,
  unidadLabel,
  enteros = false,
  reference,
  height = 180,
  footnote,
  empty = 'Todavía no hay datos en este periodo.',
}: LineChartProps) {
  const n = points.length
  const { punto, senalar, lienzo } = useSenalado(n, indiceCercano)
  const prota = Math.min(Math.max(Math.trunc(principal), 0), Math.max(series.length - 1, 0))
  const colorDe = (si: number) => tonoDeSerie(si, series.length, prota)

  // Un valor por serie, siempre; lo que falte o no sea número es un hueco.
  const datos = points.map((p) => ({ ...p, values: series.map((_, si) => limpio(p.values[si])) }))
  const conDato = datos.flatMap((p) => p.values).filter((v): v is number => v !== null)
  const ref = reference && Number.isFinite(reference.value) ? reference : undefined

  const leyenda: Array<EntradaDeLeyenda> = [
    ...(series.length > 1
      ? series.map((s, si) => ({ rotulo: s.label, color: colorDe(si), forma: 'linea' as const }))
      : []),
    ...(ref ? [{ rotulo: ref.label, color: SERIE.contexto, forma: 'discontinua' as const }] : []),
  ]
  const info = typeof footnote === 'string' ? footnote : undefined
  const pie = typeof footnote === 'string' || !footnote ? null : (
    <div className="mt-3 type-panel-caption text-panel-muted">{footnote}</div>
  )
  const marco = { titulo: title, info, resumen: summary, controles: aside, leyenda }

  if (n === 0 || conDato.length === 0) {
    return (
      <ChartCard {...marco}>
        <p className="type-panel-body text-panel-muted">{empty}</p>
        {pie}
      </ChartCard>
    )
  }

  const extremos = [...conDato, ref?.value ?? 0, 0]
  let escala = escalaConSigno(Math.min(...extremos), Math.max(...extremos), enteros)
  // Todo a cero es un dato —una mora del 0 % todo el mes— y se pinta: la
  // línea va por la base de una escala mínima en vez de decir «no hay datos».
  if (escala.tope === escala.suelo) escala = escalaConSigno(0, 1, enteros)
  const { suelo, tope, marcas } = escala
  const y = (v: number) => ((v - suelo) / (tope - suelo)) * 100

  const serieDe = (si: number) => datos.map((p) => p.values[si] ?? null)
  // Las de contexto primero y la protagonista la última: encima de todas.
  const orden = [...series.keys()].filter((si) => si !== prota).concat(prota)

  // La última cifra de cada serie, al final de su línea. Con más de dos
  // series solo la de la protagonista: cuatro cifras apiladas no se leen.
  const rotulos = orden
    .filter((si) => si === prota || series.length === 2)
    .flatMap((si) => {
      const i = ultimoConDato(serieDe(si))
      const v = i < 0 ? null : (serieDe(si)[i] ?? null)
      return v === null ? [] : [{ si, x: xDe(i, n), y: y(v), v }]
    })
  const suyo = rotulos.find((r) => r.si === prota)
  const finales = rotulos.filter(
    (r) =>
      r.si === prota ||
      !suyo ||
      Math.abs(r.x - suyo.x) > 20 ||
      (Math.abs(r.y - suyo.y) / 100) * height >= SEPARACION_ROTULOS,
  )

  const activo = punto === null ? null : datos[punto]
  const filas: Array<FilaDelGlobo> = activo
    ? series.map((s, si) => {
        const v = activo.values[si] ?? null
        return { key: s.key, rotulo: s.label, valor: v === null ? '—' : format(v), color: colorDe(si) }
      })
    : []

  return (
    <ChartCard
      {...marco}
      tabla={
        <TablaDelGrafico
          series={series}
          points={datos}
          format={format}
          ejeLabel={ejeLabel}
          unidadLabel={unidadLabel}
        />
      }
    >
      <div className="flex gap-2 pt-2">
        <div className="relative w-11 shrink-0" style={{ height }} aria-hidden>
          {marcas.map((m) => (
            <span
              key={m}
              className="absolute right-0 translate-y-1/2 type-panel-caption tabular-nums text-panel-muted"
              style={{ bottom: `${y(m)}%` }}
            >
              {formatShort(m)}
            </span>
          ))}
        </div>

        <div
          role="img"
          aria-label={`${title}. ${n} ${n === 1 ? 'punto' : 'puntos'}. Las flechas los recorren; los números están en la tabla.`}
          {...lienzo}
          // Al llegar con Tab, el globo sale ya, en el último punto con dato:
          // desde ahí las flechas recorren el resto.
          onFocus={(e) => {
            if (punto !== null || !e.currentTarget.matches(':focus-visible')) return
            let ultimo = n - 1
            while (ultimo > 0 && datos[ultimo].values.every((v) => v === null)) ultimo--
            senalar(ultimo)
          }}
          className="relative min-w-0 flex-1 touch-pan-y rounded-extra-small"
          style={{ height }}
        >
          {/* La rejilla; la del cero, más marcada, que con negativos no es la base. */}
          {marcas.map((m) => (
            <span
              key={m}
              aria-hidden
              className={`absolute inset-x-0 -mb-px border-t ${
                m === 0 ? 'border-panel-hairline-strong' : 'border-panel-hairline'
              }`}
              style={{ bottom: `${y(m)}%` }}
            />
          ))}

          {punto !== null && (
            <span
              aria-hidden
              className="absolute inset-y-0 w-px -translate-x-1/2 bg-on-surface/20"
              style={{ left: `${xDe(punto, n)}%` }}
            />
          )}

          {/* `non-scaling-stroke`: el lienzo se estira a lo ancho y el trazo
              tiene que medir lo mismo en una tablet que en un monitor. */}
          <svg
            viewBox="0 0 100 100"
            preserveAspectRatio="none"
            aria-hidden
            className="absolute inset-0 size-full overflow-visible"
          >
            {area && (
              <path
                d={relleno(serieDe(prota), y, y(0), escalon)}
                style={{ fill: SERIE.relleno }}
              />
            )}
            {orden.map((si) => (
              <path
                key={series[si].key}
                d={trazo(serieDe(si), y, escalon)}
                fill="none"
                strokeWidth={si === prota || series.length === 2 ? 2 : 1.5}
                strokeLinejoin="round"
                strokeLinecap="round"
                vectorEffect="non-scaling-stroke"
                style={{ stroke: colorDe(si) }}
              />
            ))}
          </svg>

          {ref && (
            <span
              aria-hidden
              // A rayas, y es lo único a rayas: no es dato, es el listón.
              className="absolute inset-x-0 z-10 -mb-px border-t border-dashed"
              style={{ bottom: `${y(ref.value)}%`, borderColor: SERIE.contexto }}
            />
          )}

          {orden.map((si) => {
            const valores = serieDe(si)
            const ultimo = ultimoConDato(valores)
            const indices = new Set([...puntosSueltos(valores), ultimo, ...(punto === null ? [] : [punto])])
            return [...indices].map((i) => {
              const v = valores[i] ?? null
              if (v === null) return null
              return (
                <span
                  key={`${series[si].key}-${i}`}
                  aria-hidden
                  className={`absolute z-10 -translate-x-1/2 translate-y-1/2 rounded-full ring-2 ring-panel-card ${
                    i === punto ? 'size-2.5' : 'size-2'
                  }`}
                  style={{ left: `${xDe(i, n)}%`, bottom: `${y(v)}%`, backgroundColor: colorDe(si) }}
                />
              )
            })
          })}

          {/* LA ÚLTIMA CIFRA, al final de su línea: en el margen de la derecha
              si la línea llega al final, y junto a su punto si se corta antes. */}
          {finales.map((r) => (
            <span
              key={series[r.si].key}
              aria-hidden
              className={`absolute z-10 translate-y-1/2 whitespace-nowrap type-panel-caption font-semibold tabular-nums ${
                r.si === prota ? 'text-on-surface' : 'text-on-surface-variant'
              }`}
              style={{ left: `calc(${r.x}% + 10px)`, bottom: `${r.y}%` }}
            >
              {formatShort(r.v)}
            </span>
          ))}

          {activo && punto !== null && (
            <Globo x={xDe(punto, n)} titulo={activo.label} filas={filas} nota={activo.note} />
          )}
        </div>

        {/* El margen de las cifras finales. */}
        <div className="w-14 shrink-0" />
      </div>

      <div className="flex gap-2">
        <div className="w-11 shrink-0" />
        <div className="relative mt-2 h-4 min-w-0 flex-1" aria-hidden>
          {indicesEspaciados(n, 7).map((i) => {
            const a = anclajeEn(xDe(i, n))
            return (
              <span
                key={datos[i].key}
                className={`absolute whitespace-nowrap type-panel-caption tabular-nums ${
                  i === punto ? 'text-on-surface' : 'text-panel-muted'
                } ${a.clase}`}
                style={a.style}
              >
                {datos[i].label}
              </span>
            )
          })}
        </div>
        <div className="w-14 shrink-0" />
      </div>

      {pie}

      <p aria-live="polite" className="sr-only">
        {activo ? lecturaDelPunto(activo.label, filas, activo.note) : ''}
      </p>
    </ChartCard>
  )
}
