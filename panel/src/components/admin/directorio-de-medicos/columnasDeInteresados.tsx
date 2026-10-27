import type { Column } from '@/components/DataTable'
import { Badge, formatDateTime, formatPhone } from '@/components/ui'
import { haceCuanto } from '@/features/admin/cobranza/senales'
import { rotuloDelInteresado } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import type { InteresadoDelDirectorio } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'

const APAGADO = 'text-on-surface-variant'

/**
 * Si ya se hizo paciente de ese médico: la pastilla con el número de la orden
 * que lo convirtió y, debajo, cuándo se creó. Lo usan la tabla y la ficha.
 */
export function EstadoDelInteresado({ interesado: i }: { interesado: InteresadoDelDirectorio }) {
  if (!i.conversion) return <Badge tone="neutral">{rotuloDelInteresado(i)}</Badge>
  return (
    <span className="flex flex-col items-start gap-0.5">
      <Badge tone="success">{rotuloDelInteresado(i)}</Badge>
      <span className="type-panel-caption text-on-surface-variant">{formatDateTime(i.conversion.creadaEl)}</span>
    </span>
  )
}

/**
 * Una fila por interesado: a qué médico le escribió (desde su tarjeta, por
 * el WhatsApp de Helios), desde qué teléfono, cuándo, cuántas veces y si ya
 * es su paciente. La fila abre la ficha del médico.
 */
export function columnasDeInteresados({ ahora }: { ahora: Date }): Array<Column<InteresadoDelDirectorio>> {
  return [
    {
      key: 'medico',
      header: 'Médico',
      identity: true,
      sort: (i) => i.medico,
      csv: (i) => i.medico,
      cell: (i) => <span className="font-medium text-on-surface">{i.medico || 'Sin nombre'}</span>,
    },

    {
      key: 'telefono',
      header: 'Teléfono',
      info: 'El WhatsApp desde el que escribió. No se le pasa al médico: Helios lo guarda solo para saber si después se hace paciente.',
      csv: (i) => formatPhone(i.telefono),
      cell: (i) => (
        <div>
          <p className="tabular-nums text-on-surface">{formatPhone(i.telefono)}</p>
          {i.paciente?.nombre && <p className="type-panel-caption text-on-surface-variant">{i.paciente.nombre}</p>}
        </div>
      ),
    },

    {
      key: 'primera',
      header: 'Escribió',
      info: 'Su primer mensaje con el código de la tarjeta. Desde ahí cuenta una orden para que sea paciente.',
      sort: (i) => i.primeraVez,
      sortDir: 'desc',
      csv: (i) => formatDateTime(i.primeraVez),
      cell: (i) => <span className="tabular-nums text-on-surface">{formatDateTime(i.primeraVez)}</span>,
    },

    {
      key: 'ultima',
      header: 'Último mensaje',
      info: 'La última vez que volvió a escribir con el código de ese médico.',
      sort: (i) => i.ultimaVez,
      sortDir: 'desc',
      csv: (i) => formatDateTime(i.ultimaVez),
      cell: (i) =>
        i.ultimaVez && i.ultimaVez !== i.primeraVez ? (
          <span title={formatDateTime(i.ultimaVez)}>{haceCuanto(i.ultimaVez, ahora)}</span>
        ) : (
          <span className={APAGADO}>—</span>
        ),
    },

    {
      key: 'mensajes',
      header: 'Mensajes',
      info: 'Cuántas veces escribió con el código de ese médico.',
      type: 'number',
      sort: (i) => i.mensajes,
      sortDir: 'desc',
      csv: (i) => i.mensajes,
      cell: (i) => i.mensajes,
    },

    {
      key: 'estado',
      header: 'Paciente',
      info: 'Si ese mismo teléfono tuvo después una orden confirmada con ese médico (la primera que lo hizo), y cuándo se creó.',
      sort: (i) => i.conversion?.creadaEl ?? null,
      sortDir: 'desc',
      csv: (i) => rotuloDelInteresado(i),
      cell: (i) => <EstadoDelInteresado interesado={i} />,
    },
  ]
}
