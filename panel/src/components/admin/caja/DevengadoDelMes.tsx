import { Card, NoSePudoLeer, Seccion, SkeletonList, formatUsd } from '@/components/ui'
import { useMesContable } from '@/components/admin/ExportacionContable'
import { Desglose } from '@/components/admin/tableros/Desglose'
import { devengadoDelMes } from '@/features/admin/contabilidad'

/**
 * Lo devengado y lo cobrado del mes, cada línea con su explicación.
 *
 * No hay total: el service fee es ingreso, el IVA es de Hacienda, lo dado por
 * perdido es deuda y lo cobrado es caja. Sumarlos mezclaría el consumo con el
 * service fee en una cifra que no es nada.
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
            rotulo: 'Service fee devengado, sin IVA',
            info: 'El service fee de los financiamientos confirmados en el mes, sin IVA, menos lo revertido. Se gana al confirmar el financiamiento, se cobre o no.',
            valor: formatUsd(d.servicioUsd),
          },
          {
            rotulo: 'IVA del service fee, por pagar',
            info: 'El IVA que grava el service fee del mes. No es de Helios: se cobra al paciente y se remite.',
            valor: formatUsd(d.ivaUsd),
          },
          {
            rotulo: 'Cargos por atraso devengados',
            info: 'Los cargos por atraso que cayeron en el mes, menos los condonados.',
            valor: formatUsd(d.cargosPorAtrasoUsd),
          },
          {
            rotulo: 'Dado por perdido (financiamiento + fee)',
            info: 'La deuda que pasó a pérdida en el mes, según el libro. Es deuda: lleva el service fee y su IVA dentro, y no se compara con el financiamiento, que va sin fee.',
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
