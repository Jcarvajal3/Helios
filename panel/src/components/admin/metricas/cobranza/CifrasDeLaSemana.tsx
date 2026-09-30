import { useQuery } from '@tanstack/react-query'

import { Meter, Stat, estadoDeConsulta, estadoDeConsultas, formatDayShort, formatUsd, formatPct } from '@/components/ui'
import { marcasDeUmbral, pctDeUmbral, senalDelImpago, topeDelMedidor } from '@/components/admin/tableros/senales'
import { comoTendencia, delta } from '@/features/admin/metricas/formato'
import {
  consultaCobroATiempo,
  consultaImpagoPorSemana,
  consultaResumenDeCobranza,
} from '@/features/admin/metricas/cobranza/api'
import {
  pieDeCobroATiempo,
  pieDelImpago,
  semanaJuzgadaDelImpago,
  tramoJuzgado,
} from '@/features/admin/metricas/cobranza/semana'
import type { NumeroDeCuota } from '@/features/admin/riesgo/credito'
import {
  senalPorUmbral,
  senalPorUmbralAlto,
  umbralCobroATiempo,
  umbralImpago,
  umbralMora,
} from '@/features/admin/umbrales'
import { useParametros } from '@/features/admin/useParametros'
import { LineaDeDesglose, usuarios } from './piezas'

/**
 * Las seis cifras de arriba de Cobranza y riesgo, en dos filas: la cartera
 * (lo vencido, la mora y el impago sobre lo financiado) y cómo se pagan las
 * cuotas (la 1 y la 2 sin pagar tras la gracia, y el cobro a tiempo). Cada
 * una con el corte que le da color (un `umbral_*` de los parámetros) y nada
 * más: la pastilla solo sale al cruzarlo.
 *
 * Lo vencido y la mora son los del CORTE de la semana (su cierre, o ahora si
 * está en curso) y se comparan con la semana anterior a la misma altura. El
 * impago es desde el primer día: no es de ninguna semana.
 */
