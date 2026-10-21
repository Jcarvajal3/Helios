import { Card, NoSePudoLeer, Seccion, SkeletonList, formatUsd } from '@/components/ui'
import { useMesContable } from '@/components/admin/ExportacionContable'
import { Desglose } from '@/components/admin/tableros/Desglose'
import { devengadoDelMes } from '@/features/admin/contabilidad'

/**
 * Lo devengado y lo cobrado del mes, cada línea con su explicación.
 *
 * No hay total: la Comisión Helios es ingreso, el IVA es de Hacienda, la
 * comisión del personal es gasto, lo dado por perdido es deuda y lo cobrado es
 * caja. Sumarlos mezclaría la consulta con la comisión en una cifra que no es
 * nada.
 */
export function DevengadoDelMes({ mes }: { mes: string }) {
  const query = useMesContable(mes)

  return (
    <Seccion titulo="Devengado y cobrado" info="Cada línea va por su lado y no se suman: no hay total.">
      {query.isPending && <SkeletonList rows={3} />}
      {query.isError && (
        <Card>
          <NoSePudoLeer onReintentar={() => void query.refetch()} />
        </Card>
      )}
      {query.data && <Lineas d={devengadoDelMes(query.data)} />}
    </Seccion>
  )
}

function Lineas({ d }: { d: ReturnType<typeof devengadoDelMes> }) {
  return (
    <Card>
      <Desglose
        lineas={[
          {
            rotulo: 'Comisión Helios devengada, sin IVA',
            info: 'La Comisión Helios de las órdenes confirmadas en el mes, sin IVA, menos lo revertido. Se gana al confirmar la orden, se cobre o no.',
            valor: formatUsd(d.servicioUsd),
          },
          {
            rotulo: 'IVA de la Comisión Helios, por pagar',
            info: 'El IVA que grava la Comisión Helios del mes. No es de Helios: se cobra al paciente y se remite.',
            valor: formatUsd(d.ivaUsd),
          },
          {
            rotulo: 'Comisiones del personal (gasto)',
            info: 'Lo que Helios le debe al personal de las clínicas por las órdenes confirmadas en el mes. Es gasto: se le paga a la clínica junto con sus consultas.',
            valor: formatUsd(d.comisionesDelPersonalUsd),
          },
          {
            rotulo: 'Cargos por atraso devengados',
            info: 'Los cargos por atraso que cayeron en el mes, menos los condonados.',
            valor: formatUsd(d.cargosPorAtrasoUsd),
          },
          {
            rotulo: 'Dado por perdido (consulta + comisión)',
            info: 'La deuda que pasó a pérdida en el mes, según el libro. Es deuda: lleva la Comisión Helios y su IVA dentro, y no se compara con la consulta, que va sin comisión.',
            valor: formatUsd(d.dadoPorPerdidoUsd),
          },
          {
            rotulo: 'Cobrado a los pacientes',
            info: 'Lo que entró a caja en el mes por pagos de pacientes, sea de cuotas de este mes o de antes.',
            valor: formatUsd(d.cobradoUsd),
          },
          {
            rotulo: 'Transferido a las clínicas',
            info: 'Lo que salió de caja en el mes hacia las clínicas.',
            valor: formatUsd(d.pagadoALocalesUsd),
          },
        ]}
      />
    </Card>
  )
}
