import { Button, EmptyState, Stat, StatGrid, formatUsd } from '@/components/ui'
import { contar } from '@/components/admin/inicio/cifras'
import { fraseDelCotejo } from '@/features/admin/porCobrar'
import type { CifrasPorCobrar, PorCobrar, VerPorCobrar } from '@/features/admin/porCobrar'
import { Sumandos } from './Sumandos'

/** Una cifra con la comisión dentro: el total con sus sumandos debajo, o un cero limpio. */
function sumandosSiHay(c: CifrasPorCobrar) {
  return c.totalUsd > 0 ? <Sumandos cifras={c} /> : undefined
}

/**
 * Las cifras de la semana: lo que queda por cobrar como titular, con su
 * desglose debajo, y a su lado lo que ya entró, lo vencido de antes y a
 * cuántas cuotas y personas corresponde.
 *
 * Cada cifra con la Comisión Helios dentro lleva sus sumandos a la vista: un
 * total suelto se leería como si el local hubiera cobrado de más.
 */
export function CifrasDeLaSemana({
  datos,
  ver,
  enCurso,
  onVer,
}: {
  datos: PorCobrar
  ver: VerPorCobrar
  enCurso: boolean
  onVer: (ver: VerPorCobrar) => void
}) {
  const { periodo, pagado, vencidoAntes } = datos
  const esta = enCurso ? 'esta semana' : 'la semana'
  const vacia = periodo.cuotas === 0

  const titular = vacia ? (
    <EmptyState
      title={
        ver === 'pendiente' && pagado.cuotas > 0
          ? `Todo lo que vence ${esta} ya está pagado`
          : `${enCurso ? 'Esta semana' : 'Esa semana'} no vence nada`
      }
      action={
        ver === 'pendiente' && pagado.cuotas > 0 ? (
          <Button variant="tonal" size="md" onClick={() => onVer('todo')}>
            Ver todo lo que vence
          </Button>
        ) : undefined
      }
    />
  ) : (
    <Stat
      variant="hero"
      label={
        ver === 'todo'
          ? `Total a cobrar ${esta} (financiado + Comisión Helios + IVA)`
          : `Por cobrar ${esta} (financiado + Comisión Helios + IVA)`
      }
      value={formatUsd(periodo.totalUsd)}
      info={`${
        ver === 'todo'
          ? 'Todas las cuotas que vencen de lunes a domingo, pagadas o no.'
          : 'Las cuotas que vencen de lunes a domingo y siguen sin pagar.'
      } Es el financiado (sin comisión) más la Comisión Helios + IVA (y los cargos por atraso de esas cuotas, si hay), con sus sumandos debajo. Cuenta por la fecha de vencimiento, sin lo dado por perdido ni las cuentas de prueba. ${fraseDelCotejo(datos.cotejo)}`}
      visual={<Sumandos cifras={periodo} grande />}
    />
  )

  const yaEntro = (
    <Stat
      label={`Cobrado de lo que vence ${esta}`}
      value={formatUsd(pagado.totalUsd)}
      info="De las cuotas que vencen en la semana, las ya pagadas: financiado + Comisión Helios + IVA, con sus cargos por atraso pagados y los sumandos debajo. Una cuota pagada antes de tiempo cuenta aquí."
      hint={pagado.cuotas > 0 ? contar(pagado.cuotas, 'cuota pagada', 'cuotas pagadas') : 'Nada pagado todavía'}
      visual={sumandosSiHay(pagado)}
    />
  )

  const vencido = (
    <Stat
      label="Vencido de semanas anteriores"
      value={formatUsd(vencidoAntes.totalUsd)}
      info="Las cuotas que vencieron antes del lunes de la semana, y antes de hoy, y siguen sin pagar: financiado + Comisión Helios + IVA, con sus cargos por atraso y los sumandos debajo. Lo vencido lo decide el día operativo, como el motor de mora. Es lo que trabaja Cartera vencida."
      hint={
        vencidoAntes.cuotas > 0
          ? `${contar(vencidoAntes.cuotas, 'cuota', 'cuotas')} de ${contar(vencidoAntes.personas, 'paciente', 'pacientes')}`
          : 'Nada vencido de antes'
      }
      visual={sumandosSiHay(vencidoAntes)}
      link={{ to: '/admin/cobranza' }}
    />
  )

  if (vacia) {
    return (
      <div className="flex flex-col gap-4">
        {titular}
        <StatGrid cols={2}>
          {yaEntro}
          {vencido}
        </StatGrid>
      </div>
    )
  }

  return (
    // El titular al lado de las otras cuatro cuando cabe; debajo, si no.
    <div className="@container">
      <div className="grid gap-4 @4xl:grid-cols-5">
        <div className="@4xl:col-span-2">{titular}</div>
        <div className="@4xl:col-span-3">
          <StatGrid cols={2}>
            {yaEntro}
            {vencido}
            <Stat
              label="Cuotas"
              value={String(periodo.cuotas)}
              info="Las cuotas distintas de la semana con algo que cobrar (o todas, con «Todo lo que vence»). Una cuota con su cargo por atraso cuenta una vez."
              hint={contar(periodo.locales, 'clínica', 'clínicas')}
            />
            <Stat
              label="Pacientes"
              value={String(periodo.personas)}
              info="Pacientes distintos con alguna de esas cuotas."
            />
          </StatGrid>
        </div>
      </div>
    </div>
  )
}
