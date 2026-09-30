import {
  Card,
  Seccion,
  Segmented,
  Stat,
  StatGrid,
  formatUsd,
  formatUsdShort,
  formatPorcentaje,
} from '@/components/ui'
import { BarChart, Ring } from '@/components/charts'
import type { CohortBase, CohortGrain, CohortRow, UserCohorts } from '@/features/admin/growth'
import {
  OPCIONES_DE_MEDIDA,
  TEXTOS_DE_BASE,
  UNIDAD,
  enFecha,
  etiquetaCubo,
  etiquetaPeriodo,
  mayuscula,
} from './cohortes'
import type { Medida } from './cohortes'

/**
 * Una cohorte a la vez: la lista para elegirla y su historia al lado.
 *
 * Sin elección, NO abre por la cohorte más reciente aunque sea la primera de
 * la lista: esa acaba de entrar y solo tiene la columna 0, así que la pantalla
 * se estrenaría con una sola barra y un «todavía no ha pasado una semana».
 * Abre por la más reciente que ya tenga un después, que es la que enseña de
 * qué va esto. La de esta semana está a un clic.
 */
export function UnaCohorte({
  data,
  elegida,
  onElegir,
  medida,
  onMedida,
}: {
  data: UserCohorts
  elegida: string | undefined
  onElegir: (start: string) => void
  medida: Medida
  onMedida: (m: Medida) => void
}) {
  const unidad = UNIDAD[data.grain]

  // La elegida puede no existir tras cambiar de cubo, y la lista puede estar
  // vacía si todavía no se ha registrado nadie.
  const fila =
    data.rows.find((r) => r.start === elegida) ??
    data.rows.find((r) => r.maxPeriod >= 1) ??
    data.rows.at(0)

  if (!fila) {
    return (
      <Card>
        <p className="type-panel-body text-on-surface-variant">
          {TEXTOS_DE_BASE[data.base].vacio}
        </p>
      </Card>
    )
  }

  return (
    <div className="grid gap-6 lg:grid-cols-[13rem_minmax(0,1fr)]">
      <nav aria-label={unidad.lista} className="flex flex-col gap-0.5">
        <p className="mb-1 px-3 type-panel-label text-on-surface-variant">{unidad.lista}</p>
        {data.rows.map((r) => {
          const activa = r.start === fila.start
          return (
            <button
              key={r.start}
              type="button"
              aria-current={activa ? 'true' : undefined}
              onClick={() => onElegir(r.start)}
              // Como el ítem activo del menú: levantado y en blanco, nunca en
              // lima. Elegir de una lista no es una acción, es estar en un sitio.
              className={`rounded-panel-control px-3 py-2 text-left transition-colors duration-[var(--transition-fast)] ${
                activa
                  ? 'bg-panel-raised text-on-surface'
                  : 'text-on-surface-variant hover:bg-panel-raised hover:text-on-surface'
              }`}
            >
              <span className="block type-panel-control">{etiquetaCubo(r.start, data.grain)}</span>
              <span className="block type-panel-caption text-panel-muted">
                {TEXTOS_DE_BASE[data.base].miembros(r.size)}
              </span>
            </button>
          )
        })}
      </nav>

      <Historia fila={fila} grain={data.grain} base={data.base} medida={medida} onMedida={onMedida} />
    </div>
  )
}

/**
 * La historia de una cohorte: quiénes entraron, cuántos hicieron su primer
 * consumo, cuántos vuelven y cuánto llevan gastado. Todas las cifras son sobre
 * las mismas personas, por mucha gente nueva que entre después.
 */
