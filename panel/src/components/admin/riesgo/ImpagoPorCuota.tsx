import { useNavigate } from '@tanstack/react-router'

import { Segmented, Stat, StatGrid, formatDayShort, formatUsd, formatPct, sumarDias } from '@/components/ui'
import type { EstadoCifra } from '@/components/ui'
import { Ring } from '@/components/charts'
import { DataTable } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { PctConUmbral } from '@/components/admin/tableros/PctConUmbral'
import { pctDeUmbral } from '@/components/admin/tableros/senales'
import { rotuloDeMes } from '@/features/admin/riesgo/cosechas'
import { queEsLaCifraDeCobranza } from '@/features/admin/catalogo/metricas/cobranza'
import {
  CUOTAS,
  DIMENSIONES_PRIMERA_CUOTA,
  filaDeLaMismaClave,
  impagoDeLaCuota2,
  otraCuota,
} from '@/features/admin/riesgo/credito'
import type {
  CifrasPrimeraCuota,
  CifrasTrasPagarLaAnterior,
  DimensionPrimeraCuota,
  FilaPrimeraCuota,
  NumeroDeCuota,
  PrimeraCuota as Datos,
} from '@/features/admin/riesgo/credito'
import type { Parametros } from '@/features/admin/parametros'
import { senalPorUmbral, umbralImpago } from '@/features/admin/umbrales'
import type { Umbral } from '@/features/admin/umbrales'
import { useParametros } from '@/features/admin/useParametros'
import { csvDinero } from '@/lib/csv'
import { Bloque } from './Bloque'
import type { ConsultaDeBloque } from './Bloque'

const OPCIONES_CUOTA = CUOTAS.map((c) => ({ value: String(c) as `${NumeroDeCuota}`, label: `Cuota ${c}` }))

/** Qué es la cifra, dicho para la cuota que se mira. */
function queEs(cuota: NumeroDeCuota): string {
  const quien =
    cuota === 1
      ? 'la cuota 1 de cada paciente en cada financiamiento, la señal más temprana de crédito mal dado'
      : 'la cuota 2 de cada paciente en cada financiamiento (vence una semana después de la 1), también de quien no pagó la 1; «de quien pagó la 1» deja solo a quien ya la había pagado'
  return `Cuotas sin pagar (sin pago reportado) el último día de la gracia ÷ cuotas con la gracia terminada, contadas por número de cuotas, de los financiamientos de los seis meses naturales que acaban en el de la semana elegida (hasta su domingo): ${quien}. Los importes son financiado, sin la Comisión Helios.`
}

/** La explicación de la sección, con la nota del nivel cuando se parte por nivel. */
function explicacion(cuota: NumeroDeCuota, d: Datos | undefined): string {
  const base = d?.baseDelNivel
  if (!base || base.historial + base.actual === 0) return queEs(cuota)
  return `${queEs(cuota)} El nivel es el que tenía cada paciente al financiarse. En ${base.actual} de las ${base.historial + base.actual} cuotas no había historial de cambios de nivel y se usó el nivel de hoy, que para esos pacientes es el mismo.`
}

