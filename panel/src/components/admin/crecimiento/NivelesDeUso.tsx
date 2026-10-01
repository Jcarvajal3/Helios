import { useNavigate } from '@tanstack/react-router'

import { Seccion, Table, Td, Tr, formatUsd, formatPorcentaje } from '@/components/ui'
import type { UserBehavior } from '@/features/admin/growth'

/**
 * Los niveles: cuántos registros hay en cada uno (por su nivel de hoy), cuántos
 * consumieron en la ventana y cuánto se le facturó a cada uno. Cada fila abre
 * Ajustes › Niveles y cupos.
 *
 * Con un local, cuánta gente hay en cada nivel es del padrón y no se parte:
 * esas dos columnas no se enseñan, y quedan las del consumo en el local.
 */
export function NivelesDeUso({ niveles }: { niveles: UserBehavior['levels'] }) {
  const navigate = useNavigate()
  const conPadron = niveles.every((n) => n.users !== null)
  const abrir = () => void navigate({ to: '/admin/ajustes', search: { tab: 'niveles' } })

  const cabeceras = conPadron
    ? [
        'Nivel',
        { label: 'Registros', info: 'Los registros con ese nivel hoy (el nivel fija el cupo).' },
        { label: 'Pacientes que se financiaron', info: 'Cuántos de ese nivel se financiaron en la ventana.' },
        { label: 'Se financiaron (%)', info: 'Los que se financiaron en la ventana entre los registros del nivel.' },
        { label: 'Financiado (sin fee)', info: 'Sin el service fee: lo financiado en la ventana a los pacientes de ese nivel.' },
        {
          label: 'Financiado por paciente (sin fee)',
          info: 'Sin el service fee: el financiado del nivel entre los pacientes que se financiaron. La columna que dice si la escalera sirve: si un nivel 3 se financia lo mismo por paciente que un nivel 1, el cupo extra no lo está usando nadie.',
        },
      ]
    : [
        'Nivel',
        { label: 'Pacientes que se financiaron', info: 'Cuántos pacientes de ese nivel (el de hoy) se financiaron en esta clínica en la ventana.' },
        { label: 'Financiado (sin fee)', info: 'Sin el service fee: lo financiado en esta clínica en la ventana a los pacientes de ese nivel.' },
        { label: 'Financiado por paciente (sin fee)', info: 'Sin el service fee: el financiado del nivel entre los pacientes que se financiaron.' },
      ]

  return (
    <Seccion titulo="Registros y financiado por nivel">
      <Table headers={cabeceras}>
        {niveles.map((n) => {
          const porPersona = n.activeUsers > 0 ? formatUsd(n.financedUsd / n.activeUsers) : '—'
          return (
            <Tr key={n.level} onClick={abrir}>
              <Td className="font-semibold text-on-surface">Nivel {n.level}</Td>
              {conPadron && <Td className="tabular-nums">{n.users}</Td>}
              <Td className="tabular-nums">{n.activeUsers}</Td>
              {conPadron && (
                <Td className="tabular-nums text-on-surface-variant">
                  {n.users ? formatPorcentaje((n.activeUsers / n.users) * 100) : '—'}
                </Td>
              )}
              <Td className="tabular-nums">{formatUsd(n.financedUsd)}</Td>
              <Td className="tabular-nums text-on-surface-variant">{porPersona}</Td>
            </Tr>
          )
        })}
      </Table>
    </Seccion>
  )
}
