import { Link } from '@tanstack/react-router'

import { ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { BotonAnotarGestion } from '@/components/admin/ficha-persona/CobranzaGestion'
import { InsigniaPromesa, InsigniaResultado } from '@/components/admin/ficha-persona/CobranzaInsignias'
import { BotonWhatsAppCobranza } from '@/components/admin/ficha-persona/CobranzaWhatsApp'
import { Badge, formatDateTime, formatDay, formatDayShort, formatUsd, formatPhone, formatVes, sumarDias } from '@/components/ui'
import { HORIZONTE_CARTERA, HORIZONTE_TODO, desgloseCorto, proximaAccion, tramoDeFila } from '@/features/admin/cobranza/cartera'
import type { CollectionRow } from '@/features/admin/cobranza/cartera'
import { QUE_ES_LA_INTENCION, ROTULO_INTENCION, intencionDe, senalesDe } from '@/features/admin/cobranza/senales'
import { Senales } from '@/components/admin/cartera/Senales'
import { RESULTADO, ROTULO_CANAL } from '@/features/admin/cobranza/gestion'
import { estadoDePersona, ESTADOS_PROMESA } from '@/features/admin/estados'
import { PRIORIDAD_DEL_PERFIL, ROTULO_PERFIL, TONO_PRIORIDAD } from '@/features/admin/metricas/cobranza/perfiles'
import { rotuloDeTramo } from '@/features/admin/tramos'
import type { CortesDeTramo } from '@/features/admin/tramos'
import { csvDinero, csvEntero, csvInstante } from '@/lib/csv'

export type ContextoColumnas = {
  /** Día operativo de hoy. */
  hoy: string
  cortes: CortesDeTramo | null
  /** La tasa BCV del día, para el monto en bolívares; `null` si no se leyó. */
  tasa: number | null
  /**
   * Apunta la cola antes de ir al caso: el nombre también abre el caso. Recibe
   * las filas en el orden que se ven, como la fila.
   */
  alAbrirCaso: (enPantalla: CollectionRow[]) => void
  /** Para las señales: el instante de ahora y los días de atraso de la suspensión. */
  ahora: Date
  diasBaja: number
  /** Hasta cuántos días mira la cola. Por defecto, `HORIZONTE_CARTERA`; con `HORIZONTE_TODO`, todo. */
  horizonteDias?: number
}

/** La columna de señales: la misma en la cola y en la lista de una semana. */
export function columnaDeSenales<T extends CollectionRow>(ctx: Pick<ContextoColumnas, 'hoy' | 'ahora' | 'diasBaja'>): Column<T> {
  const de = (r: T) => senalesDe(r, { ahora: ctx.ahora, hoy: ctx.hoy, diasBaja: ctx.diasBaja })
  return {
    key: 'senales',
    header: 'Señales',
    info: `Lo que hizo antes de que le escribas, con su fecha en el globo de cada una. Verde: un gesto de querer pagar. Rojo: de evitarlo o de no enterarse. Ámbar: algo que tienes que saber antes. Gris: su historia. ${QUE_ES_LA_INTENCION}`,
    // Ordena por intención: primero quien lo está evitando.
    sort: (r) => de(r).reduce((a, s) => a + s.peso, 0),
    csv: (r) => {
      const s = de(r)
      return [ROTULO_INTENCION[intencionDe(s)], ...s.map((x) => x.texto)].join(' · ')
    },
    cell: (r) => <Senales senales={de(r)} />,
  }
}

/**
 * Las columnas de la cartera vencida. Una fila por usuario y no por cuota:
 * quien cobra llama a alguien, y ese usuario puede deber tres cuotas de dos
 * locales.
 *
 * Lo vencido y lo por vencer van en columnas distintas: son dos cifras, y una
 * columna que enseñara una u otra según la fila tendría un nombre para dos
 * números.
 */
export function columnasCartera(ctx: ContextoColumnas): Array<Column<CollectionRow>> {
  // El último día que mira la cartera.
  const dias = ctx.horizonteDias ?? HORIZONTE_CARTERA
  // Con la cola entera no hay último día que decir.
  const hastaElDia = dias >= HORIZONTE_TODO ? null : formatDayShort(sumarDias(ctx.hoy, dias))
  return [
    {
      key: 'persona',
      header: 'Paciente',
      identity: true,
      sort: (r) => r.fullName,
      csv: (r) => r.fullName,
      cell: (r, enPantalla) => (
        <>
          <Link
            to="/admin/pacientes/$id"
            params={{ id: r.userId }}
            search={{ tab: 'cobranza' }}
            onClick={() => ctx.alAbrirCaso(enPantalla)}
            className={ENLACE_EN_CELDA}
          >
            {r.fullName ?? 'Sin nombre'}
          </Link>
          <p className="mt-0.5 type-panel-caption tabular-nums text-on-surface-variant">
            {formatPhone(r.phone)}
          </p>
          {r.perfil && (
            <p className="mt-0.5 max-w-56 truncate type-panel-caption text-panel-muted">{ROTULO_PERFIL[r.perfil]}</p>
          )}
        </>
      ),
    },

    {
      key: 'telefono',
      header: 'Teléfono',
      hidden: true,
      csv: (r) => r.phone,
      cell: (r) => <span className="tabular-nums">{formatPhone(r.phone)}</span>,
    },

    {
      key: 'estado',
      header: 'Estado de la cuenta',
      hidden: true,
      info: 'Lo pone el estado automático cada mañana según los días de atraso.',
      sort: (r) => estadoDePersona(r.status).label,
      csv: (r) => estadoDePersona(r.status).label,
      cell: (r) => <EstadoBadge tipo="persona" valor={r.status} />,
    },

    {
      key: 'cuotas',
      header: 'Cuotas pendientes',
      hidden: true,
      type: 'number',
      info: `Las cuotas sin pagar de este paciente, vencidas o por vencer${hastaElDia ? ` hasta el ${hastaElDia}` : ''}, incluidas las dadas por perdidas, y de qué clínicas son.`,
      sort: (r) => r.installmentCount,
      csv: (r) => csvEntero(r.installmentCount),
      cell: (r) => (
        <span className="block text-on-surface-variant">
          <span className="text-on-surface">
            {r.installmentCount} {r.installmentCount === 1 ? 'cuota' : 'cuotas'}
          </span>
          {r.merchants.length > 0 && (
            <span className="mt-0.5 block max-w-56 truncate type-panel-caption">
              {r.merchants.join(', ')}
            </span>
          )}
        </span>
      ),
    },

    {
      key: 'vencido',
      header: 'Vencido (financiamiento + comisión)',
      type: 'number',
      sortDir: 'desc',
      info: 'Las cuotas de este paciente vencidos y sin pagar, incluida la deuda dada por perdida: lo que tiene que transferir, financiamiento + Comisión Helios, con sus dos partes y su equivalente en bolívares debajo.',
      // Quien no debe nada vencido no es quien menos debe: va al final.
      sort: (r) => (r.overdueUsd > 0 ? r.overdueUsd : null),
      csv: (r) => csvDinero(r.overdueUsd),
      cell: (r) =>
        r.overdueUsd > 0 ? (
          <>
            <span className="font-semibold">{formatUsd(r.overdueUsd)}</span>
            {r.overdueDesglose && (
              <span className="mt-0.5 block whitespace-nowrap type-panel-caption font-normal text-on-surface-variant">
                {desgloseCorto(r.overdueDesglose)}
              </span>
            )}
            {ctx.tasa !== null && (
              <span className="mt-0.5 block type-panel-caption font-normal text-on-surface-variant">
                {formatVes(r.overdueUsd * ctx.tasa)}
              </span>
            )}
          </>
        ) : (
          <span className="text-on-surface-variant">—</span>
        ),
    },

    {
      key: 'porVencer',
      header: 'Por vencer (financiamiento + comisión)',
      type: 'number',
      sortDir: 'desc',
      info: `Las cuotas de este paciente sin pagar que vencen ${hastaElDia ? `de hoy al ${hastaElDia}` : 'de hoy en adelante'}: financiamiento + Comisión Helios, con sus dos partes y el día de la primera debajo.`,
      sort: (r) => (r.upcomingUsd > 0 ? r.upcomingUsd : null),
      csv: (r) => csvDinero(r.upcomingUsd),
      cell: (r) =>
        r.upcomingUsd > 0 ? (
          <>
            <span>{formatUsd(r.upcomingUsd)}</span>
            {r.upcomingDesglose && (
              <span className="mt-0.5 block whitespace-nowrap type-panel-caption text-on-surface-variant">
                {desgloseCorto(r.upcomingDesglose)}
              </span>
            )}
            {r.overdueUsd <= 0 && (
              <span className="mt-0.5 block type-panel-caption text-on-surface-variant">
                vence el {formatDay(r.nextDueDate)}
              </span>
            )}
          </>
        ) : (
          <span className="text-on-surface-variant">—</span>
        ),
    },

    {
      key: 'atraso',
      header: 'Atraso',
      type: 'number',
      sortDir: 'desc',
      info: 'Los días desde el vencimiento de su cuota sin pagar más antigua, y su tramo de atraso.',
      sort: (r) => r.daysOverdue,
      csv: (r) => csvEntero(r.daysOverdue),
      cell: (r) => {
        const tramo = ctx.cortes ? tramoDeFila(r, ctx.cortes) : null
        if (r.daysOverdue <= 0) return <span className="text-on-surface-variant">—</span>
        return (
          <>
            <span>{r.daysOverdue} d</span>
            {tramo && ctx.cortes && (
              <span className="mt-0.5 block type-panel-caption text-on-surface-variant">
                {rotuloDeTramo(tramo, ctx.cortes)}
              </span>
            )}
          </>
        )
      },
    },

    columnaDeSenales(ctx),

    {
      key: 'perfil',
      header: 'Perfil',
      // Va también bajo el nombre; la columna, para ordenar por prioridad y
      // leer el motivo.
      hidden: true,
      info: 'Cómo se comporta como deudor, de lo que ha pagado, prometido y contestado. Ordena por prioridad: primero a quien hay que llamar antes. Sin perfil: no tiene nada vencido y no hay que vigilarlo, o lo que debe ya se dio por perdido.',
      // El orden de la base: 1 es a quien se llama primero. Sin perfil, al final.
      sort: (r) => r.orden,
      csv: (r) => (r.perfil ? ROTULO_PERFIL[r.perfil] : null),
      cell: (r) =>
        r.perfil ? (
          <span className="flex flex-col items-start gap-1">
            <Badge tone={TONO_PRIORIDAD[r.prioridad ?? PRIORIDAD_DEL_PERFIL[r.perfil]]}>
              {ROTULO_PERFIL[r.perfil]}
            </Badge>
            {r.motivo && (
              <span title={r.motivo} className="block max-w-56 truncate type-panel-caption text-on-surface-variant">
                {r.motivo}
              </span>
            )}
          </span>
        ) : (
          <span className="text-on-surface-variant">—</span>
        ),
    },

    {
      key: 'contacto',
      header: 'Último contacto',
      sortDir: 'desc',
      // Sin contactar va al final en los dos sentidos: no es el contacto más
      // viejo, es que no hay ninguno.
      sort: (r) => r.lastContactAt,
      csv: (r) =>
        r.lastContactAt
          ? [
              csvInstante(r.lastContactAt),
              r.lastContactChannel ? ROTULO_CANAL[r.lastContactChannel] : '',
              r.lastContactOutcome ? RESULTADO[r.lastContactOutcome].label : '',
            ]
              .filter(Boolean)
              .join(' · ')
          : null,
      info: 'La última gestión anotada. «Sin contactar desde que venció»: debe algo vencido y nadie le ha contactado desde el vencimiento de su cuota más antigua, el recorte «Vencidos sin contactar».',
      cell: (r) =>
        r.lastContactAt ? (
          <>
            <span className="flex flex-wrap items-center gap-1.5 text-on-surface">
              {r.lastContactChannel ? ROTULO_CANAL[r.lastContactChannel] : 'Gestión'}
              {r.lastContactBy && ` · ${r.lastContactBy.split(' ')[0]}`}
              <InsigniaResultado resultado={r.lastContactOutcome} />
            </span>
            <span className="mt-0.5 block type-panel-caption tabular-nums text-on-surface-variant">
              {formatDateTime(r.lastContactAt)}
            </span>
            {r.lastContactNote && (
              <span className="mt-0.5 block max-w-48 truncate type-panel-caption italic text-on-surface-variant">
                «{r.lastContactNote}»
              </span>
            )}
            {/* La gestión es de antes de que venciera: para la cola sigue sin contactar. */}
            {r.overdueUsd > 0 && !r.contactedSinceDue && (
              <span className="mt-1 block">
                <Badge tone="warning" icono>
                  Sin contactar desde que venció
                </Badge>
              </span>
            )}
          </>
        ) : r.overdueUsd > 0 ? (
          // Debe algo vencido y nadie le ha llamado: es a quien hay que llamar.
          <Badge tone="warning" icono>
            Sin contactar
          </Badge>
        ) : (
          <span className="type-panel-caption text-on-surface-variant">Sin contactar</span>
        ),
    },

    {
      key: 'proxima',
      header: 'Próxima acción',
      info: 'El día para volver a llamar que se anotó en la última gestión.',
      sort: (r) => r.lastContactNextActionOn,
      csv: (r) => r.lastContactNextActionOn,
      cell: (r) => {
        const accion = proximaAccion(r.lastContactNextActionOn, ctx.hoy)
        if (!accion) return <span className="text-on-surface-variant">—</span>
        if (accion.cuando === 'hoy') {
          return (
            <Badge tone="warning" icono>
              Hoy
            </Badge>
          )
        }
        if (accion.cuando === 'atrasada') {
          return (
            <Badge tone="error" icono>
              {formatDay(accion.fecha)}
            </Badge>
          )
        }
        return <span className="text-on-surface">{formatDay(accion.fecha)}</span>
      },
    },

    {
      key: 'promesa',
      header: 'Promesa',
      // La promesa vigente y la rota ya son señales.
      hidden: true,
      info: 'La última promesa de pago y en qué quedó. No cambia lo que hace el estado automático.',
      sort: (r) => r.promiseDate,
      csv: (r) =>
        r.promiseDate
          ? `${r.promiseDate}${r.promiseStatus ? ` · ${ESTADOS_PROMESA[r.promiseStatus].label}` : ''}`
          : null,
      cell: (r) =>
        r.promiseDate ? (
          <span className="flex flex-col items-start gap-1">
            <span className="type-panel-caption tabular-nums text-on-surface-variant">
              {formatDay(r.promiseDate)}
            </span>
            <InsigniaPromesa estado={r.promiseStatus} />
          </span>
        ) : (
          <span className="text-on-surface-variant">—</span>
        ),
    },

    {
      key: 'acciones',
      header: '',
      cell: (r) => (
        <div className="flex items-start gap-1">
          <BotonWhatsAppCobranza userId={r.userId} persona={r} compacto />
          <BotonAnotarGestion userId={r.userId} nombre={r.fullName ?? 'este paciente'} compacto />
        </div>
      ),
    },
  ]
}
