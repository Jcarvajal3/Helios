import { useQuery } from '@tanstack/react-query'

import { BarChart } from '@/components/charts'
import {
  Card,
  NoSePudoLeer,
  Seccion,
  SkeletonTable,
  Table,
  Td,
  Tr,
  formatDay,
  formatDayShort,
  formatUsd,
  formatUsdShort,
} from '@/components/ui'
import { CajaAlFinal } from '@/components/admin/caja/ProyeccionDeCaja'
import { NoSeParte } from '@/components/admin/metricas/kit'
import { Cifra } from '@/components/admin/tableros/CifrasEnFila'
import { notaDeLoCobrado, repartirComoVencia } from '@/features/admin/metricas/caja/calculos'
import { consultaDeLaSemana } from '@/features/admin/metricas/caja/consultas'
import type { SemanaDeCaja } from '@/features/admin/metricas/caja/lectura'
import { MOTIVO_BANCO } from '@/features/admin/metricas/caja/textos'
import { textoDeDesglose } from '@/features/admin/metricas/formato'
import { SEMANAS_COMPARADAS, fetchProyectadoFrenteAReal } from '@/features/admin/proyeccionDeCaja'
import { desvioDelCobro } from '@/features/admin/proyectadoFrenteAReal'
import type { SemanaProyectadaYReal } from '@/features/admin/proyectadoFrenteAReal'
import { lunesDe } from '@/features/admin/semana'

const TITULO = 'Lo proyectado frente a lo que pasó'

const QUE_ES =
  'La proyección que se guardó cada lunes a las 10:30, frente a lo que después dijo el libro contable. Sirve para saber cuánto fiarse de la proyección de arriba: si el cobro se queda siempre por debajo, el cobro a tiempo que la multiplica es optimista. Lo cobrado del libro lleva dentro los cargos por atraso; lo esperado, no.'

/**
 * La proyección de cada lunes frente a lo que pasó: el cobro en barras (lo
 * cobrado dentro de lo esperado) y la tabla entera debajo.
 *
 * Lo esperado y lo cobrado son cuotas (con la Comisión Helios dentro), así que
 * dicen «(consumo + comisión)» y cada uno lleva sus partes en la tabla: lo
 * cobrado, las que dicen las cuotas de esa semana (y los cargos por atraso
 * aparte); lo esperado, repartido como lo que vencía esa semana, porque la
 * foto del lunes solo guarda el total. Cada barra enseña el globo del kit al
 * señalarla, con las dos cifras y, debajo, las partes de lo cobrado.
 *
 * Es de todo Ronda: con un local no se parte.
 */
export function ProyectadoFrenteAReal({ hoy, local }: { hoy: string; local: string | null }) {
  if (local) {
    return (
      <Seccion titulo={TITULO} info={QUE_ES}>
        <NoSeParte variante="bloque" motivo={MOTIVO_BANCO} />
      </Seccion>
    )
  }
  return <FrenteAReal hoy={hoy} />
}

