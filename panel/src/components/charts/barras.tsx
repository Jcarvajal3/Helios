import type { ReactNode } from 'react'

import { TablaDelGrafico, anclaje, escalaBonita, etiquetasDelEje } from '@/components/charts/comun'
import type { ChartPoint, ChartSeries } from '@/components/charts/comun'
import { columnaBajo } from '@/components/charts/geometria'
import { Globo, lecturaDelPunto, useSenalado } from '@/components/charts/lectura'
import type { FilaDelGlobo } from '@/components/charts/lectura'
import { ChartCard } from '@/components/charts/tarjeta'
import type { EntradaDeLeyenda } from '@/components/charts/tarjeta'
import { SERIE } from '@/components/charts/tonos'

// ═══════════════════════════════════════════════════════════════════════════
// EL GRÁFICO DE BARRAS.
//
// Se lee sin tocar nada: eje con marcas redondas, rejilla de un pelo, la
// cifra de la barra más alta escrita encima y la tabla entera a un clic en la
// cabecera. El globo del ratón ayuda; no es la única manera de leer.
//
// - Un día sin ventas deja una marca en la base: cero es un dato, y sin ella
//   no se distingue de un día que no existe.
// - Con dos series, la protagonista va DENTRO del listón gris del contexto:
//   lo que asoma por encima es, literalmente, lo que falta.
// - Barras de 24 px como mucho y 2 px de aire entre vecinas: con los datos
//   del piloto (treinta días casi todos a cero) una barra gruesa se leía
//   como un gráfico roto.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * El suelo de una barra que no es cero.
 *
 * Una venta de €2 en una escala de €600 mide medio píxel: se pinta igual que
 * el vacío y el día parece muerto cuando no lo está. Un 1,5 % del alto son
 * tres píxeles, suficientes para verse y demasiado poco para mentir.
 */
const SUELO_VISIBLE = 1.5

/** El ancho de una barra, y el de la protagonista cuando va dentro del listón. */
const ANCHO = 'min(24px, calc(100% - 2px))'
const ANCHO_DENTRO = 'min(14px, calc(58% - 1px))'

export type BarChartProps = {
  title: string
  /** Lo que va a la derecha de la cabecera: un dato del periodo, un enlace. */
  aside?: ReactNode
  /** La línea de resumen bajo el título: el total, el mejor día, el porcentaje. */
  summary?: ReactNode
  /** Una o dos. Con dos, la primera es el listón de contexto y la última la
   *  protagonista, en el tono del área. */
  series: Array<ChartSeries>
  points: Array<ChartPoint>
  /** El importe completo: '€1.284,50'. Va en el globo y en la tabla. */
  format: (value: number) => string
  /** El importe corto: '€1,3 k'. Va en el eje y encima de la barra. */
  formatShort: (value: number) => string
  /** Cómo se llama el eje de abajo en la tabla: 'Día', 'Hora'. */
  ejeLabel: string
  /** Cómo se llama la columna de `note` en la tabla: 'Órdenes', 'Cuotas'. */
  unidadLabel?: string
  /** El eje cuenta cosas —personas, consumos— y no dinero: marcas enteras. */
  enteros?: boolean
  /** Una línea horizontal de referencia —la media, una meta—. Entra en la
   *  escala, así que nunca se sale por arriba. */
  reference?: { value: number; label: string }
  height?: number
  /** Si es texto, va al InfoDot de la cabecera; si es otra cosa, debajo. */
  footnote?: ReactNode
  empty?: string
}

