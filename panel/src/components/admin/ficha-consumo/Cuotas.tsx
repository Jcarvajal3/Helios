import { Link } from '@tanstack/react-router'

import {
  Badge,
  Seccion,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatDay,
  formatMoneda,
  formatUsd,
} from '@/components/ui'
import type { ChargeDetail, ChargeInstallment } from '@/features/admin/consumos'
import { textoDeDesgloseCorto } from '@/features/admin/metricas/formato'

/**
 * Todas las cuotas del consumo, cada una con su dueño.
 *
 * «1 de 2» cuenta dentro de la deuda de ESA persona, no dentro del cargo: en
 * un consumo repartido entre cuatro hay ocho cuotas y ninguna es «la 7 de 8».
 */
export function Cuotas({ detail }: { detail: ChargeDetail }) {
  const porPersona = new Map<string, number>()
  for (const i of detail.installments) {
    const key = i.userId ?? ''
    porPersona.set(key, (porPersona.get(key) ?? 0) + 1)
  }
  const variasPersonas = porPersona.size > 1

  return (
    <Seccion
      titulo="Las cuotas"
      info="Cada una con su dueño. «1 de 2» cuenta dentro de la deuda de ese paciente, no dentro del financiamiento."
    >
      <Table
        headers={[
          ...(variasPersonas ? ['Quién'] : []),
          'Cuota',
          'Vence',
          { label: 'Cuota (financiamiento + fee)', info: 'Lo que se paga en esa cuota: financiamiento + service fee (IVA incluido). Debajo, sus dos partes.' },
          'Estado',
        ]}
      >
        {detail.installments.map((i) => (
          <Tr key={i.id}>
            {variasPersonas && (
              <Td className="whitespace-nowrap">
                {i.userId ? (
                  <Link
                    to="/admin/pacientes/$id"
                    params={{ id: i.userId }}
                    className="text-on-surface hover:underline"
                  >
                    {i.fullName ?? 'Sin nombre'}
                  </Link>
                ) : (
                  <span className="text-on-surface-variant">Sin nombre</span>
                )}
              </Td>
            )}
            <Td className="whitespace-nowrap">
              {i.sequence} de {porPersona.get(i.userId ?? '') ?? detail.installments.length}
            </Td>
            <Td className="whitespace-nowrap">{formatDay(i.dueDate)}</Td>
            <Td className="whitespace-nowrap tabular-nums">
              {formatUsd(i.amountUsd)}
              <span className="block type-panel-caption text-on-surface-variant">
                {textoDeDesgloseCorto({ financedUsd: i.financedUsd, feeUsd: i.amountUsd - i.financedUsd })}
              </span>
              {/* En una orden en euros, lo que paga el paciente es esto, a la
                  tasa BCV del euro del día en que paga. */}
              {detail.currency === 'EUR' && (
                <span className="block type-panel-caption text-on-surface-variant">
                  {formatMoneda(i.amountCur, 'EUR')} en euros
                </span>
              )}
            </Td>
            <Td>
              <EstadoCuota cuota={i} />
            </Td>
          </Tr>
        ))}
      </Table>
    </Seccion>
  )
}

function EstadoCuota({ cuota }: { cuota: ChargeInstallment }) {
  if (cuota.writtenOffAt) {
    return (
      <Badge tone="error" icono>
        Perdida
      </Badge>
    )
  }

  if (cuota.status === 'paid') {
    return (
      <>
        <Badge tone="success" icono>
          Pagada
        </Badge>
        <span className="mt-0.5 block type-panel-caption text-on-surface-variant">
          {formatDateTime(cuota.paidAt)}
        </span>
      </>
    )
  }

  if (cuota.daysOverdue > 0) {
    return (
      <Badge tone="error" icono>
        Vencida hace {cuota.daysOverdue} {cuota.daysOverdue === 1 ? 'día' : 'días'}
      </Badge>
    )
  }

  return <Badge>Por vencer</Badge>
}

