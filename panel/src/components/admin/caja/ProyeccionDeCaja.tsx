import { useQuery } from '@tanstack/react-query'

import {
  Badge,
  InfoDot,
  Seccion,
  SkeletonTable,
  Table,
  Td,
  Tooltip,
  Tr,
  estadoDeConsultas,
  formatDay,
  formatUsd,
} from '@/components/ui'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { Cifra } from '@/components/admin/tableros/CifrasEnFila'
import { DIAS_DE_PROYECCION, consultaDeLaFoto, consultaDeLaProyeccion } from '@/features/admin/metricas/caja/consultas'
import type { Proyeccion } from '@/features/admin/metricas/caja/lectura'
import { textoDeDesglose } from '@/features/admin/metricas/formato'
import type { Desglose } from '@/features/admin/metricas/lectura'

/**
 * Lo que va a entrar y lo que va a salir los próximos 15 días, día a día.
 *
 * A la clínica se le paga el día siguiente al vencimiento de cada cuota del
 * paciente (días 8 y 15 de cada orden), pague o no el paciente; no los lunes.
 * Con eso, todo lo que hoy está en la calle entra y sale en esos 15 días. Lo
 * que sale incluye las mitades que todavía no se han devengado.
 *
 * La caja de partida es «Dinero en caja», la misma lectura que el Balance
 * (`admin_cash_position`): el saldo proyectado se acumula aquí, día a día,
 * sobre ella. Lo que vence y lo que se espera cobrar son cuotas, así que
 * dicen «(consulta + comisión)» y van con sus dos partes debajo. Solo lleva
 * color la caja que se queda por debajo de cero. Los días sin movimiento no
 * salen.
 *
 * Con una clínica: lo que vence de sus órdenes y lo que sale hacia ella; sin
 * caja, que es de todo Helios.
 */
export function ProyeccionDeCaja({ local }: { local: string | null }) {
  const foto = useQuery(consultaDeLaFoto(null))
  const proyeccion = useQuery(consultaDeLaProyeccion(local))
  const titulo = local ? 'Proyección de esta clínica' : 'Proyección de caja'
  const controles = (
    <span className="type-panel-caption text-panel-muted">Próximos {DIAS_DE_PROYECCION} días</span>
  )

  // Con un local no hace falta la caja: no espera por ella.
  const estado = estadoDeConsultas(local ? [proyeccion] : [foto, proyeccion])

  if (estado === 'cargando') {
    return (
      <Seccion titulo={titulo} controles={controles}>
        <SkeletonTable rows={4} columns={local ? 5 : 6} />
      </Seccion>
    )
  }

  if (estado === 'error' || !proyeccion.data) {
    return (
      <Seccion titulo={titulo} controles={controles}>
        <ErrorConReintento
          title="No se pudo calcular la proyección"
          error={proyeccion.error ?? foto.error}
          onReintentar={() => {
            void foto.refetch()
            void proyeccion.refetch()
          }}
        />
      </Seccion>
    )
  }

  const d = proyeccion.data
  const caja = local ? null : (foto.data?.cajaUsd ?? null)

  return (
    <Seccion titulo={titulo} controles={controles}>
      {caja !== null && (
        <p className="flex items-center gap-1.5 type-panel-body text-on-surface-variant">
          Dinero en caja hoy: <Cifra>{formatUsd(caja)}</Cifra>
          <InfoDot
            title="Dinero en caja"
            what="La misma cifra del Balance: lo cobrado a los pacientes menos lo transferido a las clínicas, según el libro de asientos. No es el saldo del banco."
          />
        </p>
      )}
      <TablaDeProyeccion d={d} caja={caja} local={local} />
    </Seccion>
  )
}

