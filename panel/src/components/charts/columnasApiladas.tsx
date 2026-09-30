import { useId } from 'react'
import type { KeyboardEvent, MouseEvent, ReactNode } from 'react'
import { CircleAlert, TriangleAlert } from 'lucide-react'

import { TablaDelGrafico, escalaBonita } from '@/components/charts/comun'
import { apilar, columnaBajo } from '@/components/charts/geometria'
import { Globo, lecturaDelPunto, useSenalado } from '@/components/charts/lectura'
import type { FilaDelGlobo } from '@/components/charts/lectura'
import { ChartCard } from '@/components/charts/tarjeta'
import { SERIE, colorDeTono, rampaApilada } from '@/components/charts/tonos'

// ═══════════════════════════════════════════════════════════════════════════
// LAS COLUMNAS APILADAS.
//
// Pocas columnas (los siete días de una semana) partidas en sus sumandos: el
// de abajo en el tono del área y cada uno de encima, un paso más claro. Es la
// forma de enseñar un total que solo existe junto a sus partes —lo que vence
// cada día, consumo más fee—: el total va escrito encima de la columna,
// y la columna misma enseña de qué está hecho.
//
// Mismo lenguaje que `BarChart`: eje con marcas redondas, rejilla de un pelo,
// un cero es una marca en la base, 24 px de ancho como mucho, el mismo globo y
// el mismo teclado (← → Inicio Fin, Escape), y la tabla a un clic en la
// cabecera. Además, una columna se puede ELEGIR: con el ratón, o con Enter
// sobre la señalada.
// ═══════════════════════════════════════════════════════════════════════════

/** El ancho de una columna: 24 px como mucho, como las barras. */
const ANCHO = 'min(24px, calc(100% - 2px))'

/** Una serie de la pila, en orden de abajo arriba. */
export type SerieApilada = {
  key: string
  rotulo: string
  /**
   * Un color propio: un estado (`colorDeTono('error')`) o el gris de
   * contexto. Sin él, su paso de la rampa del área.
   */
  color?: string
  /**
   * Lo que todavía no ha pasado (lo programado): el tramo va solo con su
   * contorno discontinuo, para que no se lea como algo que ya ocurrió.
   */
  pendiente?: boolean
}

/**
 * Una cifra por columna que no se apila: se dibuja como una raya a su altura
 * (los que pagaron tras los avisos de ese día). Entra en la escala, en el
 * globo y en la tabla.
 */
export type MarcadorDeColumnas = {
  key: string
  rotulo: string
  valores: ReadonlyArray<number>
  color?: string
}

export type ColumnaApilada = {
  key: string
  /** Lo que se lee en el eje, corto: 'L 21'. */
  rotulo: string
  /** El nombre entero, para el globo y la tabla: 'lunes 21 de septiembre'. */
  titulo: string
  /** Un valor por serie, en el orden de `series`. */
  valores: ReadonlyArray<number>
  /** Lo que acompaña a las cifras en el globo y en la tabla: '3 cuotas · 2 personas'. */
  nota?: string
  /** Hoy: su rótulo va en blanco y debajo dice «Hoy». */
  hoy?: boolean
  /**
   * Una marca de estado bajo el rótulo del eje, con su icono: algo de esa
   * columna ESTÁ mal (un día pasado con cuotas sin pagar). Nunca un color de
   * serie: la marca no es un dato más, es un aviso.
   */
  marca?: { tono: 'warning' | 'error'; texto: string }
  /**
   * Lo que va bajo el rótulo del eje: qué pasa ese día (unas pastillas con
   * los peldaños de avisos). Ocupa lo que mide su columna y se envuelve
   * dentro de ella. No va a la tabla: si es un dato, que vaya también en
   * `nota`.
   */
  pie?: ReactNode
}

