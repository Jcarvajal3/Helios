import type { ReactNode } from 'react'

import { ChartCard, SERIE } from '@/components/charts'
import { TablaDelGrafico } from '@/components/charts/comun'
import { indiceCercano } from '@/components/charts/geometria'
import { Globo, lecturaDelPunto, useSenalado } from '@/components/charts/lectura'
import type { FilaDelGlobo } from '@/components/charts/lectura'
import { formatPct } from '@/components/ui'
import {
  MARCAS_PCT,
  curvaVacia,
  marcasDeDias,
  tramoDe,
  trazoDeCurva,
  ultimoDe,
  xDeDia,
  yDePct,
} from '@/features/admin/metricas/cohortes/curva'
import { fraseDeLaCurva, pct } from '@/features/admin/metricas/cohortes/frases'
import { rotuloDeDia } from '@/features/admin/metricas/cohortes/semanas'
import type { CuotaDeCohorte, CurvaDeCuota } from '@/features/admin/metricas/cohortes/tipos'

const ALTO = 180

/** Por debajo de esta distancia (px) las dos cifras finales se pisan. */
const SEPARACION = 16

const formato = (v: number) => formatPct(v, 1)

/**
 * Cómo se fue cobrando una cuota de la semana, día a día desde que vence,
 * frente a la media de las semanas anteriores.
 *
 * Cada cuota se mide contra SU vencimiento (los consumos de una semana vencen
 * en días distintos), con el día del pago de todo el panel: el día en que
 * la persona REPORTÓ el pago (decisión de Javier del 27-09). La franja marca
 * los días de gracia: lo cobrado hasta su borde derecho es lo cobrado a
 * tiempo. Todo en % de lo que se cobra en la cuota (consumo + service fee). Esta semana solo pinta los días que ya
 * terminaron para todas sus cuotas; un día a medias todavía puede subir.
 *
 * Se lee sin tocar nada: el eje con marcas redondas, la cifra de cada línea
 * escrita al final y la tabla con todos los días a un clic en la cabecera.
 */