function TablaDeProyeccion({ d, caja, local }: { d: Proyeccion; caja: number | null; local: string | null }) {
  const aTiempo =
    d.factorATiempo === null
      ? ': todavía no hay suficiente historia, así que van iguales.'
      : ` de los últimos 90 días (cuotas con el plazo cerrado, el vencimiento más ${d.diasDeGracia} días de gracia; un pago cuenta el día en que se registró), que hoy es del ${(d.factorATiempo * 100).toFixed(0)} %${local ? ' (el de toda la cartera: el de una clínica tiene muy pocas cuotas)' : ''}.`

  const cabeceras = [
    'Día',
    {
      label: 'Vence (financiamiento + comisión)',
      info: 'Calculado de las cuotas sin pagar que vencen ese día, desde hoy (lo ya vencido no se proyecta: está en el Balance como vencido), sin ajustar: el financiamiento más la Comisión Helios (IVA incluido), con sus dos partes debajo.',
    },
    {
      label: 'Se espera cobrar (financiamiento + comisión)',
      info: `Lo que vence multiplicado por el cobrado a tiempo${aTiempo} No es una predicción: es lo que ha pasado hasta ahora aplicado a lo que viene.`,
    },
    {
      label: local ? 'A transferir a la clínica' : 'A transferir a clínicas',
      info: 'Lo que toca pagarles ese día: la mitad de cada consulta el día siguiente al vencimiento de su cuota (pague o no el paciente) y las comisiones del personal. Debajo, cuánto ya está devengado y cuánto se devengará al vencer la cuota. Sin la Comisión Helios. Lo atrasado cae hoy. No incluye órdenes que todavía no se han registrado.',
    },
    { label: 'Neto', info: 'Lo que se espera cobrar menos lo que hay que transferir ese día.' },
    ...(caja === null
      ? []
      : [
          {
            label: 'Caja proyectada al final',
            info: 'El dinero en caja de hoy (del libro contable) más el neto de cada día, acumulado.',
          },
        ]),
  ]

  let saldo = caja ?? 0
  // El neto se acumula sobre todos los días; solo se enseñan los que mueven
  // algo (y hoy, siempre).
  const filas = d.filas.map((w) => {
    saldo += w.netoUsd
    return { ...w, proyectado: saldo }
  })
  const conMovimiento = filas.filter((w, i) => i === 0 || w.vence.payableUsd > 0 || w.saleUsd > 0)

  return (
    <Table headers={cabeceras}>
      {conMovimiento.map((w) => {
        const proyectado = w.proyectado
        return (
          <Tr key={w.dia}>
            <Td className="whitespace-nowrap">{w.dia === d.businessDate ? 'Hoy' : formatDay(w.dia)}</Td>
            <Td className="tabular-nums text-on-surface-variant">
              <ConDesglose d={w.vence} />
            </Td>
            <Td className="tabular-nums font-semibold text-on-surface">
              <ConDesglose d={w.seEspera} />
            </Td>
            <Td className="tabular-nums text-on-surface-variant">
              −{formatUsd(w.saleUsd)}
              {w.salePorDevengarUsd > 0 && (
                <span className="block whitespace-nowrap type-panel-caption font-normal text-panel-muted">
                  {formatUsd(w.saleDevengadoUsd)} devengado · {formatUsd(w.salePorDevengarUsd)} por devengar
                </span>
              )}
            </Td>
            <Td className="tabular-nums text-on-surface">{formatUsd(w.netoUsd)}</Td>
            {caja !== null && (
              <Td className="tabular-nums font-semibold text-on-surface">
                <CajaAlFinal valor={proyectado} />
              </Td>
            )}
          </Tr>
        )
      })}
    </Table>
  )
}

/** Un importe en cuotas con sus dos partes debajo: nunca el total solo. */
function ConDesglose({ d }: { d: Desglose }) {
  return (
    <>
      {formatUsd(d.payableUsd)}
      {d.payableUsd > 0 && (
        <span className="block whitespace-nowrap type-panel-caption font-normal text-panel-muted">
          {textoDeDesglose(d)}
        </span>
      )}
    </>
  )
}

/**
 * La caja de un día: en blanco, o con la pastilla de error si se queda por
 * debajo de cero.
 *
 * Por qué va en rojo lo dice el globo del kit (`Tooltip`), con el ratón o con
 * el teclado, y no el `title` del navegador; el lector de pantalla lo oye en
 * la misma pastilla.
 */
function CajaAlFinal({ valor }: { valor: number }) {
  if (valor >= 0) return <>{formatUsd(valor)}</>
  return (
    <Tooltip contenido="La caja se queda por debajo de cero">
      <span tabIndex={0} className="inline-flex rounded-full">
        <Badge tone="error" icono>
          {formatUsd(valor)}
          <span className="sr-only">, por debajo de cero</span>
        </Badge>
      </span>
    </Tooltip>
  )
}
