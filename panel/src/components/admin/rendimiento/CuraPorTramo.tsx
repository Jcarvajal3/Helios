import { Sparkline } from '@/components/charts'
import { Table, Td, Tr } from '@/components/ui'
import { periodoDeLaCura } from '@/features/admin/cobranza/rendimiento'
import type { Cura } from '@/features/admin/cobranza/rendimiento'
import { TRAMOS_VENCIDOS } from '@/features/admin/tramos'
import { pctOSinDatos, rotuloDelTramo } from './formato'

/**
 * La cura por tramo: una fila por tramo, con la última semana escrita y las
 * anteriores en una línea. La línea va en verde porque la serie entera es un
 * estado —salir del atraso—, no un dato del área.
 */
export function CuraPorTramo({ cura }: { cura: Cura }) {
  const ultima = cura.semanas.at(-1)
  if (!ultima) {
    return <p className="type-panel-body text-on-surface-variant">Todavía no hay semanas que medir.</p>
  }

  return (
    <Table
      headers={[
        'Tramo',
        {
          label: periodoDeLaCura(ultima),
          info: 'Pacientes al día al cierre ÷ pacientes que estaban en el tramo al empezar la semana.',
        },
        `Las ${cura.semanas.length} semanas que acaban en ella`,
      ]}
    >
      {TRAMOS_VENCIDOS.map((t) => {
        const c = ultima.porTramo[t]
        const serie = cura.semanas.map((s) => s.porTramo[t].pct)
        return (
          <Tr key={t}>
            <Td>{rotuloDelTramo(t, cura.cortes)}</Td>
            <Td className="tabular-nums">
              {c.estaban === 0 ? (
                <span className="text-panel-muted">Nadie en el tramo</span>
              ) : (
                <>
                  {pctOSinDatos(c.pct)}{' '}
                  <span className="text-panel-muted">
                    ({c.curados} de {c.estaban})
                  </span>
                </>
              )}
            </Td>
            <Td className="w-48">
              <Sparkline
                values={serie}
                tone="success"
                label={`Pacientes al día del tramo ${rotuloDelTramo(t, cura.cortes)} en las ${serie.length} semanas`}
              />
            </Td>
          </Tr>
        )
      })}
    </Table>
  )
}
