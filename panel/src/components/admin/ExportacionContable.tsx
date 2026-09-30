import { useQuery } from '@tanstack/react-query'
import { Download } from 'lucide-react'

import {
  Badge,
  Button,
  Card,
  EmptyState,
  ErrorBox,
  Seccion,
  SkeletonList,
  Table,
  Td,
  Tr,
  formatDay,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { Desglose } from '@/components/admin/tableros/Desglose'
import { SelectorDeMes } from '@/components/admin/tableros/SelectorDeMes'
import { fetchAccountingExport } from '@/features/admin/ajustes'
import type { AccountingExport } from '@/features/admin/ajustes'
import { nombreDelMes } from '@/features/admin/cierreMes'
import { LIBRO_CUADRA, descuadreDelLibro, nombreDeAsiento, nombreDeCuenta } from '@/features/admin/contabilidad'
import { construirCsv, csvDinero, csvInstante, descargarCsv } from '@/lib/csv'
import type { CsvColumn } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

/** La consulta del mes contable, compartida con el cierre de mes. */
export function useMesContable(mes: string) {
  return useQuery({
    queryKey: ['admin-accounting', mes],
    queryFn: () => fetchAccountingExport(mes),
  })
}

/**
 * La exportación contable del mes: las tres piezas que pide el contador.
 *
 * El balance de comprobación es el que dice si el libro cuadra: la suma de los
 * netos tiene que dar cero. El mes viaja en la URL (`?mes=`), el mismo que el
 * del cierre de mes. El resumen es un desglose y no cinco cifras sueltas: son
 * líneas del mismo mes que no se suman entre sí.
 */
export function ExportacionContable({
  mes,
  maximo,
  onMes,
}: {
  mes: string
  /** El último mes elegible. */
  maximo: string
  onMes: (mes: string) => void
}) {
  const query = useMesContable(mes)
  const d = query.data
  const cuadra = d ? Math.abs(descuadreDelLibro(d)) < LIBRO_CUADRA : false

  return (
    <div className="flex flex-col gap-10">
      <Seccion
        titulo={`Resumen de ${nombreDelMes(mes)}`}
        controles={
          <>
            <SelectorDeMes mes={mes} maximo={maximo} onMes={onMes} />
            <Button
              size="sm"
              variant="tonal"
              disabled={!d}
              onClick={() => d && exportarMesContable(d)}
            >
              <Download size={14} aria-hidden /> Exportar el mes
            </Button>
          </>
        }
      >
        {query.isPending && <SkeletonList rows={3} />}

        {query.isError && (
          <ErrorBox title="No se pudo armar el mes" detail={describeError(query.error)} />
        )}

        {d && (
          <Card>
            <Desglose
              lineas={[
                {
                  rotulo: 'Cobrado',
                  info: 'Lo que entró a caja en el mes: los pagos aprobados de los pacientes.',
                  valor: formatUsd(d.summary.collectedUsd),
                },
                {
                  rotulo: 'Pagado a clínicas',
                  info: 'Lo que salió de caja en el mes hacia las clínicas.',
                  valor: formatUsd(d.summary.paidOutUsd),
                },
                {
                  rotulo: 'Ingresos de Helios',
                  info: 'El service fee devengado y los cargos por atraso del mes, sin IVA. En el cierre de mes van por separado.',
                  valor: formatUsd(d.summary.revenueUsd),
                },
                {
                  rotulo: 'IVA por pagar',
                  info: 'El IVA del service fee. No es de Helios: se cobra al paciente y se remite.',
                  valor: formatUsd(d.summary.vatUsd),
                },
                {
                  rotulo: 'Dado por perdido',
                  info: 'La deuda que pasó a pérdida en el mes. Es deuda: financiamiento + service fee.',
                  valor: formatUsd(d.summary.writtenOffUsd),
                },
              ]}
            />
          </Card>
        )}
      </Seccion>

      {d && (
        <Seccion
          titulo="Balance de comprobación"
          info="El que dice si el libro cuadra: la suma de los netos tiene que dar cero. El CSV trae el detalle línea a línea."
          controles={
            <Badge tone={cuadra ? 'success' : 'error'} icono>
              {cuadra ? 'Cuadra' : 'No cuadra'}
            </Badge>
          }
        >
          {d.byAccount.length === 0 ? (
            <EmptyState
              title="Ningún movimiento en este mes"
              description="El mes va de día operativo a día operativo: un financiamiento del día 1 a las 3 a. m. pertenece al mes anterior."
            />
          ) : (
            <Table headers={['Cuenta', 'Debe', 'Haber', 'Neto', 'Debe (Bs.)', 'Haber (Bs.)']}>
              {d.byAccount.map((a) => (
                <Tr key={a.account}>
                  <Td className="font-medium">{nombreDeCuenta(a.account)}</Td>
                  <Td className="tabular-nums">{formatUsd(a.debitUsd)}</Td>
                  <Td className="tabular-nums">{formatUsd(a.creditUsd)}</Td>
                  <Td className="tabular-nums font-semibold">{formatUsd(a.netUsd)}</Td>
                  <Td className="tabular-nums text-on-surface-variant">{formatVes(a.debitVes)}</Td>
                  <Td className="tabular-nums text-on-surface-variant">{formatVes(a.creditVes)}</Td>
                </Tr>
              ))}
            </Table>
          )}

          <p className="type-panel-caption text-panel-muted">
            {d.summary.transactions} asientos entre el {formatDay(d.from)} y el {formatDay(d.to)}, sin
            cuentas de prueba.
          </p>
        </Seccion>
      )}
    </div>
  )
}

type Linea = AccountingExport['entries'][number]

const COLUMNAS_CSV: Array<CsvColumn<Linea>> = [
  { header: 'Dia operativo', value: (e) => e.businessDate },
  { header: 'Fecha y hora (Caracas)', value: (e) => csvInstante(e.createdAt) },
  { header: 'Tipo', value: (e) => nombreDeAsiento(e.type) },
  { header: 'Concepto', value: (e) => e.memo },
  { header: 'Cuenta', value: (e) => nombreDeCuenta(e.account) },
  { header: 'Debe USD', value: (e) => csvDinero(e.debitUsd) },
  { header: 'Haber USD', value: (e) => csvDinero(e.creditUsd) },
  { header: 'Tasa', value: (e) => csvDinero(e.fxRate, 6) },
  { header: 'Debe Bs', value: (e) => csvDinero(e.debitVes) },
  { header: 'Haber Bs', value: (e) => csvDinero(e.creditVes) },
  { header: 'Contraparte', value: (e) => e.counterparty },
]

/**
 * El detalle del mes línea a línea, para el contador. Con `lib/csv`: entrecomilla
 * en vez de borrar los puntos y coma de un concepto, como hacía la copia vieja.
 */
export function exportarMesContable(d: AccountingExport) {
  descargarCsv(`contable-${d.month}`, construirCsv(COLUMNAS_CSV, d.entries))
}