export function CifrasDeLaSemana({
  semana,
  domingo,
  local,
  enlaceAPrimeraCuota,
}: {
  semana: string
  domingo: string
  local: string | null
  /** La búsqueda de la sub-vista del impago por cuota, con la semana y el local de ahora. */
  enlaceAPrimeraCuota: { semana?: string; local?: string }
}) {
  const parametros = useParametros()
  const resumen = useQuery(consultaResumenDeCobranza(semana, local))
  const cobro = useQuery(consultaCobroATiempo(domingo, local))

  const r = resumen.data
  const estadoResumen = estadoDeConsulta(resumen)
  const reintentarResumen = () => void resumen.refetch()

  // 1. Lo vencido al corte, con su desglose.
  const vencido = r?.cartera.vencido
  const deltaVencido = r ? delta(r.cartera.vencido.payableUsd, r.anterior.vencido.payableUsd, { tipo: 'relativo', arribaEsBueno: false }) : null
  const corteEscrito = r ? (r.semana?.enCurso ? 'Ahora' : `Al cierre del domingo ${formatDayShort(r.corte)}`) : ''

  // 2. La mora.
  const mora = r?.cartera.moraPct ?? null
  const umbral = umbralMora(parametros.data)
  const deltaMora = r ? delta(mora, r.anterior.moraPct, { tipo: 'puntos', arribaEsBueno: false }) : null

  // 3. Los cortes del impago: los del impago sobre lo financiado, y los mismos
  //    que usa cada tarjeta de cuota (`ImpagoDeLaCuota`, una por cuota).
  const umbralDelImpago = umbralImpago(parametros.data)

  // 4. El cobro a tiempo.
  const c = cobro.data
  const aTiempo = c?.total.pct ?? null
  const metaATiempo = umbralCobroATiempo(parametros.data)
  const juzgado = c ? tramoJuzgado(c, semana, domingo) : null

  // 5. El impago desde el inicio, con el punto de empate.
  const impago = r?.impago.pct ?? null
  const empate = r?.impago.empatePct ?? null

  return (
    <div className="@container">
      <div className="grid grid-cols-1 gap-4 @xl:grid-cols-2 @4xl:grid-cols-3">
        <Stat
          label="Vencido en cartera"
          value={vencido ? formatUsd(vencido.payableUsd) : ''}
          trend={deltaVencido ? comoTendencia(deltaVencido) : undefined}
          visual={vencido && <LineaDeDesglose desglose={vencido} />}
          hint={r ? `${usuarios(r.cartera.personasVencidas)} · ${corteEscrito.toLowerCase()}` : undefined}
          info="Cuotas de todos los financiamientos (no solo los de esta semana) sin pagar y con el vencimiento pasado al corte de la semana (su cierre, o ahora si está en curso), sin lo perdido, en dólares con fee y su desglose; el cambio es frente al corte de la semana anterior a la misma altura."
          link={{ to: '/admin/cobranza', search: { tramo: 'plazo_vencido' } }}
          estado={estadoResumen}
          onReintentar={reintentarResumen}
        />
        <Stat
          label="Mora (%)"
          value={r ? (mora === null ? '—' : formatPct(mora)) : ''}
          senal={senalPorUmbral(mora, umbral, pctDeUmbral)}
          trend={deltaMora ? comoTendencia(deltaMora) : undefined}
          visual={
            mora !== null && (
              <Meter
                valor={mora}
                max={topeDelMedidor([mora, umbral?.critico])}
                tono={senalPorUmbral(mora, umbral, pctDeUmbral)?.tone ?? 'area'}
                marcas={marcasDeUmbral(umbral)}
                rotulo={`Mora: ${formatPct(mora)}`}
              />
            )
          }
          hint={r ? (mora === null ? 'No queda nada por cobrar' : corteEscrito) : undefined}
          info="Vencido ÷ (vencido + por vencer) de toda la cartera al corte de la semana, en dólares con fee y sin lo perdido; el cambio es en puntos frente a la semana anterior a la misma altura."
          estado={estadoResumen}
          onReintentar={reintentarResumen}
        />
        <Stat
          label="Perdido sobre lo financiado (%)"
          value={r ? (impago === null ? '—' : formatPct(impago)) : ''}
          senal={senalDelImpago(impago, empate, umbralDelImpago)}
          hint={r ? (empate === null ? 'Sin punto de empate todavía' : `Helios deja de ganar al ${formatPct(empate)}`) : undefined}
          info="Financiado (sin fee) de las cuotas dadas por perdidas ÷ todo lo financiado desde el primer día (no es de la semana); el punto de empate es el perdido a partir del cual Helios deja de ganar."
          estado={estadoResumen}
          onReintentar={reintentarResumen}
        />
        {([1, 2] as const).map((cuota) => (
          <ImpagoDeLaCuota
            key={cuota}
            cuota={cuota}
            semana={semana}
            domingo={domingo}
            local={local}
            enlace={enlaceAPrimeraCuota}
          />
        ))}
        <Stat
          label="Cuotas pagadas a tiempo (%)"
          value={c ? (aTiempo === null ? '—' : formatPct(aTiempo, 0)) : ''}
          senal={senalPorUmbralAlto(aTiempo, metaATiempo, pctDeUmbral)}
          hint={c ? pieDeCobroATiempo(c) : undefined}
          info={`Cuotas con vencimiento en la semana (y gracia ya terminada) pagadas con un pago registrado como tarde el vencimiento + ${c ? c.gracia : 'los'} días de gracia ÷ esas cuotas, contadas por número de cuotas y no por dólares.${juzgado ? ` Las de la semana elegida todavía no se pueden juzgar: ${juzgado.toLowerCase()}.` : ''}`}
          estado={estadoDeConsultas([cobro, parametros])}
          onReintentar={() => void cobro.refetch()}
        />
      </div>
    </div>
  )
}

/**
 * La cuota 1 o la 2 sin pagar tras la gracia, de la última semana de consumo
 * cuyas cuotas de ese número ya pasaron todas la gracia (hasta la elegida).
 * La de la cuota 2 suele ser una semana más vieja: vence una semana después.
 * La tarjeta lleva a «Impago por cuota» con esa cuota puesta.
 */
function ImpagoDeLaCuota({
  cuota,
  semana,
  domingo,
  local,
  enlace,
}: {
  cuota: NumeroDeCuota
  semana: string
  domingo: string
  local: string | null
  enlace: { semana?: string; local?: string }
}) {
  const parametros = useParametros()
  const impago = useQuery(consultaImpagoPorSemana(cuota, domingo, local))
  const fila = impago.data ? semanaJuzgadaDelImpago(impago.data, semana) : null
  const pct = fila?.impagoPct ?? null
  return (
    <Stat
      label={`Cuota ${cuota} sin pagar al terminar la gracia (%)`}
      value={impago.data ? (pct === null ? '—' : formatPct(pct, 0)) : ''}
      senal={senalPorUmbral(pct, umbralImpago(parametros.data), pctDeUmbral)}
      hint={impago.data ? pieDelImpago(fila, semana) : undefined}
      info={`Cuotas ${cuota} sin pagar el último día de la gracia ÷ cuotas ${cuota} con la gracia terminada, de los financiamientos de la última semana (hasta la elegida) cuyas cuotas ${cuota} ya la terminaron todas; por número de cuotas.`}
      link={{
        to: '/admin/metricas',
        search: { vista: 'cobros', sub: 'impago-por-cuota', ...(cuota === 2 ? { cuota: '2' as const } : {}), ...enlace },
      }}
      estado={estadoDeConsultas([impago, parametros])}
      onReintentar={() => void impago.refetch()}
    />
  )
}