function columnas(
  d: Datos,
  otra: Datos | undefined,
  p: Parametros | undefined,
): Array<Column<FilaPrimeraCuota>> {
  const la = otraCuota(d.cuota)
  const rotulo = (r: FilaPrimeraCuota) =>
    d.dimension === 'mes'
      ? rotuloDeMes(r.clave)
      : d.dimension === 'semana'
        ? `Del ${formatDayShort(r.clave)} al ${formatDayShort(sumarDias(r.clave, 6))}`
        : r.rotulo
  const deLaOtra = (r: FilaPrimeraCuota) => filaDeLaMismaClave(otra, r.clave)?.impagoPct ?? null
  // «De quien pagó la cuota 1, qué parte no paga la 2», fila a fila: sale de
  // la cuota 2, sea la elegida o la de al lado.
  const cuota2 = impagoDeLaCuota2(d, otra)
  const tras = (r: FilaPrimeraCuota): CifrasTrasPagarLaAnterior | null =>
    filaDeLaMismaClave(cuota2, r.clave)?.trasPagarLaAnterior ?? null
  const nombreTras = d.cuota === 2 ? 'Sin pagar, de quien pagó la cuota 1 (%)' : 'Cuota 2 sin pagar, de quien pagó la 1 (%)'
  const columnaTras: Column<FilaPrimeraCuota> = {
    key: 'tras-pagar-la-1',
    header: nombreTras,
    type: 'number',
    info: 'Cuotas 2 sin pagar al terminar su gracia ÷ cuotas 2 con la gracia terminada, contando solo a quien ya había pagado la cuota 1 del mismo financiamiento ese día; «—» si nadie así tiene todavía la gracia de la 2 terminada.',
    cell: (r) =>
      cuota2 === undefined ? (
        <span className="text-panel-muted">…</span>
      ) : (
        <PctConUmbral valor={tras(r)?.impagoPct ?? null} umbral={umbralImpago(p)} />
      ),
    sort: (r) => tras(r)?.impagoPct ?? null,
    sortDir: 'desc',
    csv: (r) => tras(r)?.impagoPct ?? null,
  }
  const columnaOtra: Column<FilaPrimeraCuota> = {
    key: 'otra',
    header: `Cuota ${la} sin pagar al terminar la gracia (%)`,
    type: 'number',
    info: `Lo mismo para la cuota ${la} de los mismos financiamientos, para leer las dos lado a lado; «—» si ninguna ha terminado la gracia.`,
    cell: (r) =>
      otra === undefined ? (
        <span className="text-panel-muted">…</span>
      ) : (
        <PctConUmbral valor={deLaOtra(r)} umbral={umbralImpago(p)} />
      ),
    sort: deLaOtra,
    sortDir: 'desc',
    csv: deLaOtra,
  }
  return [
    {
      key: 'rotulo',
      header: DIMENSIONES_PRIMERA_CUOTA.find((x) => x.value === d.dimension)?.label ?? 'Grupo',
      identity: true,
      cell: rotulo,
      csv: rotulo,
    },
    {
      key: 'maduras',
      header: 'Cuotas con la gracia terminada',
      type: 'number',
      info: `Cuotas ${d.cuota} que ya pasaron los ${d.diasDeGracia} días de gracia: el denominador del porcentaje.`,
      cell: (r) => r.maduras,
      sort: (r) => r.maduras,
      sortDir: 'desc',
      csv: (r) => r.maduras,
    },
    {
      key: 'impago',
      header: 'Sin pagar al terminar la gracia (%)',
      type: 'number',
      info: `Cuotas ${d.cuota} sin pago reportado el último día de la gracia ÷ cuotas ${d.cuota} con la gracia terminada, por número de cuotas.`,
      cell: (r) => <PctConUmbral valor={r.impagoPct} umbral={umbralImpago(p)} />,
      sort: (r) => r.impagoPct,
      sortDir: 'desc',
      csv: (r) => r.impagoPct,
    },
    // Mirando la 2, primero la suya de quien pagó la 1 y luego la 1; mirando
    // la 1, la 2 entera y luego la de quien pagó la 1.
    ...(d.cuota === 2 ? [columnaTras, columnaOtra] : [columnaOtra, columnaTras]),
    {
      key: 'monto',
      header: 'Financiado sin pagar (sin comisión)',
      type: 'number',
      info: 'Financiado (sin comisión) de las cuotas sin pagar al terminar la gracia.',
      cell: (r) => formatUsd(r.impagasMonto),
      sort: (r) => r.impagasMonto,
      sortDir: 'desc',
      csv: (r) => csvDinero(r.impagasMonto),
    },
    {
      key: 'impago30',
      header: `Sin pagar a los ${d.diasTarde} días (%)`,
      type: 'number',
      info: `Cuotas sin pagar a los ${d.diasTarde} días del vencimiento ÷ cuotas con ${d.diasTarde} días cumplidos: la vara estándar del crédito.`,
      cell: (r) => <PctConUmbral valor={r.impago30Pct} umbral={umbralImpago(p)} />,
      sort: (r) => r.impago30Pct,
      sortDir: 'desc',
      csv: (r) => r.impago30Pct,
    },
    {
      key: 'tras-pagar-la-1-30',
      header: `${nombreTras.replace(' (%)', '')}, a los ${d.diasTarde} días (%)`,
      type: 'number',
      hidden: true,
      cell: (r) =>
        cuota2 === undefined ? (
          <span className="text-panel-muted">…</span>
        ) : (
          <PctConUmbral valor={tras(r)?.impago30Pct ?? null} umbral={umbralImpago(p)} />
        ),
      sort: (r) => tras(r)?.impago30Pct ?? null,
      sortDir: 'desc',
      csv: (r) => tras(r)?.impago30Pct ?? null,
    },
    {
      key: 'monto30',
      header: `Financiado sin pagar a los ${d.diasTarde} días (sin comisión)`,
      type: 'number',
      hidden: true,
      cell: (r) => formatUsd(r.impagas30Monto),
      sort: (r) => r.impagas30Monto,
      sortDir: 'desc',
      csv: (r) => csvDinero(r.impagas30Monto),
    },
    {
      key: 'gracia',
      header: 'Cuotas todavía en la gracia',
      type: 'number',
      info: `Cuotas ${d.cuota} que todavía no han terminado la gracia: no entran en ningún porcentaje.`,
      cell: (r) => r.enGracia,
      sort: (r) => r.enGracia,
      csv: (r) => r.enGracia,
    },
  ]
}

