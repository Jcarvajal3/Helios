import type { Column } from '@/components/DataTable'
import { IconoDeEspecialidad } from '@/components/directorio/IconoDeEspecialidad'
import { Badge, Switch, formatPhone } from '@/components/ui'
import { Sparkline } from '@/components/charts/sparkline'
import { haceCuanto } from '@/features/admin/cobranza/senales'
import { ROTULO_BLOQUEO } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import type { MedicoEnElDirectorio } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import { especialidadDeTarjeta, lugarDeTarjeta } from '@/features/directorio/directorio'
import { nombreDeEspecialidad } from '@/features/directorio/especialidades'

const APAGADO = 'text-on-surface-variant'

function MarcasDeClinica({ m }: { m: MedicoEnElDirectorio }) {
  if (m.estado === 'active' && !m.esPrueba) return null
  return (
    <span className="mt-1 flex flex-wrap gap-1">
      {m.estado === 'paused' && <Badge tone="warning">Pausada</Badge>}
      {m.estado === 'terminated' && <Badge tone="neutral">Terminada</Badge>}
      {m.esPrueba && <Badge tone="neutral">Prueba</Badge>}
    </span>
  )
}

/**
 * Una fila por clínica: cómo sale su tarjeta, si se ve, a qué WhatsApp lleva
 * y cuántos contactos recibe. El interruptor publica u oculta al momento;
 * el resto se corrige en la ficha (pulsando la fila).
 */
export function columnasDelDirectorio({
  ahora,
  dias,
  cambiando,
  onVisible,
}: {
  ahora: Date
  /** Los treinta días de las barras, para el globo: «20/10». */
  dias: ReadonlyArray<string>
  /** La clínica cuyo interruptor se está guardando. */
  cambiando: string | null
  onVisible: (m: MedicoEnElDirectorio, visible: boolean) => void
}): Array<Column<MedicoEnElDirectorio>> {
  return [
    {
      key: 'medico',
      header: 'Médico',
      identity: true,
      sort: (m) => m.tarjeta.nombre,
      csv: (m) => m.tarjeta.nombre,
      cell: (m) => {
        const especialidad = especialidadDeTarjeta(m.tarjeta)
        return (
          <div className="flex items-start gap-3">
            <span className="grid size-9 shrink-0 place-items-center rounded-panel-control bg-panel-control text-on-surface-variant">
              <IconoDeEspecialidad clave={m.tarjeta.clave} className="size-4.5" />
            </span>
            <div className="min-w-0">
              <p className="font-medium text-on-surface">{m.tarjeta.nombre}</p>
              <p className="type-panel-caption text-on-surface-variant">
                {[especialidad, m.clinica !== m.tarjeta.nombre ? m.clinica : null].filter(Boolean).join(' · ')}
              </p>
              <MarcasDeClinica m={m} />
            </div>
          </div>
        )
      },
    },

    {
      key: 'visible',
      header: 'En el directorio',
      info: 'Si sale en /directorio. Solo se puede publicar una clínica activa, que no sea de prueba y con WhatsApp. Al pausarla o terminarla desaparece sola.',
      sort: (m) => (m.visible ? 1 : 0),
      sortDir: 'desc',
      csv: (m) => (m.visible ? 'Visible' : 'Oculto'),
      cell: (m) => {
        const bloqueado = m.bloqueo !== null
        return (
          <div className="flex flex-col items-start gap-1">
            <Switch
              id={`directorio-visible-${m.id}`}
              label={m.visible ? (bloqueado ? 'Visible, sin salir' : 'Visible') : 'Oculto'}
              checked={m.visible}
              disabled={cambiando === m.id || (bloqueado && !m.visible)}
              onChange={(v) => onVisible(m, v)}
            />
            {bloqueado && <Badge tone={m.visible ? 'warning' : 'neutral'}>{ROTULO_BLOQUEO[m.bloqueo!]}</Badge>}
          </div>
        )
      },
    },

    {
      key: 'especialidad',
      header: 'Filtro',
      info: 'La especialidad con la que se filtra y el icono de la tarjeta.',
      sort: (m) => nombreDeEspecialidad(m.tarjeta.clave),
      csv: (m) => nombreDeEspecialidad(m.tarjeta.clave),
      cell: (m) => <span className="text-on-surface">{nombreDeEspecialidad(m.tarjeta.clave)}</span>,
    },

    {
      key: 'whatsapp',
      header: 'WhatsApp',
      info: 'Adónde lleva el botón de la tarjeta. Por defecto, el teléfono que el médico dio en el alta.',
      csv: (m) => (m.tarjeta.whatsapp ? formatPhone(m.tarjeta.whatsapp) : null),
      cell: (m) =>
        m.tarjeta.whatsapp ? (
          <span className="tabular-nums text-on-surface">{formatPhone(m.tarjeta.whatsapp)}</span>
        ) : (
          <span className="text-warning">Sin WhatsApp</span>
        ),
    },

    {
      key: 'lugar',
      header: 'Dirección',
      csv: (m) => lugarDeTarjeta(m.tarjeta),
      cell: (m) => {
        const lugar = lugarDeTarjeta(m.tarjeta)
        return lugar ? (
          <span className="line-clamp-2 max-w-[28ch] text-on-surface-variant">{lugar}</span>
        ) : (
          <span className={APAGADO}>—</span>
        )
      },
    },

    {
      key: 'clics7',
      header: 'Clics 7 días',
      info: 'Toques al botón de WhatsApp de su tarjeta, hoy y los seis días anteriores. Los del equipo y los del personal de las clínicas no cuentan.',
      type: 'number',
      sort: (m) => m.clics.d7,
      sortDir: 'desc',
      csv: (m) => m.clics.d7,
      cell: (m) => m.clics.d7,
    },

    {
      key: 'clics30',
      header: 'Clics 30 días',
      info: 'Toques al botón de WhatsApp en los últimos 30 días, con la línea día a día.',
      type: 'number',
      sort: (m) => m.clics.d30,
      sortDir: 'desc',
      csv: (m) => m.clics.d30,
      cell: (m) => (
        <div className="flex items-center justify-end gap-3">
          <div className="w-20">
            <Sparkline
              values={m.clics.porDia}
              etiquetas={dias}
              serie="Clics"
              formato={(n) => String(Math.round(n))}
              height={24}
              label={`Clics de ${m.tarjeta.nombre} en los últimos 30 días: ${m.clics.d30}`}
            />
          </div>
          <span className="min-w-6 tabular-nums">{m.clics.d30}</span>
        </div>
      ),
    },

    {
      key: 'visitantes',
      header: 'Personas 30 días',
      info: 'Navegadores distintos que tocaron su botón en los últimos 30 días: una persona que escribe tres veces cuenta una.',
      type: 'number',
      sort: (m) => m.clics.visitantes30d,
      sortDir: 'desc',
      csv: (m) => m.clics.visitantes30d,
      cell: (m) => m.clics.visitantes30d,
    },

    {
      key: 'total',
      header: 'Total',
      info: 'Todos los toques desde que está en el directorio.',
      type: 'number',
      sort: (m) => m.clics.total,
      sortDir: 'desc',
      csv: (m) => m.clics.total,
      cell: (m) => m.clics.total,
    },

    {
      key: 'ultimo',
      header: 'Último clic',
      sort: (m) => m.clics.ultimo,
      sortDir: 'desc',
      csv: (m) => m.clics.ultimo,
      cell: (m) => (m.clics.ultimo ? haceCuanto(m.clics.ultimo, ahora) : <span className={APAGADO}>—</span>),
    },
  ]
}
