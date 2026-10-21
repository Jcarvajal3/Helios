import type { Column } from '@/components/DataTable'
import { LogoLocal } from '@/components/admin/directorio/LogoLocal'
import { TelefonoConAcciones } from '@/components/admin/seguimiento/Contacto'
import { Badge, formatDay, formatPhone } from '@/components/ui'
import { haceCuanto } from '@/features/admin/cobranza/senales'
import {
  ESTADO_DEL_SEGUIMIENTO,
  ROTULO_CANAL_DE_SEGUIMIENTO,
  ROTULO_MOTIVO,
  ROTULO_ROL,
  estadoDelSeguimiento,
} from '@/features/admin/seguimiento/seguimiento'
import type { ClinicaEnSeguimiento, PersonaConSuClinica } from '@/features/admin/seguimiento/seguimiento'
import { csvInstante } from '@/lib/csv'

const APAGADO = 'text-on-surface-variant'
const PIE = 'mt-0.5 block type-panel-caption text-on-surface-variant'

/** «hace 3 días», o una raya si no ha pasado nunca. */
function cuandoFue(instante: string | null, ahora: Date) {
  return instante ? haceCuanto(instante, ahora) : '—'
}

function MarcasDeClinica({ estado, esPrueba }: { estado: ClinicaEnSeguimiento['estado']; esPrueba: boolean }) {
  if (estado === 'active' && !esPrueba) return null
  return (
    <span className="mt-1 flex flex-wrap gap-1">
      {estado === 'paused' && <Badge tone="warning">Pausada</Badge>}
      {estado === 'terminated' && <Badge tone="neutral">Terminada</Badge>}
      {esPrueba && <Badge tone="neutral">Prueba</Badge>}
    </span>
  )
}

// ── Por clínica ────────────────────────────────────────────────────────────

/**
 * Una fila por clínica: quién es el médico, a qué teléfono llamar, quién más
 * trabaja ahí (con su número y cuántas órdenes hace cada uno), cuánto usa
 * Helios y qué se habló la última vez. `hoy` es el día operativo.
 */
