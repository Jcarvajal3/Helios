import { useQuery } from '@tanstack/react-query'

import { StatGrid, Stat, estadoDeConsulta, formatDayShort } from '@/components/ui'
import { CuerpoDelRendimiento } from '@/components/admin/RendimientoCobranza'
import { Cupos } from '@/components/admin/riesgo/Cupos'
import { ImpagoPorCuota } from '@/components/admin/riesgo/ImpagoPorCuota'
import {
  consultaCura,
  consultaEfectividad,
  consultaImpagoDeCuota,
  consultaPromesas,
  consultaRecuperado,
  consultaUsoDelCupo,
} from '@/features/admin/metricas/cobranza/api'
import { tasaDeCumplimiento } from '@/features/admin/cobranza/promesas'
import { otraCuota } from '@/features/admin/riesgo/credito'
import type { DimensionPrimeraCuota, NumeroDeCuota } from '@/features/admin/riesgo/credito'
import { pctOSinDatos } from '@/components/admin/rendimiento/formato'

// ═══════════════════════════════════════════════════════════════════════════
// Las sub-vistas que vienen de Riesgo de crédito y de Por cobrar ›
// Rendimiento, con la semana y el local de Métricas. Las piezas son las de
// siempre (`components/admin/riesgo/*`, `RendimientoCobranza`); aquí solo se
// les pasa la consulta con la semana y el local.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * El impago de la cuota 1 o de la 2 tras la gracia: seis meses de consumos
 * hasta la semana elegida. Se pide también la otra cuota, con la misma
 * dimensión: sale al lado para compararla, y cambiar de cuota es instantáneo.
 */
export function ImpagoPorCuotaDeLaSemana({
  domingo,
  local,
  cuota,
  onCambiarCuota,
  dimension,
  onCambiarDimension,
}: {
  domingo: string
  local: string | null
  cuota: NumeroDeCuota
  onCambiarCuota: (c: NumeroDeCuota) => void
  dimension: DimensionPrimeraCuota
  onCambiarDimension: (d: DimensionPrimeraCuota) => void
}) {
  const consulta = useQuery(consultaImpagoDeCuota(cuota, dimension, domingo, local))
  const otra = useQuery(consultaImpagoDeCuota(otraCuota(cuota), dimension, domingo, local))
  return (
    <ImpagoPorCuota
      cuota={cuota}
      onCambiarCuota={onCambiarCuota}
      dimension={dimension}
      onCambiarDimension={onCambiarDimension}
      consulta={consulta}
      otra={otra}
    />
  )
}

/** El uso del cupo por nivel. Es de hoy: el cupo no tiene semana. */
export function CuposDeHoy({ local, nombreLocal }: { local: string | null; nombreLocal: string | null }) {
  const consulta = useQuery(consultaUsoDelCupo(local))
  return (
    <div className="flex flex-col gap-4">
      <p className="type-panel-caption text-panel-muted">
        El cupo es de hoy: la semana de arriba no lo cambia.
      </p>
      <Cupos
        consulta={consulta}
        gente={local === null ? undefined : `Los pacientes que se han financiado en ${nombreLocal ?? 'esta clínica'}`}
      />
    </div>
  )
}

/**
 * El rendimiento de la cobranza en la semana elegida: lo recuperado, las
 * gestiones y las promesas de esos días, y la cura de las ocho semanas que
 * acaban en su corte.
 */
export function RendimientoDeLaSemana({
  lunes,
  domingo,
  corte,
  local,
}: {
  lunes: string
  domingo: string
  corte: string
  local: string | null
}) {
  const recuperado = useQuery(consultaRecuperado(lunes, domingo, local))
  const cura = useQuery(consultaCura(corte, local))
  const efectividad = useQuery(consultaEfectividad(lunes, domingo, local))
  const promesas = useQuery(consultaPromesas(local, lunes, domingo))

  const p = promesas.data
  const cumplimiento = p ? tasaDeCumplimiento(p.recuento) : null
  const estadoP = estadoDeConsulta(promesas)
  const reintentarP = () => void promesas.refetch()

  return (
    <CuerpoDelRendimiento
      titulo={`Del lunes ${formatDayShort(lunes)} al domingo ${formatDayShort(domingo)}`}
      recuperado={recuperado}
      cura={cura}
      efectividad={efectividad}
      despues={
        <StatGrid cols={3} className="mt-4">
          <Stat
            label="Promesas cumplidas (%)"
            value={cumplimiento ? pctOSinDatos(cumplimiento.pct) : ''}
            hint={
              cumplimiento
                ? cumplimiento.resueltas === 0
                  ? 'Ninguna resuelta todavía'
                  : `${cumplimiento.cumplidas} de ${cumplimiento.resueltas} resueltas`
                : undefined
            }
            info="Promesas de pago con fecha en la semana cumplidas ÷ promesas con fecha en la semana ya resueltas (cumplidas o rotas); las pendientes no cuentan."
            estado={estadoP}
            onReintentar={reintentarP}
          />
          <Stat
            label="Promesas incumplidas"
            value={p ? String(p.recuento.rota) : ''}
            link={{ to: '/admin/cobranza', search: { vista: 'promesas', estado: 'rota' } }}
            estado={estadoP}
            onReintentar={reintentarP}
          />
          <Stat
            label="Promesas pendientes"
            value={p ? String(p.recuento.pendiente + p.recuento.vence_hoy) : ''}
            hint={p && p.recuento.vence_hoy > 0 ? `${p.recuento.vence_hoy} vencen hoy` : undefined}
            estado={estadoP}
            onReintentar={reintentarP}
          />
        </StatGrid>
      }
    />
  )
}