export type ColumnasApiladasProps = {
  titulo: string
  /** La explicación del gráfico, al InfoDot de la cabecera. */
  info?: string
  /** Una línea bajo el título. */
  resumen?: ReactNode
  /** Lo que va a la derecha de la cabecera, antes del botón de la tabla. */
  controles?: ReactNode
  series: ReadonlyArray<SerieApilada>
  columnas: ReadonlyArray<ColumnaApilada>
  /** Una cifra por columna que no se apila (ver `MarcadorDeColumnas`). */
  marcador?: MarcadorDeColumnas
  /** El importe completo: va en el globo y en la tabla. */
  formato: (n: number) => string
  /** El importe corto: va en el eje y encima de cada columna. */
  formatoCorto: (n: number) => string
  /** Cómo se llama el eje en la tabla: 'Día'. */
  ejeLabel: string
  /** El nombre de la suma de la columna en el globo y en la tabla. */
  totalLabel?: string
  /** Cómo se llama la columna de `nota` en la tabla. */
  unidadLabel?: string
  /** La columna elegida. Las demás se apagan. */
  seleccionada?: number | null
  /** Con esto las columnas se eligen; pulsar la elegida la suelta (`null`). */
  onSeleccionar?: (indice: number | null) => void
  alto?: number
  vacio?: string
}