export function columnasPorClinica(hoy: string, ahora: Date): Array<Column<ClinicaEnSeguimiento>> {
  return [
    {
      key: 'clinica',
      header: 'Clínica',
      identity: true,
      sort: (c) => c.nombre,
      csv: (c) => c.nombre,
      cell: (c) => (
        <div className="flex items-start gap-3">
          <LogoLocal name={c.nombre} logoUrl={null} />
          <div className="min-w-0">
            <p className="font-medium text-on-surface">{c.nombre}</p>
            <p className="type-panel-caption text-on-surface-variant">
              {[c.especialidad, c.ciudad].filter(Boolean).join(' · ') || 'Sin especialidad ni ciudad'}
            </p>
            <MarcasDeClinica estado={c.estado} esPrueba={c.esPrueba} />
          </div>
        </div>
      ),
    },

    {
      key: 'medico',
      header: 'Médico titular',
      sort: (c) => c.medico,
      csv: (c) => c.medico,
      cell: (c) => c.medico ?? <span className={APAGADO}>Sin titular</span>,
    },

    {
      key: 'telefono',
      header: 'Teléfono',
      info: 'El teléfono de contacto de la clínica, el que se puso en el alta. El icono del chat abre su conversación en el inbox de Helios.',
      csv: (c) => (c.telefono ? formatPhone(c.telefono) : null),
      cell: (c) =>
        c.telefono ? (
          <TelefonoConAcciones telefono={c.telefono} nombre={c.medico ?? c.nombre} />
        ) : (
          <span className={APAGADO}>Sin teléfono</span>
        ),
    },

    {
      key: 'personal',
      header: 'Personal',
      info: 'Cada cuenta activa de la clínica, la que más órdenes confirmadas registró primero, con el número de WhatsApp con el que usa el bot.',
      sortDir: 'desc',
      sort: (c) => c.personal.length,
      csv: (c) =>
        c.personal
          .map((p) =>
            [p.nombre, ROTULO_ROL[p.rol], p.telefono ? formatPhone(p.telefono) : null, `${p.confirmadas} órdenes`]
              .filter(Boolean)
              .join(' · '),
          )
          .join(' | ') || null,
      cell: (c) =>
        c.personal.length === 0 ? (
          <span className={APAGADO}>Sin cuentas</span>
        ) : (
          <ul className="flex min-w-64 flex-col gap-1.5">
            {c.personal.map((p) => (
              <li key={p.userId} className="leading-tight">
                <span className="text-on-surface">{p.nombre}</span>
                <span className="type-panel-caption text-on-surface-variant">
                  {' '}
                  · {ROTULO_ROL[p.rol]} · {p.confirmadas} {p.confirmadas === 1 ? 'orden' : 'órdenes'}
                </span>
                <span className="block type-panel-caption text-on-surface-variant">
                  {p.telefono ? <TelefonoConAcciones telefono={p.telefono} nombre={p.nombre} /> : 'Sin número del bot'}
                </span>
              </li>
            ))}
          </ul>
        ),
    },

    {
      key: 'ordenes',
      header: 'Órdenes (30 días)',
      info: 'Pagos en cuotas confirmados por el paciente en los últimos 30 días operativos, sin los de pacientes de prueba; debajo, cuántas desde el alta y cuándo fue la última que se registró.',
      type: 'number',
      sortDir: 'desc',
      sort: (c) => c.confirmadas30d,
      csv: (c) => c.confirmadas30d,
      cell: (c) => (
        <>
          {c.confirmadas30d}
          <span className={PIE}>
            {c.confirmadas} desde el alta · última {cuandoFue(c.ultimaOrden, ahora)}
          </span>
        </>
      ),
    },

    {
      key: 'ordenes-total',
      header: 'Órdenes desde el alta',
      hidden: true,
      type: 'number',
      sortDir: 'desc',
      sort: (c) => c.confirmadas,
      csv: (c) => c.confirmadas,
      cell: (c) => c.confirmadas,
    },

    {
      key: 'ultimo-contacto',
      header: 'Último contacto',
      sortDir: 'desc',
      sort: (c) => c.ultimoContacto?.cuando ?? null,
      csv: (c) =>
        c.ultimoContacto
          ? `${csvInstante(c.ultimoContacto.cuando)} · ${ROTULO_MOTIVO[c.ultimoContacto.motivo]} · ${c.ultimoContacto.nota}`
          : null,
      cell: (c) => {
        const u = c.ultimoContacto
        if (!u) return <span className={APAGADO}>Nunca</span>
        return (
          <div className="max-w-80">
            <p className="text-on-surface">
              {haceCuanto(u.cuando, ahora)}
              <span className="type-panel-caption text-on-surface-variant">
                {' '}
                · {ROTULO_CANAL_DE_SEGUIMIENTO[u.canal]} · {ROTULO_MOTIVO[u.motivo]}
              </span>
            </p>
            <p className="line-clamp-2 type-panel-caption text-on-surface-variant">
              {u.quien}
              {u.conQuien ? ` con ${u.conQuien}` : ''}: {u.nota}
            </p>
          </div>
        )
      },
    },

    {
      key: 'seguimiento',
      header: 'Seguimiento',
      info: '«Volver a llamar» es la fecha que dejó el último contacto anotado: una nota nueva sin fecha la quita.',
      sort: (c) => c.volverEl,
      csv: (c) => `${ESTADO_DEL_SEGUIMIENTO[estadoDelSeguimiento(c, hoy)].label}${c.volverEl ? ` (${c.volverEl})` : ''}`,
      cell: (c) => {
        const estado = ESTADO_DEL_SEGUIMIENTO[estadoDelSeguimiento(c, hoy)]
        return (
          <div className="whitespace-nowrap">
            <Badge tone={estado.tone}>{estado.label}</Badge>
            {c.volverEl && <span className={PIE}>Volver el {formatDay(c.volverEl)}</span>}
          </div>
        )
      },
    },
  ]
}

