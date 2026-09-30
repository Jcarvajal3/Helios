import { ChartCard, SERIE } from '@/components/charts'
import { columnaBajo } from '@/components/charts/geometria'
import { Globo, lecturaDelPunto, useSenalado } from '@/components/charts/lectura'
import type { FilaDelGlobo } from '@/components/charts/lectura'
import { Badge, Table, Td, Tr, formatPorcentaje } from '@/components/ui'
import { comoPagaLaGente } from '@/features/admin/metricas/locales/pago'
import type { CeldaDePago, FilaDePago } from '@/features/admin/metricas/locales/pago'
import { semanaCorta } from '@/features/admin/metricas/locales/semanas'
import type { LocalesDeLaSemana } from '@/features/admin/metricas/locales/tipos'
import type { Parametros } from '@/features/admin/parametros'
import { tonoCobroATiempo } from '@/features/admin/umbrales'

/**
 * «Cómo paga la gente de cada local»: de lo consumido en cada una de las
 * cuatro semanas anteriores, qué parte de la cuota 1 se cobró a tiempo.
 *
 * Va en el tono de Cobranza (azul), que es de lo que habla. El número va en
 * blanco y solo se pinta de color —en una pastilla— al quedar por debajo de
 * la meta de Ajustes (`umbral_cobro_a_tiempo_*`). Una semana sin ventas no es
 * un 0 %: se dice. Cada fila se lee como un gráfico del kit: el globo al pasar
 * el ratón por una semana, las flechas con el teclado.
 */
export function ComoPagaLaGente({ d, parametros }: { d: LocalesDeLaSemana; parametros: Parametros | undefined }) {
  const { semanas, filas } = comoPagaLaGente(d)

  return (
    <div data-area="cobranza" className="h-full">
      <ChartCard
        className="h-full"
        titulo="Cuota 1 cobrada a tiempo (%), por clínica"
        info={`Por clínica y semana de financiamiento (las cuatro anteriores a la elegida): las cuotas 1 pagadas a tiempo entre las que ya cerraron su plazo (el vencimiento más ${d.graciaDias} días de gracia). Un pago cuenta el día en que se reportó. Una semana reciente puede ir a medias. Es la misma cuenta que Cobros.`}
        resumen="Por semana de financiamiento, las cuatro anteriores a la elegida."
        tabla={filas.length > 0 ? <TablaDePago semanas={semanas} filas={filas} /> : undefined}
      >
        {filas.length === 0 ? (
          <p className="type-panel-body text-panel-muted">
            Ninguna clínica vendió en las cuatro semanas anteriores a esta.
          </p>
        ) : (
          <ul className="flex flex-col gap-4">
            {filas.map((f) => (
              <li key={f.merchantId} className="grid grid-cols-[minmax(0,8rem)_minmax(0,1fr)] items-end gap-4">
                <span className="truncate pb-4 type-panel-label text-on-surface">{f.nombre}</span>
                <CeldasDelLocal f={f} parametros={parametros} />
              </li>
            ))}
          </ul>
        )}
      </ChartCard>
    </div>
  )
}

/** Lo que dice el globo de una semana: el porcentaje y de cuántas cuotas sale. */
function filasDeLaCelda(c: CeldaDePago): FilaDelGlobo[] {
  if (c.estado === 'juzgada') {
    const filas: FilaDelGlobo[] = [
      { key: 'pct', rotulo: 'cobrada a tiempo', valor: formatPorcentaje(c.pct, 0), color: SERIE.principal, forma: 'punto' },
      { key: 'juzgadas', rotulo: 'cuotas 1 a tiempo, de las juzgadas', valor: `${c.aTiempo} de ${c.juzgadas}`, color: 'transparent' },
    ]
    if (c.juzgadas < c.cuotas) {
      filas.push({ key: 'plazo', rotulo: 'siguen en plazo', valor: String(c.cuotas - c.juzgadas), color: 'transparent' })
    }
    return filas
  }
  if (c.estado === 'sin-veredicto') {
    return [{ key: 'plazo', rotulo: 'cuotas 1, todas en plazo todavía', valor: String(c.cuotas), color: SERIE.vacio, forma: 'punto' }]
  }
  return [{ key: 'ventas', rotulo: 'financiamientos: no vendió esa semana', valor: '0', color: SERIE.vacio, forma: 'punto' }]
}