export function ColumnasApiladas({
  titulo,
  info,
  resumen,
  controles,
  series,
  columnas,
  marcador,
  formato,
  formatoCorto,
  ejeLabel,
  totalLabel = 'Total',
  unidadLabel,
  seleccionada = null,
  onSeleccionar,
  alto = 200,
  vacio = 'No hay nada que enseñar en este periodo.',
}: ColumnasApiladasProps) {
  const id = useId()
  const n = columnas.length
  const { punto, senalar, lienzo } = useSenalado(n, columnaBajo)

  const rampa = rampaApilada(series.length)
  const colores = series.map((s, si) => s.color ?? (rampa[si] ?? SERIE.principal))
  const colorDelMarcador = marcador?.color ?? 'var(--color-on-surface)'
  // Un valor por serie, siempre: lo que falte es un cero y no un NaN.
  const datos = columnas.map((c, i) => {
    const valores = series.map((_, si) => Math.max(0, Number(c.valores[si]) || 0))
    const marcado = marcador ? Math.max(0, Number(marcador.valores[i]) || 0) : null
    return { ...c, valores, total: valores.reduce((a, b) => a + b, 0), marcado }
  })

  const { tope, marcas } = escalaBonita(Math.max(0, ...datos.map((d) => Math.max(d.total, d.marcado ?? 0))))
  const elegida = seleccionada !== null && seleccionada >= 0 && seleccionada < n ? seleccionada : null

  // La leyenda dice qué es cada tramo y, si alguna columna lleva marca, qué
  // significa: una marca de estado sin rótulo no se entiende.
  const leyenda = [
    ...series.map((s, si) => ({
      rotulo: s.rotulo,
      color: colores[si] ?? SERIE.principal,
      forma: s.pendiente ? ('discontinua' as const) : undefined,
    })),
    ...(marcador ? [{ rotulo: marcador.rotulo, color: colorDelMarcador, forma: 'linea' as const }] : []),
  ]
  const avisos = new Map<string, NonNullable<ColumnaApilada['marca']>>()
  for (const d of datos) if (d.marca) avisos.set(d.marca.texto, d.marca)
  const cabecera = (
    <>
      {[...avisos.values()].map((a) => (
        <span
          key={a.texto}
          className="inline-flex items-center gap-1.5 type-panel-caption text-on-surface-variant"
        >
          <IconoDeMarca tono={a.tono} />
          {a.texto}
        </span>
      ))}
      {controles}
    </>
  )
  const marco = { titulo, info, resumen, leyenda, controles: cabecera }

  if (n === 0 || tope === 0) {
    return (
      <ChartCard {...marco}>
        <p className="type-panel-body text-panel-muted">{vacio}</p>
      </ChartCard>
    )
  }

  const filasDe = (i: number): FilaDelGlobo[] => {
    const d = datos[i]
    return [
      ...series.map((s, si) => ({
        key: s.key,
        rotulo: s.rotulo,
        valor: formato(d.valores[si]),
        color: colores[si] ?? SERIE.principal,
        forma: s.pendiente ? ('discontinua' as const) : ('punto' as const),
      })),
      // La suma, sin muestra: no es un tramo, es la columna entera.
      { key: '__total', rotulo: totalLabel, valor: formato(d.total), color: 'transparent' },
      ...(marcador && d.marcado !== null
        ? [{ key: marcador.key, rotulo: marcador.rotulo, valor: formato(d.marcado), color: colorDelMarcador, forma: 'linea' as const }]
        : []),
    ]
  }
  const notaDe = (i: number) =>
    [datos[i].nota, datos[i].marca?.texto].filter((x) => x !== undefined && x !== '').join(' · ')

  const activo = punto === null ? null : datos[punto]
  const elegible = onSeleccionar !== undefined

  function elegir(i: number) {
    onSeleccionar?.(i === elegida ? null : i)
  }

  function alTeclear(e: KeyboardEvent<HTMLDivElement>) {
    if (elegible && (e.key === 'Enter' || e.key === ' ') && punto !== null) {
      e.preventDefault()
      elegir(punto)
      return
    }
    lienzo.onKeyDown(e)
  }

  // Al entrar con Tab se señala la elegida, o hoy: Enter tiene que hacer algo
  // desde el primer momento.
  function alEnfocar() {
    if (punto !== null) return
    const hoy = datos.findIndex((d) => d.hoy)
    senalar(elegida ?? (hoy >= 0 ? hoy : 0))
  }

  function alPulsar(e: MouseEvent<HTMLDivElement>) {
    if (!elegible) return
    const caja = e.currentTarget.getBoundingClientRect()
    if (caja.width === 0) return
    const i = columnaBajo((e.clientX - caja.left) / caja.width, n)
    senalar(i)
    elegir(i)
  }

  const ayuda = elegible
    ? 'Las flechas recorren las columnas y Enter elige una; los números están en la tabla.'
    : 'Las flechas recorren las columnas; los números están en la tabla.'

  // Elegible, es una lista de opciones con la señalada como activa; si no,
  // una imagen que canta la columna señalada por su región viva.
  const accesible = elegible
    ? {
        role: 'listbox',
        'aria-label': `${titulo}. ${ayuda}`,
        'aria-activedescendant': punto === null ? undefined : `${id}-${punto}`,
      }
    : { role: 'img', 'aria-label': `${titulo}. ${n} columnas. ${ayuda}` }

  return (
    <ChartCard
      {...marco}
      tabla={
        <TablaDelGrafico
          series={[
            ...series.map((s) => ({ key: s.key, label: s.rotulo })),
            { key: '__total', label: totalLabel },
            ...(marcador ? [{ key: marcador.key, label: marcador.rotulo }] : []),
          ]}
          points={datos.map((d) => ({
            key: d.key,
            label: d.titulo,
            values: [...d.valores, d.total, ...(d.marcado !== null ? [d.marcado] : [])],
            note: d.nota,
          }))}
          format={formato}
          ejeLabel={ejeLabel}
          unidadLabel={unidadLabel}
        />
      }
    >
      {/* El aire de arriba es para el total de la columna más alta. */}
      <div className="flex gap-2 pt-6">
        <div className="relative w-11 shrink-0" style={{ height: alto }} aria-hidden>
          {marcas.map((m) => (
            <span
              key={m}
              className="absolute right-0 translate-y-1/2 type-panel-caption tabular-nums text-panel-muted"
              style={{ bottom: `${(m / tope) * 100}%` }}
            >
              {formatoCorto(m)}
            </span>
          ))}
        </div>

        <div
          {...accesible}
          {...lienzo}
          onKeyDown={alTeclear}
          onFocus={alEnfocar}
          onClick={alPulsar}
          className={`relative min-w-0 flex-1 touch-pan-y rounded-extra-small ${elegible ? 'cursor-pointer' : ''}`}
          style={{ height: alto }}
        >
          {/* La elegida, con una banda detrás que llega hasta arriba: se ve
              qué día filtra lo de abajo aunque su columna sea baja. */}
          {elegida !== null && (
            <span
              aria-hidden
              className="absolute inset-y-0 rounded-panel-control bg-panel-raised"
              style={{ left: `${(elegida / n) * 100}%`, width: `${100 / n}%` }}
            />
          )}

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

          <div className="absolute inset-0 flex items-end">
            {datos.map((d, i) => {
              const { tramos, cima } = apilar(d.valores, tope)
              const opacidad =
                punto !== null ? (punto === i ? 1 : 0.5) : elegida !== null && elegida !== i ? 0.4 : 1
              const lectura = lecturaDelPunto(d.titulo, filasDe(i), notaDe(i) || undefined)
              return (
                <div
                  key={d.key}
                  id={`${id}-${i}`}
                  {...(elegible
                    ? { role: 'option', 'aria-selected': elegida === i, 'aria-label': lectura }
                    : { 'aria-hidden': true })}
                  className="relative h-full min-w-0 flex-1 transition-opacity duration-[var(--transition-fast)]"
                  style={{ opacity: opacidad }}
                >
                  {tramos.length === 0 ? (
                    // Un día sin nada es un dato: una marca en la base.
                    <span
                      aria-hidden
                      className="absolute bottom-0 left-1/2 h-0.75 -translate-x-1/2 rounded-full"
                      style={{ width: ANCHO, backgroundColor: SERIE.tenue }}
                    />
                  ) : (
                    tramos.map((t, k) => {
                      const color = colores[t.serie] ?? SERIE.principal
                      // Lo pendiente, hueco y con el borde discontinuo: no ha pasado.
                      const relleno = series[t.serie]?.pendiente
                        ? { backgroundColor: 'transparent', border: `1.5px dashed ${color}` }
                        : { backgroundColor: color }
                      return (
                        <span
                          key={t.serie}
                          aria-hidden
                          className={`absolute left-1/2 -translate-x-1/2 ${
                            k === tramos.length - 1 ? 'rounded-t-extra-small' : ''
                          }`}
                          // Dos píxeles de aire entre tramos, quitados al de
                          // encima: la columna acaba donde dice la escala.
                          style={{
                            bottom: k === 0 ? 0 : `calc(${t.base}% + 2px)`,
                            height: k === 0 ? `${t.alto}%` : `max(1px, calc(${t.alto}% - 2px))`,
                            width: ANCHO,
                            ...relleno,
                          }}
                        />
                      )
                    })
                  )}

                  {/* El marcador: una raya más ancha que la columna, a su altura. */}
                  {d.marcado !== null && d.marcado > 0 && (
                    <span
                      aria-hidden
                      className="absolute left-1/2 z-10 h-0.5 -translate-x-1/2 translate-y-1/2 rounded-full"
                      style={{
                        bottom: `${(d.marcado / tope) * 100}%`,
                        width: 'min(36px, calc(100% - 2px))',
                        backgroundColor: colorDelMarcador,
                        boxShadow: '0 0 0 1px var(--color-panel-card)',
                      }}
                    />
                  )}

                  {d.total > 0 && (
                    <span
                      aria-hidden
                      className="absolute left-1/2 z-10 mb-1 -translate-x-1/2 whitespace-nowrap type-panel-caption font-semibold tabular-nums text-on-surface"
                      style={{ bottom: `${cima}%` }}
                    >
                      {formatoCorto(d.total)}
                    </span>
                  )}
                </div>
              )
            })}
          </div>

          {activo && punto !== null && (
            <Globo
              x={((punto + 0.5) / n) * 100}
              titulo={activo.titulo}
              filas={filasDe(punto)}
              nota={notaDe(punto) || undefined}
            />
          )}
        </div>
      </div>

      <div className="flex gap-2" aria-hidden>
        <div className="w-11 shrink-0" />
        <div className="mt-2 flex min-w-0 flex-1">
          {datos.map((d, i) => (
            <div key={d.key} className="flex min-w-0 flex-1 flex-col items-center gap-0.5">
              <span
                className={`whitespace-nowrap type-panel-caption tabular-nums ${
                  d.hoy || i === punto || i === elegida
                    ? 'font-semibold text-on-surface'
                    : 'text-panel-muted'
                }`}
              >
                {d.rotulo}
              </span>
              <span className="flex h-4 items-center type-panel-caption text-on-surface">
                {d.hoy ? 'Hoy' : d.marca ? <IconoDeMarca tono={d.marca.tono} titulo={d.marca.texto} /> : null}
              </span>
              {d.pie !== undefined && <div className="mt-1 w-full min-w-0 px-0.5">{d.pie}</div>}
            </div>
          ))}
        </div>
      </div>

      {!elegible && (
        <p aria-live="polite" className="sr-only">
          {activo && punto !== null ? lecturaDelPunto(activo.titulo, filasDe(punto), notaDe(punto) || undefined) : ''}
        </p>
      )}
    </ChartCard>
  )
}

/** El icono de una marca de estado, en su color: el de la pastilla de ese tono. */
function IconoDeMarca({ tono, titulo }: { tono: 'warning' | 'error'; titulo?: string }) {
  const Icono = tono === 'error' ? CircleAlert : TriangleAlert
  return (
    <span title={titulo} className="inline-flex" style={{ color: colorDeTono(tono) }}>
      <Icono size={12} aria-hidden />
    </span>
  )
}
