import { useNavigate } from '@tanstack/react-router'

import { EstadoBadge } from '@/components/admin/EstadoBadge'
import {
  Card,
  Seccion,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatUsd,
} from '@/components/ui'
import type { UserDetail } from '@/features/admin/users'
import { desgloseDelPago } from './desgloseDelPago'

// ── 5. Pagos ───────────────────────────────────────────────────────────────

/**
 * Los pagos que reportó desde la app. Cada fila abre la ficha del pago, que
 * es donde se aprueba, se rechaza o se ve contra qué abono del banco cuadró.
 */
export function PestanaPagos({ user }: { user: UserDetail }) {
  const navigate = useNavigate()

  if (user.payments.length === 0) {
    return (
      <Card>
        <p className="type-panel-body text-on-surface-variant">
          Todavía no ha reportado ningún pago.
        </p>
      </Card>
    )
  }

  return (
    <Seccion titulo="Pagos reportados" info="Los pagos registrados de este paciente. Cada fila abre la ficha del pago, donde se aprueba, se rechaza o se ve contra qué movimiento del banco cuadró.">
      <Table
        headers={[
          'Cuándo',
          'Banco',
          'Referencia',
          {
            label: 'Monto reportado',
            info: 'Lo que transfirió: sus cuotas (financiamiento + service fee) más los cargos por atraso que llevaba el pago.',
          },
          'Estado',
        ]}
      >
        {user.payments.map((p) => (
          <Tr
            key={p.id}
            onClick={() => void navigate({ to: '/admin/cobros/$id', params: { id: p.id } })}
          >
            <Td className="whitespace-nowrap">{formatDateTime(p.createdAt)}</Td>
            <Td className="text-on-surface-variant">{p.bank ?? p.method}</Td>
            <Td className="font-mono type-panel-caption">{p.reference ?? '—'}</Td>
            <Td className="tabular-nums">
              {formatUsd(p.amountUsd)}
              {p.partes && (
                <span className="block type-panel-caption text-on-surface-variant">
                  {desgloseDelPago(p.partes)}
                </span>
              )}
            </Td>
            <Td>
              <EstadoBadge tipo="pago" valor={p.status} />
              {p.rejectionNote && (
                <span className="mt-1 block max-w-48 type-panel-caption text-on-surface-variant">
                  {p.rejectionNote}
                </span>
              )}
            </Td>
          </Tr>
        ))}
      </Table>
    </Seccion>
  )
}
