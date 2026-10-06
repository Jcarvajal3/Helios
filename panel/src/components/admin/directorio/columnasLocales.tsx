import { Link } from '@tanstack/react-router'
import { CircleAlert } from 'lucide-react'

import type { Column } from '@/components/DataTable'
import { LogoLocal } from '@/components/admin/directorio/LogoLocal'
import { Badge, NoSePudoLeer, formatDateTime, formatUsd } from '@/components/ui'
import { MERCHANT_CATEGORY_LABEL } from '@/features/admin/api'
import type { MerchantRow } from '@/features/admin/api'
import { csvDinero, csvInstante } from '@/lib/csv'
import { ESTADOS_LOCAL } from '@/features/admin/estados'

/** Lo que se le debe a un local: el total y la parte que ya llegó tarde. */
export type Deuda = { total: number; atrasado: number }

/**
 * Lo que se le debe a cada local, o por qué no se sabe.
 *
 * Llega por su lado (`admin_merchant_payables`), y si esa consulta falla la
 * columna dice que no se pudo leer: un guion ahí se leería como «no se le debe
 * nada».
 */
export type PorPagar =
  | { estado: 'listo'; porLocal: ReadonlyMap<string, Deuda> }
  | { estado: 'cargando' }
  | { estado: 'error' }

/**
 * Las columnas de la lista de locales. Es una función porque «Por pagar» no
 * sale de la fila: sale de las liquidaciones pendientes, que llegan aparte.
 */
export function columnasLocales(porPagar: PorPagar): Array<Column<MerchantRow>> {
  const deudaDe = (m: MerchantRow) =>
    porPagar.estado === 'listo' ? (porPagar.porLocal.get(m.id) ?? null) : null

  return [
    {
      key: 'local',
      header: 'Clínica',
      identity: true,
      sort: (m) => m.name,
      csv: (m) => m.name,
      cell: (m) => (
        <div className="flex items-center gap-3">
          <LogoLocal name={m.name} logoUrl={m.logoUrl} />
          <div>
            <p className="font-medium text-on-surface">{m.name}</p>
            <p className="type-panel-caption text-on-surface-variant">
              {m.taxId ?? 'Sin RIF'}
            </p>
          </div>
        </div>
      ),
    },

    { key: 'rif', header: 'RIF', hidden: true, csv: (m) => m.taxId, cell: (m) => m.taxId ?? '—' },

    {
      key: 'razon',
      header: 'Razón social',
      hidden: true,
      sort: (m) => m.legalName,
      csv: (m) => m.legalName,
      cell: (m) => m.legalName ?? '—',
    },

    {
      key: 'categoria',
      header: 'Categoría y ciudad',
      hidden: true,
      sort: (m) => (m.category ? MERCHANT_CATEGORY_LABEL[m.category] : ''),
      csv: (m) =>
        [m.category ? MERCHANT_CATEGORY_LABEL[m.category] : null, m.city].filter(Boolean).join(' · ') ||
        null,
      cell: (m) => (
        <span className="block text-on-surface-variant">
          {m.category ? MERCHANT_CATEGORY_LABEL[m.category] : 'Sin categoría'}
          <span className="mt-0.5 block type-panel-caption">{m.city ?? 'Sin ciudad'}</span>
        </span>
      ),
    },

    {
      key: 'estado',
      header: 'Estado',
      sort: (m) => ESTADOS_LOCAL[m.status].label,
      csv: (m) => `${ESTADOS_LOCAL[m.status].label}${m.isTest ? ' (prueba)' : ''}`,
      cell: (m) => (
        <div className="flex flex-wrap items-center gap-1.5">
          <Badge tone={ESTADOS_LOCAL[m.status].tone} icono>
            {ESTADOS_LOCAL[m.status].label}
          </Badge>
          {m.isTest && <Badge tone="neutral">Prueba</Badge>}
        </div>
      ),
    },

    {
      key: 'ventas',
      header: 'Financiado (sin fee, 30 días)',
      info: 'Sin el service fee: lo financiado en la clínica en financiamientos confirmados de los últimos 30 días operativos (hoy incluido), sin los de prueba; debajo, cuántos financiamientos y cuántos desde el alta.',
      type: 'number',
      // En consumo, sin el service fee: `merchant_directory.financed_30d`
      // suma `coalesce(base_usd, amount_usd)`.
      sortDir: 'desc',
      sort: (m) => m.financed30d,
      csv: (m) => csvDinero(m.financed30d),
      cell: (m) =>
        m.sales30d === 0 ? (
          <span className="text-on-surface-variant">
            —
            <span className="mt-0.5 block type-panel-caption">{m.salesCount} desde el alta</span>
          </span>
        ) : (
          <>
            {formatUsd(m.financed30d)}
            <span className="mt-0.5 block type-panel-caption text-on-surface-variant">
              {m.sales30d} {m.sales30d === 1 ? 'financiamiento' : 'financiamientos'} · {m.salesCount} desde el alta
            </span>
          </>
        ),
    },

    {
      key: 'consumos-30',
      header: 'Financiamientos (30 días)',
      hidden: true,
      type: 'number',
      sortDir: 'desc',
      sort: (m) => m.sales30d,
      csv: (m) => m.sales30d,
      cell: (m) => m.sales30d,
    },

    {
      key: 'por-pagar',
      header: 'Por pagar a la clínica',
      info: 'Lo que Helios le debe a la clínica: liquidaciones devengadas sin transferir más su parte de las cuotas que aún no vencen; debajo, lo que tocaba pagarle ayer o antes y sigue sin transferir; abre la página de sus pagos.',
      type: 'number',
      sortDir: 'desc',
      sort: (m) => deudaDe(m)?.total ?? null,
      csv: (m) => (porPagar.estado === 'listo' ? csvDinero(deudaDe(m)?.total ?? 0) : null),
      cell: (m) => {
        if (porPagar.estado === 'error') return <NoSePudoLeer />
        if (porPagar.estado === 'cargando') return <span className="text-on-surface-variant">…</span>

        const deuda = deudaDe(m)
        if (!deuda || deuda.total <= 0) return <span className="text-on-surface-variant">—</span>
        return (
          <Link
            to="/admin/pagos-clinicas/$id"
            params={{ id: m.id }}
            className="text-on-surface decoration-panel-muted underline-offset-2 hover:underline"
          >
            {formatUsd(deuda.total)}
            {deuda.atrasado > 0 && (
              <span className="mt-0.5 flex items-center justify-end gap-1 type-panel-caption text-on-surface-variant">
                <CircleAlert size={12} aria-hidden className="shrink-0 text-error" />
                {formatUsd(deuda.atrasado)} atrasado
              </span>
            )}
          </Link>
        )
      },
    },

    {
      key: 'personal',
      header: 'Personal',
      hidden: true,
      type: 'number',
      sort: (m) => m.staffCount,
      csv: (m) => m.staffCount,
      cell: (m) => (
        <span className="text-on-surface-variant">
          {m.staffCount} {m.staffCount === 1 ? 'cuenta' : 'cuentas'}
        </span>
      ),
    },

    {
      key: 'alta',
      header: 'Alta',
      hidden: true,
      sortDir: 'desc',
      sort: (m) => m.createdAt,
      csv: (m) => csvInstante(m.createdAt),
      cell: (m) => (
        <span className="whitespace-nowrap type-panel-caption text-on-surface-variant">
          {formatDateTime(m.createdAt)}
        </span>
      ),
    },
  ]
}
