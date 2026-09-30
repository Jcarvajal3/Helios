import { Link } from '@tanstack/react-router'

import { ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { InsigniaPromesa, InsigniaResultado } from '@/components/admin/ficha-persona/CobranzaInsignias'
import { Badge, Tooltip, formatDateTime, formatDay, formatUsd, formatPhone } from '@/components/ui'
import { RESULTADO, ROTULO_CANAL } from '@/features/admin/cobranza/gestion'
import type { Promesa } from '@/features/admin/cobranza/promesas'
import { estadoDePagoReportado, ESTADOS_PROMESA } from '@/features/admin/estados'
import { csvDinero, csvEntero, csvInstante } from '@/lib/csv'

/**
 * Las columnas de Promesas. `alAbrirCaso` apunta la cola antes de que el
 * nombre lleve al caso, igual que la fila y en el orden que se ve.
 */
export function columnasPromesas(
  alAbrirCaso: (enPantalla: Promesa[]) => void,
): Array<Column<Promesa>> {
  return [
    {
      key: 'persona',
      header: 'Paciente',
      identity: true,
      sort: (p) => p.nombre,
      csv: (p) => p.nombre,
      cell: (p, enPantalla) => (
        <>
          <Link
            to="/admin/pacientes/$id"
            params={{ id: p.userId }}
            search={{ tab: 'cobranza' }}
            onClick={() => alAbrirCaso(enPantalla)}
            className={ENLACE_EN_CELDA}
          >
            {p.nombre ?? 'Sin nombre'}
          </Link>
          <p className="mt-0.5 type-panel-caption tabular-nums text-on-surface-variant">
            {formatPhone(p.telefono)}
          </p>
        </>
      ),
    },

    {
      key: 'fecha',
      header: 'Prometió pagar el',
      sort: (p) => p.fecha,
      csv: (p) => p.fecha,
      cell: (p) => <span className="tabular-nums">{formatDay(p.fecha)}</span>,
    },

    {
      key: 'estado',
      header: 'Estado',
      info: 'Se cumple con un pago reportado entre la gestión y el final del día operativo prometido. Si ese pago se rechaza deja de contar: vuelve a pendiente o, si el día ya pasó, a rota.',
      sort: (p) => ESTADOS_PROMESA[p.estado].label,
      csv: (p) => `${ESTADOS_PROMESA[p.estado].label}${p.renegociada ? ' · renegociada' : ''}`,
      cell: (p) => (
        <span className="flex flex-wrap items-center gap-1.5">
          <InsigniaPromesa estado={p.estado} />
          {p.renegociada && (
            <Tooltip contenido="El paciente hizo otra promesa después de esta.">
              <span tabIndex={0} className="inline-flex rounded-full">
                <Badge>Renegociada</Badge>
              </span>
            </Tooltip>
          )}
        </span>
      ),
    },

    {
      key: 'gestion',
      header: 'Gestión',
      sortDir: 'desc',
      sort: (p) => p.contactadoEl,
      csv: (p) =>
        [
          csvInstante(p.contactadoEl),
          ROTULO_CANAL[p.canal],
          p.quien,
          p.resultado ? RESULTADO[p.resultado].label : '',
          p.nota ?? '',
        ]
          .filter(Boolean)
          .join(' · '),
      cell: (p) => (
        <>
          <span className="flex flex-wrap items-center gap-1.5 text-on-surface">
            {ROTULO_CANAL[p.canal]} · {p.quien.split(' ')[0]}
            <InsigniaResultado resultado={p.resultado} />
          </span>
          <span className="mt-0.5 block type-panel-caption tabular-nums text-on-surface-variant">
            {formatDateTime(p.contactadoEl)}
          </span>
          {p.nota && (
            <span className="mt-0.5 block max-w-56 truncate type-panel-caption italic text-on-surface-variant">
              «{p.nota}»
            </span>
          )}
        </>
      ),
    },

    {
      key: 'deuda',
      header: 'Vencido hoy (financiado + service fee + IVA)',
      type: 'number',
      sortDir: 'desc',
      info: 'Cuotas del paciente sin pagar con vencimiento anterior a hoy (día operativo): financiado (sin fee) más service fee + IVA, que se ven debajo por separado. Sin cargos por atraso.',
      sort: (p) => p.vencidoHoyUsd,
      csv: (p) => csvDinero(p.vencidoHoyUsd),
      cell: (p) =>
        p.vencidoHoyUsd > 0 ? (
          <>
            <span className="font-semibold">{formatUsd(p.vencidoHoyUsd)}</span>
            <span className="mt-0.5 block type-panel-caption text-on-surface-variant">
              Financiado {formatUsd(p.vencidoHoyFinancedUsd)} + service fee + IVA {formatUsd(p.vencidoHoyFeeUsd)}
            </span>
            <span className="block type-panel-caption text-on-surface-variant">
              {p.diasDeAtraso} d de atraso
            </span>
          </>
        ) : (
          <span className="text-on-surface-variant">Nada vencido</span>
        ),
    },

    {
      key: 'pago',
      header: 'Último pago reportado (con fee)',
      info: 'El último pago que el paciente reportó después de la gestión, en cualquier estado: sus cuotas con service fee + IVA y los cargos por atraso que saldaba.',
      sortDir: 'desc',
      sort: (p) => p.ultimoPago?.creadoEl ?? null,
      csv: (p) =>
        p.ultimoPago
          ? `${csvDinero(p.ultimoPago.montoUsd)} · ${estadoDePagoReportado(p.ultimoPago.estado).label} · ${csvInstante(p.ultimoPago.creadoEl)}`
          : null,
      cell: (p) =>
        p.ultimoPago ? (
          <span className="flex flex-col items-start gap-1">
            <span className="flex flex-wrap items-center gap-1.5">
              <Link
                to="/admin/cobros/$id"
                params={{ id: p.ultimoPago.id }}
                className="tabular-nums text-on-surface underline decoration-panel-muted underline-offset-2 hover:decoration-on-surface"
              >
                {formatUsd(p.ultimoPago.montoUsd)}
              </Link>
              <EstadoBadge tipo="pago" valor={p.ultimoPago.estado} />
            </span>
            <span className="type-panel-caption tabular-nums text-on-surface-variant">
              {formatDateTime(p.ultimoPago.creadoEl)}
            </span>
          </span>
        ) : (
          <span className="text-on-surface-variant">Ninguno</span>
        ),
    },

    {
      key: 'dias',
      header: 'Días de atraso',
      hidden: true,
      type: 'number',
      sort: (p) => p.diasDeAtraso,
      csv: (p) => csvEntero(p.diasDeAtraso),
      cell: (p) => (p.diasDeAtraso > 0 ? `${p.diasDeAtraso} d` : '—'),
    },
  ]
}
