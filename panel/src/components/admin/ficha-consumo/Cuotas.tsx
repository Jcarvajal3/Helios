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
import { esLaInicial, rotuloDeCuota } from '@/features/admin/rotuloDeCuota'

/**
 * Todas las cuotas del consumo, cada una con su dueño.
 *
 * «1 de 2» cuenta dentro de la deuda de ESA persona, no dentro del cargo: en
 * un consumo repartido entre cuatro hay ocho cuotas y ninguna es «la 7 de 8».
 *
 * La inicial (`sequence` 0, 2026-11-12) sale primero y se llama «Inicial»; no
 * cuenta en el «de 2»: el plan sigue siendo de dos cuotas.
 */
export function Cuotas({ detail }: { detail: ChargeDetail }) {
  const porPersona = new Map<string, number>()
  const personas = new Set<string>()
  for (const i of detail.installments) {
    const key = i.userId ?? ''
    personas.add(key)
    if (esLaInicial(i.sequence)) continue
    porPersona.set(key, (porPersona.get(key) ?? 0) + 1)
  }
  const variasPersonas = personas.size > 1

  return (
    <Seccion
      titulo="Las cuotas"
      info="Cada una con su dueño. «1 de 2» cuenta dentro de la deuda de ese paciente, no dentro del financiamiento. La inicial (en las órdenes desde el 2026-11-12) vence el día del «Sí», se queda en Helios y nunca cuenta como vencida: si no se paga a tiempo, la orden se anula sola."
    >
      <Table
        headers={[
          ...(variasPersonas ? ['Quién'] : []),
          'Cuota',
          'Vence',
          { label: 'Cuota (financiamiento + comisión)', info: 'Lo que se paga en esa cuota: financiamiento + Comisión Helios (IVA incluido). Debajo, sus dos partes.' },
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
              {rotuloDeCuota(i.sequence, porPersona.get(i.userId ?? ''))}
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

  // La inicial no vence: o se paga o la orden se anula sola.
  if (esLaInicial(cuota.sequence)) {
    return <Badge tone="warning">Por pagar</Badge>
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

