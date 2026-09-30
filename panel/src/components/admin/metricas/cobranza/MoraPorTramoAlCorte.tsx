import { Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { Meter, formatUsd, formatNumero } from '@/components/ui'
import { SERIE } from '@/components/charts'
import { Cifra } from '@/components/admin/tableros/CifrasEnFila'
import { MarcaConGlobo } from '@/components/charts/lectura'
import { NumerosEnDetalles } from '@/components/admin/metricas/kit'
import { consultaResumenDeCobranza } from '@/features/admin/metricas/cobranza/api'
import { totalDeLosTramos } from '@/features/admin/metricas/cobranza/semana'
import type { TramoAlCorte } from '@/features/admin/metricas/cobranza/semana'
import { QUE_PASA_EN_EL_TRAMO, rotuloDeTramo, tramoVacio } from '@/features/admin/tramos'
import type { CortesDeTramo } from '@/features/admin/tramos'
import { Bloque, LineaDeDesglose, usuarios } from './piezas'

/**
 * La mora del corte de la semana, por los tramos que tienen consecuencia.
 *
 * Cada persona cae entera en el tramo de su cuota más atrasada (la misma
 * cuenta que el paso entre tramos y la cola de Por cobrar). Sale de la misma
 * lectura que «Vencido sin pagar», así que las dos cifras son la misma. Con la
 * semana en curso y todos los locales, cada tramo abre Por cobrar filtrada por
 * él; en otra semana o con un local, la cola de hoy ya no es esta foto.
 */
export function MoraPorTramoAlCorte({ semana, local }: { semana: string; local: string | null }) {
  const resumen = useQuery(consultaResumenDeCobranza(semana, local))

  return (
    <Bloque
      titulo="Vencido por tramo de atraso"
      info="Vencido en cartera al corte de la semana (su cierre, o ahora si está en curso), en dólares con fee, con cada paciente entero en el tramo de su cuota vencida más atrasada; los tramos suman el «Vencido en cartera» de arriba."
      consulta={resumen}
      filas={5}
    >
      {(r) => {
        const total = totalDeLosTramos(r.tramos)
        if (!r.cortes) {
          return (
            <p className="type-panel-body text-on-surface-variant">
              Faltan los cortes de los tramos: se ponen en Ajustes › Parámetros.
            </p>
          )
        }
        if (total.personas === 0) {
          return <p className="type-panel-body text-on-surface-variant">Nadie tenía cuotas vencidas.</p>
        }
        const enlazar = local === null && r.semana?.enCurso === true
        const cortes = r.cortes
        const visibles = r.tramos.filter((t) => !tramoVacio(t.tramo, cortes))
        return (
          <div className="flex flex-col gap-4">
            <p className="-mt-2 flex flex-col gap-0.5 type-panel-body text-on-surface-variant">
              <span>
                <Cifra>{formatUsd(total.vencido.payableUsd)}</Cifra> vencido · {usuarios(total.personas)}
              </span>
              <LineaDeDesglose desglose={total.vencido} />
            </p>
            <ul className="flex flex-col gap-1">
              {visibles.map((t) => (
                <li key={t.tramo}>
                  {enlazar ? (
                    // El enlace lleva el foco; el globo sale igual al enfocarlo.
                    <MarcaConGlobo {...globoDelTramo(t, cortes)} como="div" enfocable={false}>
                      <Link
                        to="/admin/cobranza"
                        search={{ tramo: t.tramo }}
                        className="-mx-2 block rounded-panel-control px-2 py-1.5 transition-colors duration-[var(--transition-fast)] hover:bg-panel-raised"
                      >
                        <FilaDeTramo tramo={t} cortes={cortes} total={total.vencido.payableUsd} />
                      </Link>
                    </MarcaConGlobo>
                  ) : (
                    <MarcaConGlobo {...globoDelTramo(t, cortes)} como="div" className="py-1.5">
                      <FilaDeTramo tramo={t} cortes={cortes} total={total.vencido.payableUsd} />
                    </MarcaConGlobo>
                  )}
                </li>
              ))}
            </ul>
            <NumerosEnDetalles
              cabeceras={[
                'Tramo',
                'Pacientes',
                'Cuotas',
                'Vencido (con fee)',
                'Financiado (sin fee)',
                'Service fee + IVA',
                'Atraso medio (días)',
              ]}
              filas={visibles.map((t) => ({
                clave: t.tramo,
                celdas: [
                  rotuloDeTramo(t.tramo, cortes),
                  t.personas,
                  t.cuotas,
                  formatUsd(t.vencido.payableUsd),
                  formatUsd(t.vencido.financedUsd),
                  formatUsd(t.vencido.feeUsd),
                  t.diasAtrasoMedio === null ? '—' : `${formatNumero(t.diasAtrasoMedio)} d`,
                ],
              }))}
            />
          </div>
        )
      }}
    </Bloque>
  )
}

/**
 * Lo que dice el globo de un tramo: lo vencido con sus dos partes, la gente,
 * las cuotas y el atraso medio, y debajo qué le pasa a quien está en él.
 */
function globoDelTramo(t: TramoAlCorte, cortes: CortesDeTramo) {
  return {
    titulo: rotuloDeTramo(t.tramo, cortes),
    filas: [
      { key: 'vencido', rotulo: 'vencido (con fee)', valor: formatUsd(t.vencido.payableUsd), color: SERIE.principal },
      { key: 'consumo', rotulo: 'financiado (sin fee)', valor: formatUsd(t.vencido.financedUsd), color: SERIE.contexto },
      { key: 'fee', rotulo: 'service fee + IVA', valor: formatUsd(t.vencido.feeUsd), color: SERIE.contexto },
      { key: 'personas', rotulo: t.personas === 1 ? 'paciente' : 'pacientes', valor: String(t.personas), color: SERIE.tenue },
      { key: 'cuotas', rotulo: t.cuotas === 1 ? 'cuota' : 'cuotas', valor: String(t.cuotas), color: SERIE.tenue },
      ...(t.diasAtrasoMedio === null
        ? []
        : [
            {
              key: 'atraso',
              rotulo: 'de atraso medio',
              valor: `${formatNumero(t.diasAtrasoMedio)} d`,
              color: SERIE.tenue,
            },
          ]),
    ],
    nota: QUE_PASA_EN_EL_TRAMO[t.tramo],
  }
}

function FilaDeTramo({ tramo: t, cortes, total }: { tramo: TramoAlCorte; cortes: CortesDeTramo; total: number }) {
  const rotulo = rotuloDeTramo(t.tramo, cortes)
  const hay = t.vencido.payableUsd > 0
  return (
    <span className="flex flex-col gap-1.5">
      <span
        className={`flex items-baseline justify-between gap-4 type-panel-label ${hay ? 'text-on-surface' : 'text-panel-muted'}`}
      >
        <span>{rotulo}</span>
        <span className="font-normal tabular-nums">
          {formatUsd(t.vencido.payableUsd)} · {hay ? usuarios(t.personas) : 0}
        </span>
      </span>
      <Meter valor={t.vencido.payableUsd} max={total} rotulo={`${rotulo}: ${formatUsd(t.vencido.payableUsd)}`} />
      {/* Cada importe es una suma de cuotas: va con sus dos partes. */}
      {hay && <LineaDeDesglose desglose={t.vencido} className="text-right" />}
    </span>
  )
}
