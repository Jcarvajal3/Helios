import { ChartCard, SERIE, escalaBonita } from '@/components/charts'
import { TablaDelGrafico } from '@/components/charts/comun'
import { apilar, columnaBajo } from '@/components/charts/geometria'
import { Globo, lecturaDelPunto, useSenalado } from '@/components/charts/lectura'
import type { FilaDelGlobo } from '@/components/charts/lectura'
import { formatUsd, formatUsdShort } from '@/components/ui'
import { columnasDelCobro } from '@/features/admin/metricas/cohortes/comparar'
import type { ColumnaDelCobro } from '@/features/admin/metricas/cohortes/comparar'
import { desgloseCorto } from '@/features/admin/metricas/cohortes/desglose'
import { ROTULO_DE_ESTADO } from '@/features/admin/metricas/cohortes/estados'
import { fraseDelGrafico, pct } from '@/features/admin/metricas/cohortes/frases'
import { ESTADOS_DE_CUOTA } from '@/features/admin/metricas/cohortes/tipos'
import type { Cohorte } from '@/features/admin/metricas/cohortes/tipos'
import { COLOR_DE_ESTADO } from './colores'
import { TextoConCifras } from './TextoConCifras'

const ALTO = 200

/** El ancho de una columna: 24 px como mucho, como las barras del kit. */
const ANCHO = 'min(24px, calc(100% - 2px))'

/**
 * Lo que hay que cobrar, semana a semana: cada columna es el total a cobrar
 * de una semana de consumo (la cuota 1 + la 2, con el service fee dentro),
 * partido por estado con los colores de toda la pestaña: lo cobrado a tiempo
 * abajo, en el tono del área; lo cobrado tarde; lo vencido en ámbar; lo por
 * vencer en gris y lo perdido en rojo. Así se ve de un vistazo qué semanas
 * deben y cuánto de lo que falta todavía no vence.
 *
 * Se lee sin tocar nada: el eje con marcas redondas, el total de la columna
 * más alta escrito encima y la tabla (con el desglose de cada total: consumo
 * sin fee y service fee) a un clic en la cabecera. El globo sale al instante
 * con el ratón o con las flechas.
 */