/**
 * El impago de una cuota tras la gracia: de la 1, la señal más temprana de
 * que se le dio crédito a quien no debía; de la 2, si quien pagó una sigue
 * pagando. Las dos tienen lo mismo, y se elige cuál con el Segmented «Cuota»
 * de la cabecera; la otra sale al lado, en su columna y en el pie de las
 * cifras, para leerlas juntas.
 *
 * Arriba, el total de los seis meses con su anillo; debajo, partido por lo
 * que se elija en «Partido por». Las consultas llegan hechas (Métricas las
 * pide con su semana y su local): este bloque solo las pinta.
 */
export function ImpagoPorCuota({
  cuota,
  onCambiarCuota,
  dimension,
  onCambiarDimension,
  consulta,
  otra,
}: {
  cuota: NumeroDeCuota
  onCambiarCuota: (c: NumeroDeCuota) => void
  dimension: DimensionPrimeraCuota
  onCambiarDimension: (d: DimensionPrimeraCuota) => void
  /** El impago de la cuota elegida. */
  consulta: ConsultaDeBloque<Datos>
  /** El de la otra cuota, con la misma dimensión: para compararla. */
  otra: { data: Datos | undefined; isError?: boolean; refetch?: () => unknown }
}) {
  const navigate = useNavigate()
  const parametros = useParametros()

  return (
    <Bloque
      titulo={`Cuota ${cuota} sin pagar al terminar la gracia`}
      info={explicacion(cuota, consulta.data)}
      consulta={consulta}
      filas={5}
      aside={
        <div className="flex flex-wrap items-center gap-2">
          <Segmented
            etiqueta="Cuota"
            options={OPCIONES_CUOTA}
            value={`${cuota}`}
            onChange={(c) => onCambiarCuota(c === '2' ? 2 : 1)}
          />
          <Segmented
            etiqueta="Partido por"
            options={[...DIMENSIONES_PRIMERA_CUOTA]}
            value={dimension}
            onChange={onCambiarDimension}
          />
        </div>
      }
    >
      {(d) => {
        // Mientras llega la otra con la dimensión nueva, la de antes no vale:
        // sus claves son de otra cosa. Y tiene que ser la otra cuota.
        const laOtra =
          otra.data?.dimension === d.dimension && otra.data.cuota !== d.cuota ? otra.data : undefined
        return (
          <div className="flex flex-col gap-4">
            <Totales
              cuota={d.cuota}
              total={d.total}
              otra={laOtra}
              cuota2={impagoDeLaCuota2(d, laOtra)}
              estadoCuota2={
                d.cuota === 2 || laOtra !== undefined ? 'listo' : otra.isError ? 'error' : 'cargando'
              }
              onReintentarCuota2={otra.refetch ? () => void otra.refetch?.() : undefined}
              diasTarde={d.diasTarde}
              umbral={umbralImpago(parametros.data)}
            />
            <DataTable
              rows={d.filas}
              rowKey={(r) => r.clave}
              columns={columnas(d, laOtra, parametros.data)}
              noun={['fila', 'filas']}
              exportar={{ archivo: `impago-cuota-${d.cuota}-por-${d.dimension}` }}
              onRowClick={
                d.dimension === 'local'
                  ? (r) => void navigate({ to: '/admin/clinicas/$id', params: { id: r.clave } })
                  : undefined
              }
            />
          </div>
        )
      }}
    </Bloque>
  )
}

/**
 * Las cuatro cifras del total: las proporciones con su anillo y lo que no
 * volvió. Todas con los cortes del impago, como en Inicio: el mismo
 * porcentaje no puede tener dos colores en dos pantallas. El pie de cada
 * proporción dice la de la otra cuota, para compararlas sin cambiar de vista,
 * y «de quien pagó la 1» sale se mire la cuota que se mire.
 */