function FrenteAReal({ hoy }: { hoy: string }) {
  const consulta = useQuery({
    queryKey: ['admin-forecast', 'frente-a-real', SEMANAS_COMPARADAS],
    queryFn: () => fetchProyectadoFrenteAReal(SEMANAS_COMPARADAS),
  })
  // Las mismas ocho semanas, con las partes de lo cobrado y de lo que vencía.
  const partes = useQuery(consultaDeLaSemana(lunesDe(hoy), null))

  if (consulta.isPending) {
    return (
      <Seccion titulo={TITULO} info={QUE_ES}>
        <SkeletonTable rows={3} columns={6} />
      </Seccion>
    )
  }

  if (consulta.isError) {
    return (
      <Seccion titulo={TITULO} info={QUE_ES}>
        <Card>
          <NoSePudoLeer onReintentar={() => void consulta.refetch()} />
        </Card>
      </Seccion>
    )
  }

  const d = consulta.data

  if (d.semanas.length === 0) {
    return (
      <Seccion titulo={TITULO} info={QUE_ES}>
        <Card>
          <p className="type-panel-body text-on-surface-variant">
            La primera proyección se guardará el lunes {formatDay(d.proximaFoto)} a las 10:30.
          </p>
        </Card>
      </Seccion>
    )
  }

  const desvio = desvioDelCobro(d.semanas)
  const porLunes = new Map((partes.data?.semanas ?? []).map((s) => [s.lunes, s]))

  return (
    <Seccion titulo={TITULO} info={QUE_ES}>
      <BarChart
        title="Cobro esperado y cobro real"
        summary={
          desvio === null ? (
            'La semana en curso todavía puede cambiar.'
          ) : Math.abs(desvio) < 0.005 ? (
            'En las semanas cerradas se cobró lo esperado.'
          ) : (
            <>
              En las semanas cerradas se cobró <Cifra>{formatUsd(Math.abs(desvio))}</Cifra>{' '}
              {desvio < 0 ? 'menos' : 'más'} de lo esperado
            </>
          )
        }
        series={[
          { key: 'esperado', label: 'Se esperaba cobrar (financiamiento + comisión)' },
          { key: 'cobrado', label: 'Cobrado según el libro (cuotas + cargos)' },
        ]}
        points={d.semanas.map((s) => ({
          key: s.weekStart,
          label: formatDayShort(s.weekStart),
          values: [s.proyectadoCobrarUsd, s.cobradoUsd],
          note: notaDeLoCobrado(porLunes.get(s.weekStart), !s.completa),
        }))}
        format={formatUsd}
        formatShort={formatUsdShort}
        ejeLabel="Semana"
        unidadLabel="Detalle"
        footnote="Lo esperado son cuotas: el financiamiento más la Comisión Helios. Lo cobrado es lo que el libro contable apunta por pagos de cuotas, con los cargos por atraso dentro. Las partes de lo cobrado salen en el globo de cada barra, y las de las dos en la tabla de abajo. Lo cobrado va dentro de lo esperado; lo que asoma por encima es lo que faltó."
      />

      <Table
        headers={[
          'Semana',
          {
            label: 'Se esperaba cobrar (financiamiento + comisión)',
            info: 'Lo que vencía esa semana multiplicado por el cobro a tiempo, según la proyección guardada el lunes. Sus partes se reparten como las de lo que vencía esa semana.',
          },
          {
            label: 'Cobrado según el libro (cuotas + cargos)',
            info: 'Del libro contable: lo que entró a la caja por pagos de cuotas esa semana, con los cargos por atraso dentro. Debajo, calculado de las cuotas: el financiamiento, la Comisión Helios y, aparte, los cargos por atraso.',
          },
          {
            label: 'Transferencia prevista a clínicas',
            info: 'Lo que la proyección guardada el lunes esperaba transferir a las clínicas esa semana.',
          },
          {
            label: 'Transferido a clínicas',
            info: 'Del libro contable: lo transferido a las clínicas esa semana.',
          },
          {
            label: 'Caja al final',
            info: 'Arriba, la caja que proyectaba la foto del lunes; abajo, la que dice el libro al terminar la semana (o hoy, si está en curso).',
          },
        ]}
      >
        {d.semanas.map((s) => (
          <FilaSemana key={s.weekStart} s={s} partes={porLunes.get(s.weekStart)} />
        ))}
      </Table>
    </Seccion>
  )
}

function FilaSemana({ s, partes }: { s: SemanaProyectadaYReal; partes: SemanaDeCaja | undefined }) {
  const esperado = partes ? repartirComoVencia(s.proyectadoCobrarUsd, partes.vencia) : null

  return (
    <Tr>
      <Td className="whitespace-nowrap">
        {formatDay(s.weekStart)}
        <span className="block type-panel-caption text-panel-muted">
          {s.completa ? `al ${formatDay(s.weekEnd)}` : 'En curso'}
        </span>
      </Td>
      <Td className="tabular-nums text-on-surface-variant">
        {formatUsd(s.proyectadoCobrarUsd)}
        {esperado && s.proyectadoCobrarUsd > 0 && <Partes texto={textoDeDesglose(esperado)} />}
      </Td>
      <Td className="tabular-nums font-semibold">
        {formatUsd(s.cobradoUsd)}
        {partes && s.cobradoUsd > 0 && (
          <Partes
            texto={`${textoDeDesglose(partes.cobrado)}${
              partes.cargosCobradosUsd > 0 ? ` · cargos por atraso ${formatUsd(partes.cargosCobradosUsd)}` : ''
            }`}
          />
        )}
      </Td>
      <Td className="tabular-nums text-on-surface-variant">{formatUsd(s.proyectadoTransferirUsd)}</Td>
      <Td className="tabular-nums">{formatUsd(s.transferidoUsd)}</Td>
      <Td className="whitespace-nowrap tabular-nums">
        <span className="block text-on-surface-variant">{formatUsd(s.proyectadoCajaFinalUsd)}</span>
        <span className="block font-semibold">
          <CajaAlFinal valor={s.cajaFinalUsd} />
        </span>
      </Td>
    </Tr>
  )
}

/** Las partes de un importe en cuotas, debajo de él. */
function Partes({ texto }: { texto: string }) {
  return <span className="block whitespace-nowrap type-panel-caption font-normal text-panel-muted">{texto}</span>
}
