import { Link } from '@tanstack/react-router'
import { Paperclip } from 'lucide-react'

import { ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { Badge, formatDay, formatMoneda, formatUsd, formatVes } from '@/components/ui'
import type { Payout } from '@/features/admin/api'
import { nombreDelMedio } from '@/features/admin/liquidaciones'
import { csvDinero } from '@/lib/csv'

/**
 * Las columnas de una lista de transferencias a locales.
 *
 * Las usan el histórico de Pagos a locales y la página de un local, que es la
 * misma lista acotada a uno: por eso la columna del local es opcional.
 *
 * Se ordena por la fecha del BANCO y no por la del registro: la pregunta es
 * «¿qué salió esta semana?», y esa es la fecha que se coteja con el extracto.
 */
export function columnasDeTransferencias({ conLocal }: { conLocal: boolean }): Array<Column<Payout>> {
  const local: Column<Payout> = {
    key: 'local',
    header: 'Clínica',
    sort: (p) => p.merchantName,
    csv: (p) => p.merchantName,
    cell: (p) => (
      <span className="flex items-center gap-2">
        <Link
          to="/admin/clinicas/$id"
          params={{ id: p.merchantId }}
          className={ENLACE_EN_CELDA}
        >
          {p.merchantName}
        </Link>
        {p.isTest && <Badge tone="neutral">Prueba</Badge>}
      </span>
    ),
  }

  return [
    {
      key: 'fecha',
      header: 'Salió del banco',
      identity: true,
      sort: (p) => p.paidOn,
      sortDir: 'desc',
      csv: (p) => p.paidOn,
      cell: (p) => (
        <span className="block whitespace-nowrap">
          {formatDay(p.paidOn)}
          {p.businessDate !== p.paidOn && (
            <span className="block type-panel-caption text-on-surface-variant">
              registrada el {formatDay(p.businessDate)}
            </span>
          )}
        </span>
      ),
    },
    ...(conLocal ? [local] : []),
    {
      key: 'monto',
      header: 'Monto',
      type: 'number',
      info: 'Lo transferido a la clínica: sus consultas enteras (sin la Comisión Helios, que paga el paciente) más las comisiones de su personal. Debajo, partido y en bolívares; si llevaba liquidaciones de órdenes cobradas en euros, cuánto era en euros (pagado a la tasa del euro).',
      sort: (p) => p.amountUsd,
      sortDir: 'desc',
      csv: (p) => csvDinero(p.amountUsd),
      cell: (p) => (
        <>
          <span className="font-semibold">{formatUsd(p.amountUsd)}</span>
          {p.desglose && (
            <span className="block whitespace-nowrap type-panel-caption font-normal text-on-surface-variant">
              consultas {formatUsd(p.desglose.consultasUsd)} + comisiones {formatUsd(p.desglose.comisionesUsd)}
            </span>
          )}
          {p.amountVes !== null && (
            <span className="block type-panel-caption font-normal text-on-surface-variant">
              {formatVes(p.amountVes)}
            </span>
          )}
          {p.amountEur !== null && p.amountEur > 0 && (
            <span className="block whitespace-nowrap type-panel-caption font-normal text-on-surface-variant">
              con {formatMoneda(p.amountEur, 'EUR')} en euros
            </span>
          )}
        </>
      ),
    },
    {
      key: 'monto-ves',
      header: 'Monto en bolívares',
      type: 'number',
      hidden: true,
      csv: (p) => (p.amountVes === null ? null : csvDinero(p.amountVes)),
      cell: (p) => (p.amountVes === null ? '—' : formatVes(p.amountVes)),
    },
    {
      key: 'monto-eur',
      header: 'Parte en euros',
      type: 'number',
      hidden: true,
      csv: (p) => (p.amountEur === null ? null : csvDinero(p.amountEur)),
      cell: (p) => (p.amountEur === null ? '—' : formatMoneda(p.amountEur, 'EUR')),
    },
    {
      key: 'tasa-eur',
      header: 'Tasa del euro',
      type: 'number',
      hidden: true,
      csv: (p) => (p.fxRateEur === null ? null : csvDinero(p.fxRateEur, 6)),
      cell: (p) => (p.fxRateEur === null ? '—' : p.fxRateEur.toLocaleString('es-VE')),
    },
    {
      key: 'tasa',
      header: 'Tasa del dólar',
      type: 'number',
      hidden: true,
      csv: (p) => (p.fxRate === null ? null : csvDinero(p.fxRate, 6)),
      cell: (p) => (p.fxRate === null ? '—' : p.fxRate.toLocaleString('es-VE')),
    },
    {
      key: 'medio',
      header: 'Medio',
      sort: (p) => p.method,
      csv: (p) => nombreDelMedio(p.method),
      cell: (p) => (
        <span className="flex items-center gap-1 whitespace-nowrap">
          {nombreDelMedio(p.method)}
          {p.tieneComprobante && (
            <Paperclip size={12} aria-label="Con comprobante" className="text-on-surface-variant" />
          )}
        </span>
      ),
    },
    {
      key: 'referencia',
      header: 'Referencia',
      sort: (p) => p.reference,
      csv: (p) => p.reference,
      cell: (p) => <span className="text-on-surface-variant">{p.reference ?? '—'}</span>,
    },
    {
      key: 'cubrio',
      header: 'Cubrió',
      sort: (p) => p.lineas,
      csv: (p) => p.lineas,
      cell: (p) => (
        <span className="text-on-surface-variant">
          {p.lineas} {p.lineas === 1 ? 'liquidación' : 'liquidaciones'}
          {p.primerVencimiento && (
            <span className="block type-panel-caption">
              con vencimiento del {formatDay(p.primerVencimiento)} al{' '}
              {formatDay(p.ultimoVencimiento)}
            </span>
          )}
        </span>
      ),
    },
    {
      key: 'quien',
      header: 'Quién la registró',
      sort: (p) => p.actorName,
      csv: (p) => p.actorName,
      cell: (p) => <span className="text-on-surface-variant">{p.actorName ?? '—'}</span>,
    },
  ]
}

/** Lo transferido de verdad: sin los locales de prueba. */
export function totalTransferido(pagos: ReadonlyArray<Payout>): number {
  return pagos.filter((p) => !p.isTest).reduce((sum, p) => sum + p.amountUsd, 0)
}
