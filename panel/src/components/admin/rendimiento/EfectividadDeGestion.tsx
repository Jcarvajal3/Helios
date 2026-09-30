import { BarChart } from '@/components/charts'
import { Table, Td, Tr, formatPct } from '@/components/ui'
import { ROTULO_CANAL } from '@/features/admin/cobranza/gestion'
import type { EfectividadDeCobranza } from '@/features/admin/cobranza/rendimiento'
import { describirPeriodo, pctOSinDatos } from './formato'

/**
 * Qué gestiones acaban en un pago: por canal, en una tabla, y por hora del
 * día, con las que acabaron en pago dentro de cada barra.
 */
export function EfectividadDeGestion({ e }: { e: EfectividadDeCobranza }) {
  return (
    <>
      <Table
        headers={[
          'Canal',
          'Gestiones',
          'Con pago en 72 h',
          { label: 'En ventana', info: 'Gestiones de las últimas 72 horas: todavía pueden acabar en un pago y no cuentan en el porcentaje.' },
          { label: 'Con pago en 72 h (%)', info: 'Con pago en 72 h ÷ gestiones que ya cumplieron las 72 horas.' },
        ]}
      >
        {e.porCanal.map((c) => (
          <Tr key={c.canal}>
            <Td>{ROTULO_CANAL[c.canal]}</Td>
            <Td className="tabular-nums">{c.gestiones}</Td>
            <Td className="tabular-nums">{c.conPago}</Td>
            <Td className="tabular-nums text-on-surface-variant">{c.enVentana}</Td>
            <Td className="tabular-nums">{pctOSinDatos(c.pct)}</Td>
          </Tr>
        ))}
      </Table>

      <BarChart
        title="Gestiones por hora"
        summary={`Hora de Caracas, ${describirPeriodo(e.desde, e.hasta)}`}
        series={[
          { key: 'gestiones', label: 'Gestiones' },
          { key: 'conPago', label: 'Con pago en 72 h' },
        ]}
        points={e.porHora.map((h) => ({
          key: String(h.hora),
          label: `${String(h.hora).padStart(2, '0')}:00`,
          values: [h.gestiones, h.conPago],
          note: h.pct === null ? undefined : `${formatPct(h.pct)} con pago`,
        }))}
        format={(v) => String(v)}
        formatShort={(v) => String(v)}
        ejeLabel="Hora"
        enteros
        footnote="Dentro de cada barra, las gestiones que acabaron en un pago: lo que asoma por encima no lo hizo."
        empty="No hubo gestiones en este periodo."
      />
    </>
  )
}
