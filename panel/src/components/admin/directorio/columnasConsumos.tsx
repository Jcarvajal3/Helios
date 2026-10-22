import { Link } from '@tanstack/react-router'

import { ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { AnularConsumo } from '@/components/admin/directorio/AnularConsumo'
import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { Badge, formatDay, formatUsd, formatPhone, formatTime } from '@/components/ui'
import {
  ESTADOS_CONSUMO,
  VALORES_ESTADO_CONSUMO,
  estadoDeConsumo,
} from '@/features/admin/estados'
import type { ChargeRow } from '@/features/admin/ops'
import { csvDinero, csvInstante } from '@/lib/csv'

/**
 * Las columnas de la lista de consumos.
 *
 * La ancla es el número de orden: es lo que identifica la fila y lo único que
 * el local dice por teléfono. El importe es el consumo sin la Comisión Helios;
 * la comisión va en las cuotas y en la factura de cada consumo.
 */
export const COLUMNAS_CONSUMOS: Array<Column<ChargeRow>> = [
  {
    key: 'orden',
    header: '# Orden',
    identity: true,
    type: 'number',
    sort: (c) => c.orderNumber,
    csv: (c) => c.orderNumber,
    cell: (c) =>
      c.orderNumber === null ? (
        <span className="text-on-surface-variant">—</span>
      ) : (
        <span className="font-medium text-on-surface">#{c.orderNumber}</span>
      ),
  },

  {
    key: 'dia',
    header: 'Día operativo',
    info: 'El día operativo, de medianoche a medianoche en Caracas. Debajo, la hora.',
    sortDir: 'desc',
    sort: (c) => c.confirmedAt ?? c.createdAt,
    csv: (c) => c.businessDate,
    cell: (c) => (
      <span className="block whitespace-nowrap">
        {formatDay(c.businessDate)}
        <span className="block type-panel-caption text-on-surface-variant">
          {formatTime(c.confirmedAt ?? c.createdAt)}
        </span>
      </span>
    ),
  },

  {
    key: 'hora',
    header: 'Hora',
    hidden: true,
    csv: (c) => csvInstante(c.confirmedAt ?? c.createdAt),
    cell: (c) => formatTime(c.confirmedAt ?? c.createdAt),
  },

  {
    key: 'persona',
    header: 'Paciente',
    info: 'El paciente que paga la consulta en cuotas.',
    sort: (c) => c.fullName,
    csv: (c) => c.fullName,
    cell: (c) =>
      c.userId ? (
        <>
          <Link
            to="/admin/pacientes/$id"
            params={{ id: c.userId }}
            className={ENLACE_EN_CELDA}
          >
            {c.fullName ?? 'Sin nombre'}
          </Link>
          <p className="type-panel-caption tabular-nums text-on-surface-variant">
            {formatPhone(c.phone)}
          </p>
        </>
      ) : (
        <span className="text-on-surface-variant">
          Sin paciente
        </span>
      ),
  },

  { key: 'telefono', header: 'Teléfono', hidden: true, csv: (c) => c.phone, cell: (c) => formatPhone(c.phone) },

  {
    // El médico titular y no el nombre de la clínica (2026-10-22): es como lo
    // conoce el equipo. La clínica queda en su columna, escondida.
    key: 'local',
    header: 'Médico',
    sort: (c) => c.doctorName ?? c.merchantName,
    csv: (c) => c.doctorName ?? c.merchantName,
    cell: (c) => (
      <span className="flex flex-wrap items-center gap-2">
        <Link
          to="/admin/clinicas/$id"
          params={{ id: c.merchantId }}
          className={ENLACE_EN_CELDA}
        >
          {c.doctorName ?? c.merchantName}
        </Link>
        {c.isTest && <Badge tone="neutral">Prueba</Badge>}
      </span>
    ),
  },

  {
    key: 'clinica',
    header: 'Clínica',
    hidden: true,
    sort: (c) => c.merchantName,
    csv: (c) => c.merchantName,
    cell: (c) => c.merchantName,
  },

  {
    key: 'consumo',
    header: 'Financiado (sin comisión)',
    info: 'Sin la Comisión Helios: lo que se financió en la clínica, que es lo que ocupó cupo; la Comisión Helios + IVA va repartido en las cuotas.',
    type: 'number',
    sortDir: 'desc',
    sort: (c) => c.financedUsd,
    csv: (c) => csvDinero(c.financedUsd),
    cell: (c) => (
      <span className="font-semibold">
        {formatUsd(c.financedUsd)}
      </span>
    ),
  },

  {
    key: 'cuotas',
    header: 'Cuotas cobradas',
    info: 'Cuotas cobradas sobre el total de cuotas del financiamiento, de todos los pacientes que pagan en él.',
    hidden: true,
    type: 'number',
    // Por lo que queda por pagar: «1 de 2» y «1 de 6» no son lo mismo.
    sort: (c) => (c.installmentsTotal > 0 ? c.installmentsTotal - c.installmentsPaid : null),
    csv: (c) => (c.installmentsTotal > 0 ? `${c.installmentsPaid} de ${c.installmentsTotal}` : null),
    cell: (c) => (
      <span className="text-on-surface-variant">
        {c.installmentsTotal > 0 ? `${c.installmentsPaid} de ${c.installmentsTotal} cobradas` : '—'}
      </span>
    ),
  },

  {
    key: 'estado',
    header: 'Estado',
    info: VALORES_ESTADO_CONSUMO.map((v) => `${ESTADOS_CONSUMO[v].label}: ${ESTADOS_CONSUMO[v].que}`).join(' '),
    sort: (c) => estadoDeConsumo(c.status).label,
    csv: (c) => estadoDeConsumo(c.status).label,
    cell: (c) => (
      <>
        <EstadoBadge tipo="consumo" valor={c.status} />
        {c.voidReason && (
          <span className="mt-1 block max-w-48 type-panel-caption text-on-surface-variant">
            {c.voidReason}
          </span>
        )}
      </>
    ),
  },

  // Solo para el archivo: sin ella, un CSV no distingue uno de prueba, y una
  // suma en Excel mete los de prueba.
  {
    key: 'prueba',
    header: 'Prueba',
    hidden: true,
    sort: (c) => (c.isTest ? 1 : 0),
    csv: (c) => (c.isTest ? 'Sí' : null),
    cell: (c) => (c.isTest ? 'Sí' : '—'),
  },

  {
    key: 'anular',
    header: '',
    cell: (c) =>
      c.status === 'pending' ? (
        <AnularConsumo chargeId={c.chargeId} financedUsd={c.financedUsd} merchantName={c.merchantName} />
      ) : null,
  },
]