/** Las cuatro semanas de un local, con el globo del kit. */
function CeldasDelLocal({ f, parametros }: { f: FilaDePago; parametros: Parametros | undefined }) {
  const n = f.celdas.length
  const { punto, senalar, lienzo } = useSenalado(n, columnaBajo)
  const activa = punto === null ? null : (f.celdas[punto] ?? null)
  const titulo = (c: CeldaDePago) => `${f.nombre} · ${semanaCorta(c.semana)}`
  const lectura = f.celdas
    .map((c) => lecturaDelPunto(semanaCorta(c.semana), filasDeLaCelda(c)))
    .join(' ')

  return (
    <>
      <span
        role="img"
        aria-label={`Cuota 1 cobrada a tiempo en ${f.nombre}. Las flechas recorren las semanas. ${lectura}`}
        {...lienzo}
        // Al entrar con el tabulador, el globo sale ya en la semana más reciente.
        onFocus={() => {
          if (punto === null) senalar(n - 1)
        }}
        className="relative grid touch-pan-y grid-cols-4 gap-2.5 rounded-extra-small"
      >
        {f.celdas.map((c, i) => (
          <Celda key={c.semana} c={c} parametros={parametros} apagada={punto !== null && punto !== i} />
        ))}
        {activa && punto !== null && (
          <Globo x={((punto + 0.5) / n) * 100} titulo={titulo(activa)} filas={filasDeLaCelda(activa)} />
        )}
      </span>
      {/* Fuera del lienzo: lo de dentro de un role="img" no se lee. */}
      <span aria-live="polite" className="sr-only">
        {activa ? lecturaDelPunto(titulo(activa), filasDeLaCelda(activa)) : ''}
      </span>
    </>
  )
}

function Celda({ c, parametros, apagada }: { c: CeldaDePago; parametros: Parametros | undefined; apagada: boolean }) {
  const juzgada = c.estado === 'juzgada'
  const tono = juzgada ? tonoCobroATiempo(c.pct, parametros) : 'neutral'
  const valor = juzgada ? formatPorcentaje(c.pct, 0) : c.estado === 'sin-ventas' ? 'sin financiamientos' : 'en plazo'

  return (
    <span
      aria-hidden
      className="flex min-w-0 flex-col gap-1.5 transition-opacity duration-[var(--transition-fast)]"
      style={{ opacity: apagada ? 0.5 : 1 }}
    >
      <span className="flex items-baseline justify-between gap-1 type-panel-caption">
        <span className="truncate text-panel-muted">{semanaCorta(c.semana)}</span>
        {juzgada && (tono === 'warning' || tono === 'error') ? (
          <Badge tone={tono}>{valor}</Badge>
        ) : (
          <span className={`font-semibold tabular-nums ${juzgada ? 'text-on-surface' : 'text-panel-muted'}`}>{valor}</span>
        )}
      </span>
      <span aria-hidden className="flex h-1.5 overflow-hidden rounded-full" style={{ backgroundColor: SERIE.vacio }}>
        {juzgada && (
          <span className="h-full rounded-full" style={{ width: `${Math.min(100, c.pct)}%`, backgroundColor: SERIE.principal }} />
        )}
      </span>
    </span>
  )
}

function TablaDePago({ semanas, filas }: { semanas: ReadonlyArray<string>; filas: ReadonlyArray<FilaDePago> }) {
  return (
    <Table headers={['Clínica', ...semanas.map(semanaCorta)]}>
      {filas.map((f) => (
        <Tr key={f.merchantId}>
          <Td>{f.nombre}</Td>
          {f.celdas.map((c) => (
            <Td key={c.semana} className="text-right tabular-nums">
              {c.estado === 'juzgada'
                ? `${formatPorcentaje(c.pct, 0)} (${c.aTiempo} de ${c.juzgadas})`
                : c.estado === 'sin-ventas'
                  ? 'sin financiamientos'
                  : `en plazo (${c.cuotas})`}
            </Td>
          ))}
        </Tr>
      ))}
    </Table>
  )
}