function Totales({
  cuota,
  total,
  otra,
  cuota2,
  estadoCuota2,
  onReintentarCuota2,
  diasTarde,
  umbral,
}: {
  cuota: NumeroDeCuota
  total: CifrasPrimeraCuota
  otra: Datos | undefined
  /** El impago de la cuota 2, la elegida o la de al lado. */
  cuota2: Datos | undefined
  estadoCuota2: EstadoCifra
  onReintentarCuota2?: () => void
  diasTarde: number
  umbral: Umbral | null
}) {
  const senalGracia = senalPorUmbral(total.impagoPct, umbral, pctDeUmbral)
  const senalTarde = senalPorUmbral(total.impago30Pct, umbral, pctDeUmbral)
  const meta = umbral ? umbral.alerta / 100 : undefined
  const pct = (v: number | null) => (v === null ? '—' : formatPct(v))
  const la = otraCuota(cuota)
  // «· cuota 2: 12,0 %», solo cuando la otra ya se leyó y tiene veredicto.
  const frente = (v: number | null | undefined) => (v == null ? '' : ` · cuota ${la}: ${formatPct(v)}`)
  const tras = cuota2?.total.trasPagarLaAnterior ?? null
  const senalTras = senalPorUmbral(tras?.impagoPct ?? null, umbral, pctDeUmbral)
  // La cuota 2 entera al lado, para ver cuánto pesa quien nunca pagó la 1.
  const todaLa2 = cuota2?.total.impagoPct == null ? '' : ` · toda la cuota 2: ${formatPct(cuota2.total.impagoPct)}`

  return (
    <StatGrid cols={4}>
      <Stat
        label={`Cuota ${cuota} sin pagar al terminar la gracia, 6 meses (%)`}
        value={pct(total.impagoPct)}
        senal={senalGracia}
        hint={
          total.maduras === 0
            ? `Ninguna cuota ${cuota} ha terminado la gracia${frente(otra?.total.impagoPct)}`
            : `${total.impagas} de ${total.maduras} cuotas con la gracia terminada${frente(otra?.total.impagoPct)}`
        }
        lateral={
          <Ring
            valor={total.impagoPct === null ? null : total.impagoPct / 100}
            meta={meta}
            tono={senalGracia?.tone ?? 'area'}
            rotulo={`Cuota ${cuota} sin pagar al terminar la gracia: ${pct(total.impagoPct)}`}
          />
        }
      />
      <Stat
        label="Cuota 2 sin pagar, de quien pagó la 1 (%)"
        value={pct(tras?.impagoPct ?? null)}
        info={queEsLaCifraDeCobranza('impago-segunda-cuota-de-quien-pago-la-primera')}
        estado={estadoCuota2}
        onReintentar={onReintentarCuota2}
        senal={senalTras}
        hint={
          tras === null
            ? undefined
            : tras.maduras === 0
              ? `Nadie que pagó la 1 tiene todavía la gracia de la 2 terminada${todaLa2}`
              : `${tras.impagas} de ${tras.maduras} que pagaron la 1${todaLa2}`
        }
        lateral={
          <Ring
            valor={tras?.impagoPct == null ? null : tras.impagoPct / 100}
            meta={meta}
            tono={senalTras?.tone ?? 'area'}
            rotulo={`Cuota 2 sin pagar, de quien pagó la 1: ${pct(tras?.impagoPct ?? null)}`}
          />
        }
      />
      <Stat
        label={`Cuota ${cuota} sin pagar a los ${diasTarde} días (%)`}
        value={pct(total.impago30Pct)}
        senal={senalTarde}
        hint={
          total.maduras30 === 0
            ? `Ninguna ha cumplido ${diasTarde} días${frente(otra?.total.impago30Pct)}`
            : `${total.impagas30} de ${total.maduras30} cuotas${frente(otra?.total.impago30Pct)}`
        }
        lateral={
          <Ring
            valor={total.impago30Pct === null ? null : total.impago30Pct / 100}
            meta={meta}
            tono={senalTarde?.tone ?? 'area'}
            rotulo={`Cuota ${cuota} sin pagar a los ${diasTarde} días: ${pct(total.impago30Pct)}`}
          />
        }
      />
      <Stat
        label="Financiado sin pagar al terminar la gracia (sin comisión)"
        value={formatUsd(total.impagasMonto)}
        info="Financiado (sin comisión) de las cuotas que seguían sin pagar el último día de la gracia, en los seis meses."
        hint={
          total.enGracia > 0
            ? `${total.enGracia} ${total.enGracia === 1 ? 'cuota sigue' : 'cuotas siguen'} en la gracia`
            : 'Al terminar la gracia'
        }
      />
    </StatGrid>
  )
}
