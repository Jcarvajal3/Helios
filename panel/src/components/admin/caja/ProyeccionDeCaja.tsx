import { useQuery } from '@tanstack/react-query'

import {
  Badge,
  InfoDot,
  Seccion,
  Segmented,
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
import { HORIZONTES } from '@/features/admin/metricas/caja/busqueda'
import type { Horizonte } from '@/features/admin/metricas/caja/busqueda'
import { consultaDeLaFoto, consultaDeLaProyeccion } from '@/features/admin/metricas/caja/consultas'
import type { Proyeccion } from '@/features/admin/metricas/caja/lectura'
import { textoDeDesglose } from '@/features/admin/metricas/formato'
import type { Desglose } from '@/features/admin/metricas/lectura'

/** Las ventanas que se ofrecen. El servidor no pasa de doce semanas. */
export const SEMANAS_DE_PROYECCION = HORIZONTES
export type SemanasDeProyeccion = Horizonte

/**
 * Lo que va a entrar y lo que va a salir las próximas semanas, desde hoy.
 *
 * La caja de partida es «Dinero en caja», la misma lectura que el Balance
 * (`admin_cash_position`): el saldo proyectado se acumula aquí, semana a
 * semana, sobre ella. Lo que vence y lo que se espera cobrar son cuotas, así
 * que dicen «(consumo + fee)» y van con sus dos partes debajo (regla del
 * fee). Solo lleva color la caja que se queda por debajo de cero.
 *
 * Con un local: lo que vence de sus consumos y lo que sale hacia él; sin
 * caja, que es de todo Ronda.
 */
export function ProyeccionDeCaja({
  semanas,
  onSemanas,
  local,
}: {
  semanas: SemanasDeProyeccion
  onSemanas: (semanas: SemanasDeProyeccion) => void
  local: string | null
}) {
  const foto = useQuery(consultaDeLaFoto(null))
  const proyeccion = useQuery(consultaDeLaProyeccion(semanas, local))
  const titulo = local ? 'Proyección de esta clínica' : 'Proyección de caja'

  const controles = (
    <Segmented
      etiqueta="Semanas"
      options={SEMANAS_DE_PROYECCION.map((s) => ({ value: s, label: `${s} semanas` }))}
      value={semanas}
      onChange={onSemanas}
    />
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
      : ` de los últimos 90 días (cuotas con el plazo cerrado, el vencimiento más ${d.diasDeGracia} días de gracia; un pago cuenta el día en que se reportó), que hoy es del ${(d.factorATiempo * 100).toFixed(0)} %${local ? ' (el de toda la cartera: el de una clínica tiene muy pocas cuotas)' : ''}.`

  const cabeceras = [
    'Semana',
    {
      label: 'Vence (financiamiento + fee)',
      info: 'Calculado de las cuotas sin pagar que vencen esa semana, desde hoy (lo ya vencido no se proyecta: está en el Balance como vencido), sin ajustar: el financiamiento más el service fee (IVA incluido), con sus dos partes debajo.',
    },
    {
      label: 'Se espera cobrar (financiamiento + fee)',
      info: `Lo que vence multiplicado por el cobrado a tiempo${aTiempo} No es una predicción: es lo que ha pasado hasta ahora aplicado a lo que viene.`,
    },
    {
      label: local ? 'A transferir a la clínica' : 'A transferir a clínicas',
      info: 'Las liquidaciones ya generadas que toca pagar esa semana (cada una, el día siguiente a su vencimiento): el neto de la clínica, sin el service fee. Lo atrasado cae en la primera. No incluye lo que todavía no se ha financiado.',
    },
    { label: 'Neto', info: 'Lo que se espera cobrar menos lo que hay que transferir esa semana.' },
    ...(caja === null
      ? []
      : [
          {
            label: 'Caja proyectada al final',
            info: 'El dinero en caja de hoy (del libro contable) más el neto de cada semana, acumulado.',
          },
        ]),
  ]

  let saldo = caja ?? 0

  return (
    <Table headers={cabeceras}>
      {d.filas.map((w) => {
        saldo += w.netoUsd
        const proyectado = saldo
        return (
          <Tr key={w.weekStart}>
            <Td className="whitespace-nowrap">
              {formatDay(w.weekStart)}
              <span className="block type-panel-caption text-panel-muted">al {formatDay(w.weekEnd)}</span>
            </Td>
            <Td className="tabular-nums text-on-surface-variant">
              <ConDesglose d={w.vence} />
            </Td>
            <Td className="tabular-nums font-semibold text-on-surface">
              <ConDesglose d={w.seEspera} />
            </Td>
            <Td className="tabular-nums text-on-surface-variant">−{formatUsd(w.saleUsd)}</Td>
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
 * La caja de una semana: en blanco, o con la pastilla de error si se queda por
 * debajo de cero. La comparte lo proyectado frente a lo real.
 *
 * Por qué va en rojo lo dice el globo del kit (`Tooltip`), con el ratón o con
 * el teclado, y no el `title` del navegador; el lector de pantalla lo oye en
 * la misma pastilla.
 */
export function CajaAlFinal({ valor }: { valor: number }) {
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