// ── Por persona ────────────────────────────────────────────────────────────

/** Una fila por persona del personal: quién registra órdenes y cómo localizarla. */
export function columnasPorPersona(ahora: Date): Array<Column<PersonaConSuClinica>> {
  return [
    {
      key: 'persona',
      header: 'Persona',
      identity: true,
      sort: (p) => p.nombre,
      csv: (p) => p.nombre,
      cell: (p) => (
        <div className="min-w-0">
          <p className="font-medium text-on-surface">{p.nombre}</p>
          <p className="type-panel-caption text-on-surface-variant">{p.correo ?? 'Sin correo'}</p>
        </div>
      ),
    },

    {
      key: 'clinica',
      header: 'Clínica',
      sort: (p) => p.clinica,
      csv: (p) => p.clinica,
      cell: (p) => (
        <>
          {p.clinica}
          <span className={PIE}>
            {ROTULO_ROL[p.rol]}
            {p.sede ? ` · ${p.sede}` : ''}
          </span>
          <MarcasDeClinica
            estado={p.clinicaTerminada ? 'terminated' : 'active'}
            esPrueba={p.clinicaDePrueba}
          />
        </>
      ),
    },

    {
      key: 'rol',
      header: 'Rol',
      hidden: true,
      sort: (p) => ROTULO_ROL[p.rol],
      csv: (p) => ROTULO_ROL[p.rol],
      cell: (p) => ROTULO_ROL[p.rol],
    },

    {
      key: 'telefono',
      header: 'WhatsApp del bot',
      info: 'El número con el que esta persona usa el bot de WhatsApp. Sin él, solo entra al panel con su correo.',
      csv: (p) => (p.telefono ? formatPhone(p.telefono) : null),
      cell: (p) =>
        p.telefono ? (
          <TelefonoConAcciones telefono={p.telefono} nombre={p.nombre} />
        ) : (
          <span className={APAGADO}>Sin número</span>
        ),
    },

    {
      key: 'confirmadas',
      header: 'Órdenes',
      info: 'Pagos en cuotas que registró esta persona y el paciente confirmó, desde que empezó, sin los de pacientes de prueba; debajo, cuántas registró en total (también las que el paciente rechazó o dejó vencer).',
      type: 'number',
      sortDir: 'desc',
      sort: (p) => p.confirmadas,
      csv: (p) => p.confirmadas,
      cell: (p) => (
        <>
          {p.confirmadas}
          <span className={PIE}>de {p.registradas} registradas</span>
        </>
      ),
    },

    {
      key: '30d',
      header: 'Últimos 30 días',
      type: 'number',
      sortDir: 'desc',
      sort: (p) => p.confirmadas30d,
      csv: (p) => p.confirmadas30d,
      cell: (p) => p.confirmadas30d,
    },

    {
      key: 'bot',
      header: 'Por el bot',
      info: 'De sus órdenes confirmadas, cuántas registró por WhatsApp; el resto, desde el panel.',
      type: 'number',
      sortDir: 'desc',
      sort: (p) => p.porWhatsApp,
      csv: (p) => p.porWhatsApp,
      cell: (p) => (p.confirmadas === 0 ? <span className={APAGADO}>—</span> : `${p.porWhatsApp} de ${p.confirmadas}`),
    },

    {
      key: 'ultima-orden',
      header: 'Última orden',
      sortDir: 'desc',
      sort: (p) => p.ultimaOrden,
      csv: (p) => csvInstante(p.ultimaOrden),
      cell: (p) => <span className="whitespace-nowrap">{cuandoFue(p.ultimaOrden, ahora)}</span>,
    },

    {
      key: 'acceso',
      header: 'Último acceso al panel',
      sortDir: 'desc',
      sort: (p) => p.ultimoAcceso,
      csv: (p) => csvInstante(p.ultimoAcceso),
      cell: (p) => <span className="whitespace-nowrap">{cuandoFue(p.ultimoAcceso, ahora)}</span>,
    },
  ]
}