export function GraficoDelCobro({ cohortes, semana }: { cohortes: ReadonlyArray<Cohorte>; semana: string }) {
  const columnas = columnasDelCobro(cohortes)
  const n = columnas.length
  const { punto, senalar, lienzo } = useSenalado(n, columnaBajo)
  const { tope, marcas } = escalaBonita(Math.max(0, ...columnas.map((c) => c.total.payableUsd)))
  const muestras = ESTADOS_DE_CUOTA.map((e) => COLOR_DE_ESTADO[e])
  // La frase habla de las mismas semanas que se ven.
  const vistas = new Set(columnas.map((c) => c.semana))

  const marco = {
    titulo: 'Total a cobrar por semana de financiamiento, por estado',
    info: 'Cada columna es el total a cobrar (cuota 1 + cuota 2, con fee) de los financiamientos de una de las doce últimas semanas, partido por su estado hoy; el desglose financiado + service fee + IVA está en el globo y en la tabla.',
    resumen: <TextoConCifras trozos={fraseDelGrafico(cohortes.filter((c) => vistas.has(c.semana)))} />,
    leyenda: ESTADOS_DE_CUOTA.map((e, i) => ({ rotulo: ROTULO_DE_ESTADO[e], color: muestras[i] ?? SERIE.principal })),
  }

  if (n === 0 || tope === 0) {
    return (
      <ChartCard {...marco}>
        <p className="type-panel-body text-panel-muted">Todavía no hay ninguna semana con algo que cobrar.</p>
      </ChartCard>
    )
  }

  const filasDe = (c: ColumnaDelCobro): FilaDelGlobo[] => [
    ...ESTADOS_DE_CUOTA.map((e, i) => {
      const v = c.valores[i] ?? 0
      return {
        key: e,
        rotulo: ROTULO_DE_ESTADO[e],
        valor: `${formatUsd(v)}${c.total.payableUsd > 0 && v > 0 ? ` · ${pct((v / c.total.payableUsd) * 100)}` : ''}`,
        color: v > 0 ? (muestras[i] ?? SERIE.principal) : SERIE.tenue,
        forma: 'punto' as const,
      }
    }),
    // El total, sin muestra: no es un tramo, es la columna entera.
    { key: '__total', rotulo: 'Total a cobrar', valor: formatUsd(c.total.payableUsd), color: 'transparent' },
  ]
  const notaDe = (c: ColumnaDelCobro) =>
    `${desgloseCorto(c.total)}${c.cobradoPct === null ? '' : ` · cobrado el ${pct(c.cobradoPct)}`}`

  // La columna más alta lleva su total escrito: es el dato que peor se estima.
  let cima = 0
  columnas.forEach((c, i) => {
    if (c.total.payableUsd > (columnas[cima]?.total.payableUsd ?? 0)) cima = i
  })
  const activa = punto === null ? null : (columnas[punto] ?? null)
  const elegida = columnas.findIndex((c) => c.semana === semana)

  return (
    <ChartCard
      {...marco}
      tabla={
        <TablaDelGrafico
          series={[
            ...ESTADOS_DE_CUOTA.map((e) => ({ key: e, label: ROTULO_DE_ESTADO[e] })),
            { key: '__total', label: 'Total a cobrar' },
            { key: '__consumo', label: 'De ello financiado (sin fee)' },
            { key: '__fee', label: 'De ello service fee + IVA' },
          ]}
          points={columnas.map((c) => ({
            key: c.semana,
            label: c.titulo,
            values: [...c.valores, c.total.payableUsd, c.total.financedUsd, c.total.feeUsd],
            note: c.cobradoPct === null ? '—' : pct(c.cobradoPct),
          }))}
          format={formatUsd}
          ejeLabel="Semana de financiamiento"
          unidadLabel="Cobrado (%)"
        />
      }
    >
      {/* El aire de arriba es para el total de la columna más alta. */}
      <div className="flex gap-2 pt-6">
        <div className="relative w-11 shrink-0" style={{ height: ALTO }} aria-hidden>
          {marcas.map((m) => (
            <span
              key={m}
              className="absolute right-0 translate-y-1/2 type-panel-caption tabular-nums text-panel-muted"
              style={{ bottom: `${(m / tope) * 100}%` }}
            >
              {formatUsdShort(m)}
            </span>
          ))}
        </div>

        <div
          role="img"
          aria-label={`Total a cobrar por semana de financiamiento, por estado. ${n} semanas. Las flechas las recorren; los números están en la tabla.`}
          {...lienzo}
          // Al entrar con el teclado, el globo sale al instante en la semana
          // elegida arriba (o en la última); las flechas siguen.
          onFocus={(e) => {
            if (punto === null && e.currentTarget.matches(':focus-visible')) senalar(elegida >= 0 ? elegida : n - 1)
          }}
          className="relative min-w-0 flex-1 touch-pan-y rounded-extra-small"
          style={{ height: ALTO }}
        >
          {/* La semana elegida arriba, con una banda detrás. */}
          {elegida >= 0 && (
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

          <div className="absolute inset-0 flex items-end" aria-hidden>
            {columnas.map((c, i) => {
              const { tramos, cima: arriba } = apilar(c.valores, tope)
              return (
                <div
                  key={c.semana}
                  className="relative h-full min-w-0 flex-1 transition-opacity duration-[var(--transition-fast)]"
                  style={{ opacity: punto === null || punto === i ? 1 : 0.5 }}
                >
                  {tramos.length === 0 ? (
                    // Una semana sin nada que cobrar es un dato: una marca en la base.
                    <span
                      className="absolute bottom-0 left-1/2 h-0.75 -translate-x-1/2 rounded-full"
                      style={{ width: ANCHO, backgroundColor: SERIE.tenue }}
                    />
                  ) : (
                    tramos.map((t, k) => (
                      <span
                        key={t.serie}
                        className={`absolute left-1/2 -translate-x-1/2 ${k === tramos.length - 1 ? 'rounded-t-extra-small' : ''}`}
                        // Dos píxeles de aire entre tramos, quitados al de encima.
                        style={{
                          bottom: k === 0 ? 0 : `calc(${t.base}% + 2px)`,
                          height: k === 0 ? `${t.alto}%` : `max(1px, calc(${t.alto}% - 2px))`,
                          width: ANCHO,
                          backgroundColor: muestras[t.serie] ?? SERIE.principal,
                        }}
                      />
                    ))
                  )}
                  {punto === null && i === cima && c.total.payableUsd > 0 && (
                    <span
                      className="absolute left-1/2 z-10 mb-1 -translate-x-1/2 whitespace-nowrap type-panel-caption font-semibold tabular-nums text-on-surface"
                      style={{ bottom: `${arriba}%` }}
                    >
                      {formatUsdShort(c.total.payableUsd)}
                    </span>
                  )}
                </div>
              )
            })}
          </div>

          {activa && punto !== null && (
            <Globo x={((punto + 0.5) / n) * 100} titulo={`Semana ${activa.titulo}`} filas={filasDe(activa)} nota={notaDe(activa)} />
          )}
        </div>
      </div>

      <div className="flex gap-2" aria-hidden>
        <div className="w-11 shrink-0" />
        <div className="mt-2 flex min-w-0 flex-1">
          {columnas.map((c, i) => (
            <span
              key={c.semana}
              className={`min-w-0 flex-1 truncate text-center type-panel-caption tabular-nums ${
                i === punto || i === elegida ? 'font-semibold text-on-surface' : 'text-panel-muted'
              }`}
            >
              {c.rotulo}
            </span>
          ))}
        </div>
      </div>

      <p aria-live="polite" className="sr-only">
        {activa ? lecturaDelPunto(`Semana ${activa.titulo}`, filasDe(activa), notaDe(activa)) : ''}
      </p>
    </ChartCard>
  )
}

