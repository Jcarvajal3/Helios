import { Link, useNavigate } from '@tanstack/react-router'

import { DataTable, ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { Button, Card, Meter, Seccion, formatUsd, formatPorcentaje } from '@/components/ui'
import { SERIE } from '@/components/charts'
import { MarcaConGlobo } from '@/components/charts/lectura'
import { hayCargos, localesDe } from '@/features/admin/porCobrar'
import type { LocalPorCobrar, PorCobrar } from '@/features/admin/porCobrar'
import { diaConNombre } from '@/features/admin/semana'
import { csvDinero } from '@/lib/csv'
import { QUE_ES, ROTULOS } from './Sumandos'

/**
 * Lo que corresponde a cada local: de la semana entera o del día elegido en
 * el gráfico, de mayor a menor total. La fila abre la ficha del local.
 *
 * La columna Total existe solo porque a su lado están sus sumandos, y por eso
 * el consumo y el service fee no se pueden ocultar (`fija`): un total con el
 * fee dentro no se queda nunca solo.
 */
export function PorLocal({
  datos,
  dia,
  lunes,
  onDia,
}: {
  datos: PorCobrar
  dia: string | null
  lunes: string
  onDia: (dia: string | null) => void
}) {
  const navigate = useNavigate()
  const filas = localesDe(datos, dia)
  const suma = filas.reduce((s, f) => s + f.totalUsd, 0)
  const columnas = columnasPorLocal(
    hayCargos(datos),
    suma,
    dia === null ? 'la semana' : 'ese día',
    datos.incluyePagadas,
  )

  return (
    <Seccion
      titulo={dia === null ? 'Por clínica, toda la semana' : `Por clínica, el ${diaConNombre(dia)}`}
      info="Lo que corresponde a cada clínica: las cuotas de los financiamientos hechos en él. Un paciente que debe en dos clínicas cuenta en los dos."
      controles={
        dia !== null && (
          <Button variant="text" size="sm" onClick={() => onDia(null)}>
            Toda la semana
          </Button>
        )
      }
    >
      {filas.length === 0 ? (
        <Card>
          <p className="type-panel-body text-on-surface-variant">
            {dia === null ? 'Ninguna clínica tiene cuotas que venzan esta semana.' : 'Ese día no vence nada.'}
          </p>
        </Card>
      ) : (
        <DataTable
          rows={filas}
          rowKey={(f) => f.localId}
          columns={columnas}
          noun={['clínica', 'clínicas']}
          exportar={{ archivo: `por-cobrar-${dia ?? lunes}` }}
          onRowClick={(f) => void navigate({ to: '/admin/clinicas/$id', params: { id: f.localId } })}
        />
      )}
    </Seccion>
  )
}

/**
 * Las columnas. Los cargos por atraso solo cuando los hay; el reparto de cada
 * local, como una barrita bajo su total, medido contra la suma de la tabla.
 */
function columnasPorLocal(
  conCargos: boolean,
  suma: number,
  deQue: string,
  /** Con «Todo lo que vence» el total es «Total a cobrar»; si no, «Por cobrar». */
  incluyePagadas: boolean,
): Array<Column<LocalPorCobrar>> {
  const rotuloTotal = incluyePagadas ? 'total a cobrar' : 'por cobrar'
  const dinero = (
    key: 'consumo' | 'comision' | 'cargos',
    valor: (f: LocalPorCobrar) => number,
  ): Column<LocalPorCobrar> => ({
    key,
    header: ROTULOS[key],
    type: 'number',
    info: QUE_ES[key],
    fija: true,
    sort: valor,
    sortDir: 'desc',
    csv: (f) => csvDinero(valor(f)),
    cell: (f) => <span className="text-on-surface-variant">{formatUsd(valor(f))}</span>,
  })

  return [
    {
      key: 'local',
      header: 'Clínica',
      identity: true,
      sort: (f) => f.local,
      csv: (f) => f.local,
      cell: (f) => (
        <Link to="/admin/clinicas/$id" params={{ id: f.localId }} className={ENLACE_EN_CELDA}>
          {f.local}
        </Link>
      ),
    },
    {
      key: 'cuotas',
      header: 'Cuotas',
      type: 'number',
      sort: (f) => f.cuotas,
      sortDir: 'desc',
      csv: (f) => f.cuotas,
      cell: (f) => f.cuotas,
    },
    {
      key: 'personas',
      header: 'Pacientes',
      type: 'number',
      info: 'Pacientes distintos con cuotas de esa clínica.',
      sort: (f) => f.personas,
      sortDir: 'desc',
      csv: (f) => f.personas,
      cell: (f) => f.personas,
    },
    dinero('consumo', (f) => f.consumoUsd),
    dinero('comision', (f) => f.comisionUsd),
    ...(conCargos ? [dinero('cargos', (f) => f.cargosUsd)] : []),
    {
      key: 'total',
      header: incluyePagadas
        ? 'Total a cobrar (financiado + service fee + IVA)'
        : 'Por cobrar (financiado + service fee + IVA)',
      type: 'number',
      info: `La suma de las columnas de al lado: el financiado (sin fee), el service fee + IVA y, si hay, los cargos por atraso. La barrita es la parte del total de ${deQue} que corresponde a esa clínica.`,
      fija: true,
      sort: (f) => f.totalUsd,
      sortDir: 'desc',
      csv: (f) => csvDinero(f.totalUsd),
      cell: (f) => {
        const parte = suma > 0 ? f.totalUsd / suma : 0
        return (
          <MarcaConGlobo
            como="div"
            titulo={f.local}
            filas={[
              {
                key: 'parte',
                rotulo: `del total de ${deQue}`,
                valor: formatPorcentaje(parte * 100),
                color: SERIE.principal,
              },
              { key: 'total', rotulo: rotuloTotal, valor: formatUsd(f.totalUsd), color: SERIE.contexto },
              { key: 'consumo', rotulo: 'financiado (sin fee)', valor: formatUsd(f.consumoUsd), color: SERIE.tenue },
              { key: 'fee', rotulo: 'service fee + IVA', valor: formatUsd(f.comisionUsd), color: SERIE.tenue },
              ...(f.cargosUsd > 0
                ? [{ key: 'cargos', rotulo: 'cargos por atraso', valor: formatUsd(f.cargosUsd), color: SERIE.tenue }]
                : []),
            ]}
            className="inline-flex flex-col items-end gap-1.5"
          >
            <span className="font-semibold">{formatUsd(f.totalUsd)}</span>
            <span className="inline-flex items-center gap-1.5">
              <span className="type-panel-caption tabular-nums text-on-surface-variant">
                {formatPorcentaje(parte * 100)}
              </span>
              <Meter
                valor={parte}
                rotulo={`${formatPorcentaje(parte * 100)} del total de ${deQue}`}
                className="w-16"
              />
            </span>
          </MarcaConGlobo>
        )
      },
    },
  ]
}
