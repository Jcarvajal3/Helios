import { ColumnasApiladas } from '@/components/charts'
import type { ColumnaApilada, SerieApilada } from '@/components/charts'
import { formatUsd, formatUsdShort } from '@/components/ui'
import { contar } from '@/components/admin/inicio/cifras'
import { hayCargos, rotuloDelDia } from '@/features/admin/porCobrar'
import type { PorCobrar } from '@/features/admin/porCobrar'
import { diaConNombre } from '@/features/admin/semana'
import { ROTULOS } from './Sumandos'

/**
 * «Lo que vence cada día»: siete columnas, de lunes a domingo, con el consumo
 * abajo y la Comisión Helios encima (y los cargos por atraso arriba, si los
 * hay). El total va escrito encima de cada columna, porque la columna misma
 * enseña los sumandos.
 *
 * Pulsar un día lo elige y la tabla de locales pasa a ser la de ese día.
 */
export function LoQueVenceCadaDia({
  datos,
  dia,
  onDia,
}: {
  datos: PorCobrar
  /** El día elegido, o `null` para la semana entera. */
  dia: string | null
  onDia: (dia: string | null) => void
}) {
  const conCargos = hayCargos(datos)
  const series: SerieApilada[] = [
    { key: 'consumo', rotulo: ROTULOS.consumo },
    { key: 'comision', rotulo: ROTULOS.comision },
    ...(conCargos ? [{ key: 'cargos', rotulo: ROTULOS.cargos }] : []),
  ]

  const columnas: ColumnaApilada[] = datos.porDia.map((d, i) => ({
    key: d.dia,
    rotulo: rotuloDelDia(datos.desde, i),
    titulo: diaConNombre(d.dia),
    valores: [d.consumoUsd, d.comisionUsd, ...(conCargos ? [d.cargosUsd] : [])],
    nota:
      d.cuotas > 0
        ? `${contar(d.cuotas, 'cuota', 'cuotas')} · ${contar(d.personas, 'paciente', 'pacientes')}`
        : 'Sin cuotas',
    hoy: d.dia === datos.hoy,
    marca: d.vencido ? { tono: 'error', texto: 'Vencido sin pagar' } : undefined,
  }))

  const elegida = dia === null ? null : datos.porDia.findIndex((d) => d.dia === dia)

  return (
    <ColumnasApiladas
      titulo="Lo que vence cada día"
      info={`Cada columna es un día, por la fecha de vencimiento de la cuota: abajo el financiado (sin comisión) y encima la Comisión Helios + IVA${
        conCargos ? ', y arriba los cargos por atraso' : ''
      }. El número de encima es la suma. Un día ya pasado con cuotas sin pagar lleva la marca de vencido.`}
      resumen="Pulsa un día para ver lo que corresponde a cada clínica."
      series={series}
      columnas={columnas}
      formato={formatUsd}
      formatoCorto={formatUsdShort}
      ejeLabel="Día"
      unidadLabel="Cuotas y pacientes"
      totalLabel={datos.incluyePagadas ? 'Total a cobrar' : 'Por cobrar'}
      seleccionada={elegida !== null && elegida >= 0 ? elegida : null}
      onSeleccionar={(i) => onDia(i === null ? null : (datos.porDia[i]?.dia ?? null))}
    />
  )
}
