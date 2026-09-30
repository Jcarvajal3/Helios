import { BarraDeEstados } from '@/components/admin/metricas/cohortes/BarraDeEstados'
import { formatUsd, formatNumero } from '@/components/ui'
import { desgloseCorto, totalPorCobrar, tramoDeFila, vencidoCobrable } from '@/features/admin/cobranza/cartera'
import type { CollectionRow, PartesDeDeuda } from '@/features/admin/cobranza/cartera'
import { TRAMOS_VENCIDOS, rotuloDeTramo, tramoVacio } from '@/features/admin/tramos'
import type { CortesDeTramo, TramoVencido } from '@/features/admin/tramos'

type Clave = TramoVencido | 'por_vencer'

/**
 * Del atraso más largo al que todavía no vence: del rojo oscuro al gris. El
 * color de estado sale solo donde algo ESTÁ mal.
 */
const COLOR: Record<Clave, string> = {
  t5: 'var(--color-error-dim)',
  t4: 'var(--color-error)',
  t3: 'color-mix(in oklab, var(--color-error) 55%, var(--color-warning))',
  t2: 'var(--color-warning)',
  t1: 'color-mix(in oklab, var(--color-warning) 55%, var(--color-panel-muted))',
  por_vencer: 'color-mix(in oklab, var(--color-panel-muted) 55%, transparent)',
}

type Parte = { clave: Clave; rotulo: string; importe: number; partes: PartesDeDeuda | null; personas: number }

function sumarPartes(filas: ReadonlyArray<PartesDeDeuda | null>): PartesDeDeuda | null {
  let financedUsd = 0
  let feeUsd = 0
  for (const p of filas) {
    if (p === null) return null
    financedUsd += p.financedUsd
    feeUsd += p.feeUsd
  }
  return { financedUsd, feeUsd }
}

/**
 * Lo vencido por tramo de atraso (del más largo al más corto), sin lo dado
 * por perdido, y todo lo por vencer. Las partes suman el total por cobrar.
 */
export function partesDeLaCartera(filas: ReadonlyArray<CollectionRow>, cortes: CortesDeTramo): Parte[] {
  const vencidas: Parte[] = [...TRAMOS_VENCIDOS]
    .reverse()
    .filter((t) => !tramoVacio(t, cortes))
    .map((t) => {
      const del = filas
        .filter((f) => tramoDeFila(f, cortes) === t)
        .map(vencidoCobrable)
        .filter((v) => v.usd > 0)
      return {
        clave: t,
        rotulo: `${rotuloDeTramo(t, cortes)} de atraso`,
        importe: del.reduce((a, v) => a + v.usd, 0),
        partes: sumarPartes(del.map((v) => v.partes)),
        personas: del.length,
      }
    })
  const conPorVencer = filas.filter((f) => f.upcomingUsd > 0)
  return [
    ...vencidas,
    {
      clave: 'por_vencer',
      rotulo: 'Por vencer',
      importe: conPorVencer.reduce((a, f) => a + f.upcomingUsd, 0),
      partes: sumarPartes(conPorVencer.map((f) => f.upcomingDesglose)),
      personas: conPorVencer.length,
    },
  ]
}

/**
 * Cuánto hay por cobrar, en total, y cuánto lleva cuánto tiempo: una barra
 * con lo vencido por tramo de atraso y lo que queda por vencer, y debajo cada
 * parte con su importe, su desglose y cuánta gente. No filtra la lista.
 *
 * El total es el «Por cobrar» de Métricas › Global, la misma cifra con la
 * misma definición (Javier, 28-09): todo lo que queda sin pagar, sin lo dado
 * por perdido. Lo perdido sigue en la lista —se sigue cobrando— y se dice
 * aparte, debajo.
 *
 * Todo es lo que hay que cobrar, con el fee dentro y siempre partido en
 * consumo y fee (en cobranza el fee se cobra).
 */
export function BarraDeLaCartera({ filas, cortes }: { filas: ReadonlyArray<CollectionRow>; cortes: CortesDeTramo }) {
  const partes = partesDeLaCartera(filas, cortes)
  const t = totalPorCobrar(filas)

  return (
    // La caja de `Card`, escrita aquí para no perder el `aria-label` de la sección.
    <section
      aria-label="La cartera por atraso"
      className="@container mb-5 flex flex-col gap-3 rounded-panel-card border border-panel-hairline bg-panel-card p-panel-pad-card"
    >
      <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1">
        <span className="type-panel-figure tabular-nums text-on-surface">{formatUsd(t.usd)}</span>
        <span className="type-panel-body text-on-surface-variant">
          por cobrar de {formatNumero(t.personas, 0)} {t.personas === 1 ? 'paciente' : 'pacientes'}
        </span>
        {t.partes && <span className="type-panel-caption tabular-nums text-panel-muted">{desgloseCorto(t.partes)}</span>}
      </div>

      <BarraDeEstados
        tramos={partes.map((p) => ({
          clave: p.clave,
          rotulo: p.rotulo,
          valor: p.importe,
          personas: p.personas,
          desglose: p.partes ? { payableUsd: p.importe, ...p.partes } : undefined,
        }))}
        colores={COLOR}
        rotulo="Lo que hay por cobrar, por días de atraso"
        titulo="Por cobrar"
        total={t.partes ? { payableUsd: t.usd, ...t.partes } : undefined}
        alto="gruesa"
      />

      <ul className="grid grid-cols-2 gap-x-5 gap-y-2 @xl:grid-cols-3 @4xl:grid-cols-6">
        {partes.map((p) => (
          <li key={p.clave} className="flex min-w-0 flex-col gap-0.5">
            <span className="flex items-center gap-1.5 type-panel-caption text-on-surface-variant">
              <span aria-hidden className="size-2 shrink-0 rounded-[3px]" style={{ backgroundColor: COLOR[p.clave] }} />
              <span className="truncate">{p.rotulo}</span>
            </span>
            <span
              className={`type-panel-label tabular-nums ${p.importe > 0 ? 'text-on-surface' : 'text-panel-muted'}`}
            >
              {formatUsd(p.importe)}
            </span>
            <span className="type-panel-caption tabular-nums text-panel-muted">
              {p.personas} {p.personas === 1 ? 'paciente' : 'pacientes'}
              {p.partes && p.importe > 0 ? ` · ${desgloseCorto(p.partes)}` : ''}
            </span>
          </li>
        ))}
      </ul>

      {t.perdido.usd > 0 && (
        <p className="type-panel-caption text-panel-muted">
          Aparte, {formatUsd(t.perdido.usd)} dado por perdido de {t.perdido.personas}{' '}
          {t.perdido.personas === 1 ? 'paciente' : 'pacientes'}: sigue en la lista para cobrarlo, pero no cuenta como
          por cobrar.
        </p>
      )}
    </section>
  )
}
