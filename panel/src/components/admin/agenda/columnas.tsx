import type { Column } from '@/components/DataTable'
import { TelefonoConAcciones } from '@/components/admin/seguimiento/Contacto'
import { Badge, formatDateTime, formatDay, formatPhone } from '@/components/ui'
import { haceCuanto } from '@/features/admin/cobranza/senales'
import {
  ESTADO_DEL_LEAD,
  PENDIENTE,
  ROTULO_CANAL,
  ROTULO_MODO,
  ROTULO_RESULTADO,
  estaCerrado,
  pendienteDe,
  tieneVisita,
} from '@/features/admin/agenda/agenda'
import type { Lead } from '@/features/admin/agenda/agenda'
import { csvInstante } from '@/lib/csv'

const APAGADO = 'text-on-surface-variant'
const PIE = 'mt-0.5 block type-panel-caption text-on-surface-variant'

/** El estado y, si lo hay, lo que toca hoy. */
export function EstadoDelLeadBadge({ lead, hoy, ahora }: { lead: Lead; hoy: string; ahora: Date }) {
  const pendiente = pendienteDe(lead, hoy, ahora)
  const estado = ESTADO_DEL_LEAD[lead.estado]
  return (
    <span className="flex flex-wrap gap-1">
      <Badge tone={estado.tone}>{estado.label}</Badge>
      {pendiente && pendiente !== 'sin_contactar' && (
        <Badge tone={PENDIENTE[pendiente].tone}>{PENDIENTE[pendiente].label}</Badge>
      )}
    </span>
  )
}

/**
 * Una fila por médico: quién es y dónde atiende, cómo llamarlo, en qué quedó,
 * la próxima cita y la última gestión. `hoy` es el día de Caracas.
 */
export function columnasDeLaAgenda(hoy: string, ahora: Date): Array<Column<Lead>> {
  return [
    {
      key: 'medico',
      header: 'Médico',
      identity: true,
      sort: (l) => l.nombre,
      csv: (l) => l.nombre,
      cell: (l) => (
        <div className="min-w-0">
          <p className="font-medium text-on-surface">{l.nombre}</p>
          <p className="type-panel-caption text-on-surface-variant">
            {[l.especialidad, l.consultorio].filter(Boolean).join(' · ') || 'Sin especialidad ni consultorio'}
          </p>
        </div>
      ),
    },

    {
      key: 'telefono',
      header: 'Teléfono',
      csv: (l) => (l.telefono ? formatPhone(l.telefono) : null),
      cell: (l) =>
        l.telefono ? (
          <TelefonoConAcciones telefono={l.telefono} nombre={l.nombre} conWaMe />
        ) : (
          <span className={APAGADO}>Sin teléfono</span>
        ),
    },

    {
      key: 'direccion',
      header: 'Dirección',
      sort: (l) => l.direccion,
      csv: (l) => l.direccion,
      cell: (l) =>
        l.direccion ? (
          <span className="block max-w-64">{l.direccion}</span>
        ) : (
          <span className={APAGADO}>—</span>
        ),
    },

    {
      key: 'estado',
      header: 'Estado',
      info: '«Afiliado» se pone solo cuando el médico llena el formulario de afiliación de la portada o se da de alta su clínica: se le reconoce por su teléfono o su nombre.',
      sort: (l) => l.estado,
      csv: (l) => ESTADO_DEL_LEAD[l.estado].label,
      cell: (l) => (
        <>
          <EstadoDelLeadBadge lead={l} hoy={hoy} ahora={ahora} />
          {l.estado === 'convertido' && l.clinica && <span className={PIE}>{l.clinica}</span>}
          {l.estado === 'convertido' && !l.clinica && l.solicitudEstado === 'pending' && (
            <span className={PIE}>Solicitud por revisar</span>
          )}
        </>
      ),
    },

    {
      key: 'proxima',
      header: 'Próxima cita',
      info: 'La visita agendada, con su hora, o el día de volver a llamar.',
      sort: (l) => (tieneVisita(l) && l.reunion ? l.reunion.slice(0, 10) : l.volverEl),
      csv: (l) =>
        tieneVisita(l) && l.reunion ? csvInstante(l.reunion) : l.volverEl ? formatDay(l.volverEl) : null,
      cell: (l) => {
        if (tieneVisita(l) && l.reunion) {
          return (
            <span className="tabular-nums">
              {formatDateTime(l.reunion)}
              <span className={PIE}>
                {l.modo ? `Visita ${ROTULO_MODO[l.modo].toLowerCase()}` : 'Visita'}
                {l.lugar ? ` · ${l.lugar}` : ''}
              </span>
            </span>
          )
        }
        if (l.volverEl && !estaCerrado(l)) {
          return (
            <span className="tabular-nums">
              {formatDay(l.volverEl)}
              <span className={PIE}>Volver a llamar</span>
            </span>
          )
        }
        return <span className={APAGADO}>—</span>
      },
    },

    {
      key: 'ultima',
      header: 'Última gestión',
      sort: (l) => l.ultima?.cuando ?? null,
      csv: (l) =>
        [l.ultima?.resultado ? ROTULO_RESULTADO[l.ultima.resultado] : null, l.ultima?.nota].filter(Boolean).join(': ') || null,
      cell: (l) => {
        const u = l.ultima
        if (!u || u.tipo === 'creado') return <span className={APAGADO}>Ninguna</span>
        return (
          <span className="block max-w-72">
            {u.resultado && <span className="block font-medium text-on-surface">{ROTULO_RESULTADO[u.resultado]}</span>}
            {(u.nota ?? !u.resultado) && (
              <span className="line-clamp-2">
                {u.nota ?? (u.estado ? ESTADO_DEL_LEAD[u.estado].label : 'Sin nota')}
              </span>
            )}
            <span className={PIE}>
              {haceCuanto(u.cuando, ahora)}
              {u.canal ? ` · ${ROTULO_CANAL[u.canal]}` : ''}
              {u.quien ? ` · ${u.quien}` : ' · Helios'}
            </span>
          </span>
        )
      },
    },

    {
      key: 'responsable',
      header: 'Gestionado por',
      sort: (l) => l.responsable,
      csv: (l) => l.responsable,
      cell: (l) => l.responsable ?? <span className={APAGADO}>Nadie</span>,
    },

    {
      key: 'creado',
      header: 'Apuntado',
      hidden: true,
      sort: (l) => l.creado,
      csv: (l) => csvInstante(l.creado),
      cell: (l) => <span className="tabular-nums">{formatDay(l.creado.slice(0, 10))}</span>,
    },
  ]
}