export function BarChart({
  title,
  aside,
  summary,
  series,
  points,
  format,
  formatShort,
  ejeLabel,
  unidadLabel,
  enteros = false,
  reference,
  height = 180,
  footnote,
  empty = 'Todavía no hay movimiento en este periodo.',
}: BarChartProps) {
  const n = points.length
  const { punto, senalar, lienzo } = useSenalado(n, columnaBajo)

  // La última serie es la protagonista: con una, es la única; con dos, es la
  // que va dentro del listón gris.
  const principal = series.length - 1
  const conListon = series.length > 1

  // Un valor por serie, siempre. Lo que falte —o un `null` colado desde la
  // base— es un cero y no un NaN, que en un `height: NaN%` deja la barra
  // invisible y el gráfico mintiendo en silencio.
  const datos = points.map((p) => ({
    ...p,
    values: series.map((_, si) => Number(p.values[si]) || 0),
  }))

  const ref = reference && reference.value > 0 ? reference : undefined
  const { tope, marcas } = escalaBonita(
    Math.max(...datos.flatMap((p) => p.values), ref?.value ?? 0, 0),
    enteros,
  )

  const colorDe = (si: number) => (si === principal ? SERIE.principal : SERIE.tenue)
  const leyenda: Array<EntradaDeLeyenda> = [
    ...(conListon ? series.map((s, si) => ({ rotulo: s.label, color: colorDe(si) })) : []),
    ...(ref ? [{ rotulo: ref.label, color: SERIE.contexto, forma: 'discontinua' as const }] : []),
  ]
  const info = typeof footnote === 'string' ? footnote : undefined
  const pie = typeof footnote === 'string' || !footnote ? null : (
    <div className="mt-3 type-panel-caption text-panel-muted">{footnote}</div>
  )

  const marco = { titulo: title, info, resumen: summary, controles: aside, leyenda }

  if (n === 0 || tope === 0) {
    return (
      <ChartCard {...marco}>
        <p className="type-panel-body text-panel-muted">{empty}</p>
        {pie}
      </ChartCard>
    )
  }

  // La barra más alta de la protagonista lleva su cifra escrita siempre: es
  // el dato que se busca —cuánto fue el mejor día— y el que peor se estima.
  let cima = 0
  datos.forEach((p, i) => {
    if (p.values[principal] > datos[cima].values[principal]) cima = i
  })
  const valorCima = datos[cima].values[principal]

  const activo = punto === null ? null : datos[punto]
  const filas: Array<FilaDelGlobo> = activo
    ? series.map((s, si) => ({
        key: s.key,
        rotulo: s.label,
        valor: format(activo.values[si]),
        color: colorDe(si),
        forma: 'punto',
      }))
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
      {/* El aire de arriba es para la cifra de la barra más alta: sin él, una
          barra que llega al tope de la escala se comería su propia cifra. */}
      <div className="flex gap-2 pt-6">
        <div className="relative w-11 shrink-0" style={{ height }} aria-hidden>
          {marcas.map((m) => (
            <span
              key={m}
              className="absolute right-0 translate-y-1/2 type-panel-caption tabular-nums text-panel-muted"
              style={{ bottom: `${(m / tope) * 100}%` }}
            >
              {formatShort(m)}
            </span>
          ))}
        </div>

        <div
          role="img"
          aria-label={`${title}. ${n} ${n === 1 ? 'barra' : 'barras'}. Las flechas las recorren; los números están en la tabla.`}
          {...lienzo}
          // Al llegar con Tab, el globo sale ya, en la última barra: desde
          // ahí las flechas recorren el resto.
          onFocus={(e) => {
            if (punto === null && e.currentTarget.matches(':focus-visible')) senalar(n - 1)
          }}
          // `pan-y`: el dedo recorre el gráfico de lado sin que la página
          // deje de desplazarse hacia abajo.
          className="relative min-w-0 flex-1 touch-pan-y rounded-extra-small"
          style={{ height }}
        >
          {/* La rejilla: un pelo, continua y de un solo tono. A rayas se
              leería como un umbral, y aquí no significa nada. */}
          {marcas.map((m) => (
            <span
              key={m}
              aria-hidden
              className={`absolute inset-x-0 -mb-px border-t ${
                m === 0 ? 'border-panel-hairline-strong' : 'border-panel-hairline'
              }`}
              style={{ bottom: `${(m / tope) * 100}%` }}
            />
          ))}

          <div className="absolute inset-0 flex items-end" aria-hidden>
            {datos.map((p, i) => (
              <div
                key={p.key}
                className="relative h-full min-w-0 flex-1 transition-opacity duration-[var(--transition-fast)]"
                // Al señalar una, las demás se apagan un poco: así se ve
                // qué barra lee el globo.
                style={{ opacity: punto === null || punto === i ? 1 : 0.5 }}
              >
                {conListon && (
                  <Barra valor={p.values[0]} tope={tope} ancho={ANCHO} color={SERIE.tenue} />
                )}
                <Barra
                  valor={p.values[principal]}
                  tope={tope}
                  ancho={conListon ? ANCHO_DENTRO : ANCHO}
                  color={SERIE.principal}
                />
              </div>
            ))}
          </div>

          {ref && (
            <span
              aria-hidden
              // A rayas, y es lo único a rayas: no es dato, es el listón
              // contra el que se miden los datos. Por encima de las barras,
              // que detrás la más alta la parte justo donde hay que comparar.
              className="absolute inset-x-0 z-10 -mb-px border-t border-dashed"
              style={{ bottom: `${(ref.value / tope) * 100}%`, borderColor: SERIE.contexto }}
            />
          )}

          {punto === null && valorCima > 0 && (
            <span
              aria-hidden
              className={`absolute z-10 mb-1 whitespace-nowrap type-panel-caption font-semibold tabular-nums text-on-surface ${
                anclaje(cima, n).clase
              }`}
              style={{ ...anclaje(cima, n).style, bottom: `${(valorCima / tope) * 100}%` }}
            >
              {formatShort(valorCima)}
            </span>
          )}

          {activo && punto !== null && (
            <Globo x={((punto + 0.5) / n) * 100} titulo={activo.label} filas={filas} nota={activo.note} />
          )}
        </div>
      </div>

      <div className="flex gap-2">
        <div className="w-11 shrink-0" />
        <div className="relative mt-2 h-4 min-w-0 flex-1" aria-hidden>
          {etiquetasDelEje(n).map(({ i, clase }) => {
            const a = anclaje(i, n)
            return (
              <span
                key={datos[i].key}
                className={`absolute whitespace-nowrap type-panel-caption tabular-nums ${
                  i === punto ? 'text-on-surface' : 'text-panel-muted'
                } ${a.clase} ${clase}`}
                style={a.style}
              >
                {datos[i].label}
              </span>
            )
          })}
        </div>
      </div>

      {pie}

      <p aria-live="polite" className="sr-only">
        {activo ? lecturaDelPunto(activo.label, filas, activo.note) : ''}
      </p>
    </ChartCard>
  )
}

/**
 * Una barra: punta redondeada arriba y cuadrada en la base. Un cero no es
 * una barra de altura cero —eso no se pinta— sino una marca en la base: ese
 * día existió y no pasó nada.
 */
function Barra({
  valor,
  tope,
  ancho,
  color,
}: {
  valor: number
  tope: number
  /** Valor CSS de `width`: el tope depende de cuántas barras haya. */
  ancho: string
  color: string
}) {
  if (valor <= 0) {
    return (
      <span
        className="absolute bottom-0 left-1/2 h-0.75 -translate-x-1/2 rounded-full"
        style={{ width: ancho, backgroundColor: SERIE.tenue }}
      />
    )
  }

  return (
    <span
      className="absolute bottom-0 left-1/2 -translate-x-1/2 rounded-t-extra-small"
      style={{
        height: `${Math.max((valor / tope) * 100, SUELO_VISIBLE)}%`,
        width: ancho,
        backgroundColor: color,
      }}
    />
  )
}