function Historia({
  fila,
  grain,
  base,
  medida,
  onMedida,
}: {
  fila: CohortRow
  grain: CohortGrain
  base: CohortBase
  medida: Medida
  onMedida: (m: Medida) => void
}) {
  const unidad = UNIDAD[grain]
  const textos = TEXTOS_DE_BASE[base]

  const consumieron = fila.size > 0 ? (fila.everActive / fila.size) * 100 : 0
  const siguiente = fila.cells.find((c) => c.k === 1)
  const vuelven = siguiente && fila.size > 0 ? (siguiente.active / fila.size) * 100 : null
  const ultima = fila.cells.at(-1)
  const porPersona = fila.size > 0 ? fila.everFinancedUsd / fila.size : 0
  const enCurso =
    ultima && ultima.k > 0
      ? ` ${mayuscula(unidad.uno)} ${ultima.k} es ${unidad.el} en curso: esa barra va a subir todavía.`
      : ''

  return (
    <div className="flex flex-col gap-10">
      <Seccion
        titulo={`La gente que ${textos.laGenteQue} ${enFecha(fila.start, grain)}`}
        info={`Entraron ${textos.miembros(fila.size)}. Todas las cifras de aquí abajo son sobre esa misma gente: ni uno más ni uno menos, por muchos que entren después.`}
      >
        <StatGrid cols={4}>
          <Stat label={textos.entraron} value={String(fila.size)} hint={mayuscula(enFecha(fila.start, grain))} />
          <Stat
            label="Se financiaron alguna vez"
            value={String(fila.everActive)}
            info="Los de la cohorte con al menos un financiamiento desde que entraron (en la clínica, si hay uno elegido), no solo al entrar."
            hint={`${formatPorcentaje(consumieron)} de ${fila.size}`}
            lateral={
              <Ring
                tamano="sm"
                valor={fila.size > 0 ? consumieron / 100 : null}
                rotulo={`Se financiaron alguna vez: ${formatPorcentaje(consumieron)}`}
              />
            }
          />
          <Stat
            label={`Se financiaron ${unidad.siguiente}`}
            info={`Los de la cohorte con al menos un financiamiento en el periodo 1 (${unidad.siguiente} de entrar), se hubieran financiado al entrar o no.`}
            value={siguiente ? String(siguiente.active) : '—'}
            hint={
              siguiente && vuelven !== null
                ? `${formatPorcentaje(vuelven)} de ${fila.size}`
                : `Todavía no ha pasado ${unidad.uno === 'mes' ? 'un mes' : `una ${unidad.uno}`}`
            }
            lateral={
              <Ring
                tamano="sm"
                valor={vuelven === null ? null : vuelven / 100}
                rotulo={`Se financiaron ${unidad.siguiente}: ${vuelven === null ? 'sin dato' : formatPorcentaje(vuelven)}`}
              />
            }
          />
          <Stat
            label="Financiado desde que entraron (sin fee)"
            value={formatUsd(fila.everFinancedUsd)}
            info="Sin el service fee: todo lo financiado a esta cohorte desde que entró (en un grupo, la parte de cada uno)."
            hint={`${formatUsd(porPersona)} sin fee por paciente de la cohorte`}
          />
        </StatGrid>
      </Seccion>

      <Seccion
        titulo="Financiamiento de la cohorte por periodo"
        controles={
          <Segmented
            etiqueta="Medida"
            options={OPCIONES_DE_MEDIDA}
            value={medida}
            onChange={onMedida}
          />
        }
      >
        {medida === 'gente' ? (
          <BarChart
            title={`Cuántos de los ${fila.size} se financiaron, por periodo`}
            summary={frase(fila, grain)}
            // Dos series y en este orden: la primera es el listón —siempre el
            // tamaño de la cohorte— y la segunda va DENTRO. Lo que sobresale del
            // gris es, literalmente, la gente de la cohorte que no vino.
            enteros
            series={[
              { key: 'size', label: 'Entraron' },
              { key: 'active', label: 'Se financiaron' },
            ]}
            points={fila.cells.map((c) => ({
              key: String(c.k),
              label: etiquetaPeriodo(c.k, grain),
              values: [fila.size, c.active],
              note: `${formatPorcentaje((c.active / Math.max(fila.size, 1)) * 100)} · ${formatUsdShort(c.financedUsd)} sin fee`,
            }))}
            format={(v) => textos.miembros(Math.round(v))}
            formatShort={(v) => String(Math.round(v))}
            ejeLabel={mayuscula(unidad.uno)}
            unidadLabel="De la cohorte"
            footnote={`La barra gris son los ${fila.size} que entraron; la de color, cuántos de ellos se financiaron en ese periodo.${enCurso}`}
            empty="Esta cohorte todavía no se ha financiado."
          />
        ) : (
          <BarChart
            title="Financiado por periodo (sin fee)"
            summary={`${formatUsd(fila.everFinancedUsd)} en total · ${formatUsd(porPersona)} por paciente de la cohorte`}
            series={[{ key: 'financed', label: 'Financiado (sin fee)' }]}
            points={fila.cells.map((c) => ({
              key: String(c.k),
              label: etiquetaPeriodo(c.k, grain),
              values: [c.financedUsd],
              note: `${c.orders} financiamientos · ${formatUsdShort(c.cumFinancedUsd)} acumulado sin fee`,
            }))}
            format={formatUsd}
            formatShort={formatUsdShort}
            ejeLabel={mayuscula(unidad.uno)}
            unidadLabel="Financiamientos y acumulado"
            footnote={`Sin el service fee: lo financiado a la cohorte en cada periodo.${enCurso}`}
            empty="Esta cohorte todavía no se ha financiado."
          />
        )}
      </Seccion>
    </div>
  )
}

/** La frase que resume la cohorte, con sus números dentro. */
function frase(fila: CohortRow, grain: CohortGrain): string {
  const unidad = UNIDAD[grain]

  if (fila.everActive === 0) {
    return `Ninguno de los ${fila.size} que entraron ${enFecha(fila.start, grain)} se ha financiado todavía.`
  }

  const primero = fila.cells.find((c) => c.k === 0)
  const siguiente = fila.cells.find((c) => c.k === 1)

  const trozos = [`${fila.everActive} de los ${fila.size} se han financiado alguna vez`]

  if (primero) trozos.push(`${primero.active} lo hicieron ${unidad.ese}`)
  if (siguiente) trozos.push(`y ${siguiente.active} se financiaron ${unidad.siguiente}`)

  return `${trozos.join(', ')}.`
}