export function CurvaDeCobro({
  curva,
  cuota,
  graciaDias,
  controles,
}: {
  curva: CurvaDeCuota
  cuota: CuotaDeCohorte | null
  graciaDias: number
  /** El Segmented de cuota 1 / cuota 2. */
  controles?: ReactNode
}) {
  const n = curva.puntos.length
  const { punto, senalar, lienzo } = useSenalado(n, indiceCercano)
  const t = tramoDe(curva)
  const semanas = curva.semanasMedia.length
  const rotuloMedia =
    semanas === 1 ? 'La semana anterior' : `Media de las ${semanas} semanas anteriores`
  const titulo = `Cuota ${curva.numero}: cobrado acumulado por día desde el vencimiento (%)`

  const series = [
    { key: 'esta', label: 'Esta semana' },
    { key: 'media', label: rotuloMedia },
  ]
  const leyenda = [
    { rotulo: 'Esta semana', color: SERIE.principal, forma: 'linea' as const },
    ...(semanas > 0 ? [{ rotulo: rotuloMedia, color: SERIE.contexto, forma: 'discontinua' as const }] : []),
  ]
  const puntos = curva.puntos.map((p) => ({
    key: String(p.dia),
    label: rotuloDeDia(p.dia),
    values: [p.estaPct, p.mediaPct],
    note: semanas > 0 ? `${p.semanasEnMedia} de ${semanas}` : '—',
  }))

  const marco = {
    titulo,
    info: `Cobrado de la cuota ${curva.numero} de esta semana hasta cada día contado desde su vencimiento (por día operativo en que se registró el pago) ÷ total de la cuota ${curva.numero}, en dólares con fee, frente a la media simple de las (hasta) cuatro semanas anteriores en los días que todas cerraron; la franja son los ${graciaDias} días de gracia, y su borde es lo cobrado a tiempo.`,
    resumen: fraseDeLaCurva(curva, cuota),
    leyenda,
    controles,
  }

  if (n === 0 || curvaVacia(curva)) {
    return (
      <ChartCard {...marco}>
        <p className="type-panel-body text-panel-muted">
          Todavía no hay ningún día cerrado que dibujar, ni de esta semana ni de las anteriores.
        </p>
      </ChartCard>
    )
  }

  const ultimaEsta = ultimoDe(curva, 'esta')
  const ultimaMedia = ultimoDe(curva, 'media')
  const finales = [
    ...(ultimaEsta ? [{ clave: 'esta', ...ultimaEsta, prota: true }] : []),
    ...(ultimaMedia &&
    (!ultimaEsta ||
      Math.abs(xDeDia(ultimaMedia.dia, t) - xDeDia(ultimaEsta.dia, t)) > 20 ||
      (Math.abs(ultimaMedia.pct - ultimaEsta.pct) / 100) * ALTO >= SEPARACION)
      ? [{ clave: 'media', ...ultimaMedia, prota: false }]
      : []),
  ]

  const activo = punto === null ? null : curva.puntos[punto]
  const filas: Array<FilaDelGlobo> = activo
    ? [
        { key: 'esta', rotulo: 'Esta semana', valor: activo.estaPct === null ? 'sin cerrar' : pct(activo.estaPct), color: SERIE.principal },
        ...(semanas > 0
          ? [
              {
                key: 'media',
                rotulo: rotuloMedia,
                valor: activo.mediaPct === null ? '—' : pct(activo.mediaPct),
                color: SERIE.contexto,
                forma: 'discontinua' as const,
              },
            ]
          : []),
      ]
    : []
  // Lo que acompaña a las cifras de un día: si cae en la gracia (la franja no
  // lleva `title`: lo dice el globo) y cuántas semanas de la media lo cerraron.
  const notaDelDia = (dia: number, cerradas: number): string | undefined =>
    [
      graciaDias > 0 && dia >= 0 && dia <= graciaDias
        ? `Día de gracia: lo pagado hasta el día +${graciaDias} es a tiempo`
        : null,
      semanas > 0 ? `${cerradas} de ${semanas} semanas anteriores ya lo cerraron` : null,
    ]
      .filter((x) => x !== null)
      .join(' · ') || undefined
  const xVence = xDeDia(0, t)
  const ultimoConDato = curva.puntos.map((p) => p.estaPct !== null).lastIndexOf(true)
  const diaDeEntrada = ultimoConDato >= 0 ? ultimoConDato : Math.max(0, curva.puntos.findIndex((p) => p.dia === 0))
  const xGracia = xDeDia(Math.min(graciaDias, t.hasta), t)

  return (
    <ChartCard
      {...marco}
      tabla={
        <TablaDelGrafico
          series={series}
          points={puntos}
          format={formato}
          ejeLabel="Día"
          unidadLabel="Semanas de la media que ya lo cerraron"
        />
      }
    >
      <div className="flex gap-2 pt-2">
        <div className="relative w-11 shrink-0" style={{ height: ALTO }} aria-hidden>
          {MARCAS_PCT.map((m) => (
            <span
              key={m}
              className="absolute right-0 translate-y-1/2 type-panel-caption tabular-nums text-panel-muted"
              style={{ bottom: `${m}%` }}
            >
              {m} %
            </span>
          ))}
        </div>

        <div
          role="img"
          aria-label={`${titulo}. ${n} días, de ${rotuloDeDia(t.desde)} a ${rotuloDeDia(t.hasta)}. Las flechas los recorren; los números están en la tabla.`}
          {...lienzo}
          // Al entrar con el teclado, el globo sale al instante en el último día
          // cerrado de esta semana (o en el del vencimiento); las flechas siguen.
          onFocus={(e) => {
            if (punto === null && e.currentTarget.matches(':focus-visible')) senalar(diaDeEntrada)
          }}
          className="relative min-w-0 flex-1 touch-pan-y rounded-extra-small"
          style={{ height: ALTO }}
        >
          {/* Los días de gracia: lo pagado hasta su borde es a tiempo. */}
          {graciaDias > 0 && xGracia > xVence && (
            <span
              aria-hidden
              className="absolute inset-y-0"
              style={{
                left: `${xVence}%`,
                width: `${xGracia - xVence}%`,
                backgroundColor: 'color-mix(in oklab, var(--area) 9%, transparent)',
              }}
            />
          )}

          {MARCAS_PCT.map((m) => (
            <span
              key={m}
              aria-hidden
              className={`absolute inset-x-0 -mb-px border-t ${
                m === 0 ? 'border-panel-hairline-strong' : 'border-panel-hairline'
              }`}
              style={{ bottom: `${m}%` }}
            />
          ))}

          {/* El día en que vence. */}
          <span
            aria-hidden
            className="absolute inset-y-0 -translate-x-1/2 border-l border-dashed border-panel-hairline-strong"
            style={{ left: `${xVence}%` }}
          />

          {punto !== null && (
            <span
              aria-hidden
              className="absolute inset-y-0 w-px -translate-x-1/2 bg-on-surface/20"
              style={{ left: `${xDeDia(curva.puntos[punto].dia, t)}%` }}
            />
          )}

          <svg
            viewBox="0 0 100 100"
            preserveAspectRatio="none"
            aria-hidden
            className="absolute inset-0 size-full overflow-visible"
          >
            <path
              d={trazoDeCurva(curva, 'media')}
              fill="none"
              strokeWidth={2}
              strokeDasharray="5 5"
              strokeLinejoin="round"
              vectorEffect="non-scaling-stroke"
              style={{ stroke: SERIE.contexto }}
            />
            <path
              d={trazoDeCurva(curva, 'esta')}
              fill="none"
              strokeWidth={2.5}
              strokeLinejoin="round"
              strokeLinecap="round"
              vectorEffect="non-scaling-stroke"
              style={{ stroke: SERIE.principal }}
            />
          </svg>

          {finales.map((f) => (
            <span key={`punto-${f.clave}`} aria-hidden>
              <span
                className="absolute z-10 size-2.5 -translate-x-1/2 translate-y-1/2 rounded-full ring-2 ring-panel-card"
                style={{
                  left: `${xDeDia(f.dia, t)}%`,
                  bottom: `${yDePct(f.pct)}%`,
                  backgroundColor: f.prota ? SERIE.principal : SERIE.contexto,
                }}
              />
              <span
                className={`absolute z-10 translate-y-1/2 whitespace-nowrap type-panel-caption font-semibold tabular-nums ${
                  f.prota ? 'text-on-surface' : 'text-on-surface-variant'
                }`}
                style={{ left: `calc(${xDeDia(f.dia, t)}% + 10px)`, bottom: `${yDePct(f.pct)}%` }}
              >
                {pct(f.pct)}
              </span>
            </span>
          ))}

          {activo && punto !== null && (
            <Globo
              x={xDeDia(activo.dia, t)}
              titulo={rotuloDeDia(activo.dia)}
              filas={filas}
              nota={notaDelDia(activo.dia, activo.semanasEnMedia)}
            />
          )}
        </div>

        {/* El margen de las cifras finales. */}
        <div className="w-14 shrink-0" />
      </div>

      <div className="flex gap-2">
        <div className="w-11 shrink-0" />
        <div className="relative mt-2 h-4 min-w-0 flex-1" aria-hidden>
          {marcasDeDias(t).map((d) => {
            const x = xDeDia(d, t)
            const ancla = x < 8 ? 'left-0' : x > 92 ? 'right-0' : '-translate-x-1/2'
            return (
              <span
                key={d}
                className={`absolute whitespace-nowrap type-panel-caption tabular-nums ${ancla} ${
                  d === 0 ? 'font-semibold text-on-surface' : 'text-panel-muted'
                }`}
                style={x < 8 || x > 92 ? undefined : { left: `${x}%` }}
              >
                {rotuloDeDia(d)}
              </span>
            )
          })}
        </div>
        <div className="w-14 shrink-0" />
      </div>

      <p aria-live="polite" className="sr-only">
        {activo ? lecturaDelPunto(rotuloDeDia(activo.dia), filas, notaDelDia(activo.dia, activo.semanasEnMedia)) : ''}
      </p>
    </ChartCard>
  )
}
