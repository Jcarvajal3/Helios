import type { ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'

import { BarChart, Ring } from '@/components/charts'
import {
  Card,
  NoSePudoLeer,
  Seccion,
  SkeletonList,
  Stat,
  StatGrid,
  diaOperativo,
  estadoDeConsulta,
  formatUsd,
  formatUsdShort,
  hoyCaracas,
} from '@/components/ui'
import { SelectorDeVentana } from '@/components/admin/tableros/SelectorDeVentana'
import { CuraPorTramo } from '@/components/admin/rendimiento/CuraPorTramo'
import { EfectividadDeGestion } from '@/components/admin/rendimiento/EfectividadDeGestion'
import { describirPeriodo, pctOSinDatos, rotuloDelTramo } from '@/components/admin/rendimiento/formato'
import {
  consultaCura,
  consultaEfectividad,
  consultaRecuperado,
} from '@/features/admin/cobranza/consultas'
import { textoDelDesglose } from '@/features/admin/metricas/cobranza/semana'
import { PERIODOS, desgloseDeBolsa, rangoDe } from '@/features/admin/cobranza/rendimiento'
import type { Cura, EfectividadDeCobranza, Periodo, Recuperado } from '@/features/admin/cobranza/rendimiento'

/** Semanas de la cura: dos meses de lunes. */
const SEMANAS_DE_CURA = 8

const OPCIONES_PERIODO = PERIODOS.map((p) => ({ valor: p, dias: p }))

/** Lo que el cuerpo del rendimiento necesita de cada `useQuery`. */
export type ConsultaDeRendimiento<T> = {
  data: T | undefined
  isError: boolean
  isPending: boolean
  refetch: () => unknown
}

/**
 * Si lo que hace Cobranza funciona, en Por cobrar › Rendimiento: los últimos
 * 7, 30 o 90 días. El cuerpo es el mismo que en Métricas › Cobranza y riesgo
 * (`CuerpoDelRendimiento`), que lo pide con su semana y su local.
 */
export function RendimientoCobranza({
  dias,
  onDias,
}: {
  dias: Periodo
  onDias: (d: Periodo) => void
}) {
  // El dinero va por día operativo; las gestiones, por día de Caracas.
  const dinero = rangoDe(diaOperativo(new Date()), dias)
  const gestiones = rangoDe(hoyCaracas(), dias)

  const recuperado = useQuery(consultaRecuperado(dinero.desde, dinero.hasta))
  const cura = useQuery(consultaCura(SEMANAS_DE_CURA))
  const efectividad = useQuery(consultaEfectividad(gestiones.desde, gestiones.hasta))

  return (
    <CuerpoDelRendimiento
      titulo={`Los últimos ${dias} días`}
      controles={
        <SelectorDeVentana valor={dias} opciones={OPCIONES_PERIODO} hoy={dinero.hasta} onChange={onDias} />
      }
      recuperado={recuperado}
      cura={cura}
      efectividad={efectividad}
    />
  )
}

/**
 * Si lo que hace Cobranza funciona: cuánto se recuperó de lo vencido, cuánta
 * gente sale de cada tramo cada semana y qué gestiones acaban en un pago.
 *
 * Lo recuperado es lo pagado: consumo + service fee, así que va siempre con
 * su desglose. El cargo por atraso va aparte y no se suma.
 */
export function CuerpoDelRendimiento({
  titulo,
  controles,
  recuperado,
  cura,
  efectividad,
  despues,
}: {
  titulo: string
  controles?: ReactNode
  recuperado: ConsultaDeRendimiento<Recuperado>
  cura: ConsultaDeRendimiento<Cura>
  efectividad: ConsultaDeRendimiento<EfectividadDeCobranza>
  /** Lo que va al final de la primera sección (Métricas pone las promesas). */
  despues?: ReactNode
}) {
  const r = recuperado.data
  const e = efectividad.data
  const estadoR = estadoDeConsulta(recuperado)
  const estadoE = estadoDeConsulta(efectividad)
  const desglose = r ? desgloseDeBolsa(r.recuperado) : null

  return (
    <div className="flex flex-col gap-10">
      <Seccion titulo={titulo} controles={controles}>
        <StatGrid cols={4}>
          <Stat
            label="Cobrado de cuotas vencidas (con fee)"
            value={r ? formatUsd(r.recuperado.usd) : ''}
            visual={
              desglose &&
              r &&
              r.recuperado.usd > 0 && (
                <span className="type-panel-caption text-panel-muted">{textoDelDesglose(desglose)}</span>
              )
            }
            hint={
              r
                ? `${r.recuperado.cuotas} ${r.recuperado.cuotas === 1 ? 'cuota' : 'cuotas'} de ${r.recuperado.personas} ${r.recuperado.personas === 1 ? 'paciente' : 'pacientes'}`
                : undefined
            }
            info="Cuotas con el pago reportado en el periodo después de su día de vencimiento (también las pagadas dentro de la gracia, que cuentan además como a tiempo), en dólares con fee y su desglose; el cargo por atraso va aparte."
            estado={estadoR}
            onReintentar={() => void recuperado.refetch()}
          />
          <Stat
            label="Cobrado de lo vencido al empezar (%)"
            value={r ? pctOSinDatos(r.pctRecuperacion) : ''}
            hint={
              r && r.pctRecuperacion !== null
                ? `${r.recuperadoDeLoVencido.cuotas} de ${r.vencidoAlEmpezar.cuotas} cuotas vencidas al empezar`
                : 'No había nada vencido al empezar'
            }
            info="De las cuotas vencidas y sin pagar al empezar el periodo (lo perdido incluido), lo cobrado dentro del periodo ÷ lo que se debía, en dólares con fee; debajo, en número de cuotas."
            lateral={
              <Ring
                tamano="sm"
                valor={r?.pctRecuperacion == null ? null : r.pctRecuperacion / 100}
                rotulo={`Cobrado de lo vencido al empezar: ${r ? pctOSinDatos(r.pctRecuperacion) : 'sin datos'}`}
              />
            }
            estado={estadoR}
            onReintentar={() => void recuperado.refetch()}
          />
          <Stat
            label="Cargos por atraso cobrados (sin IVA)"
            value={r ? formatUsd(r.cargosPorAtraso.usd) : ''}
            hint={r ? `${r.cargosPorAtraso.cuantos} ${r.cargosPorAtraso.cuantos === 1 ? 'cargo' : 'cargos'}` : undefined}
            info="Ingreso de Helios, sin IVA. Se cuentan aparte y no se suman a lo recuperado."
            estado={estadoR}
            onReintentar={() => void recuperado.refetch()}
          />
          <Stat
            label={`Gestiones con pago en ${e?.horas ?? 72} h (%)`}
            value={e ? pctOSinDatos(e.total.pct) : ''}
            hint={
              e
                ? `${e.total.gestiones} ${e.total.gestiones === 1 ? 'gestión' : 'gestiones'}, ${e.total.enVentana} en ventana`
                : undefined
            }
            info="Gestiones seguidas de un pago reportado (o de una cuota pagada sin reporte) en las 72 horas siguientes ÷ gestiones que ya cumplieron esas 72 horas; es una señal, no una prueba de causa."
            lateral={
              <Ring
                tamano="sm"
                valor={e?.total.pct == null ? null : e.total.pct / 100}
                rotulo={`Gestiones con pago: ${e ? pctOSinDatos(e.total.pct) : 'sin datos'}`}
              />
            }
            estado={estadoE}
            onReintentar={() => void efectividad.refetch()}
          />
        </StatGrid>

        {despues}

        {r && (
          <BarChart
            title="Cobrado de cuotas vencidas, por tramo de atraso al pagar"
            summary={`Por días de atraso el día del reporte del pago, ${describirPeriodo(r.desde, r.hasta)}`}
            series={[{ key: 'usd', label: 'Cobrado de cuotas vencidas (con fee)' }]}
            points={r.porTramo.map((t) => {
              const d = desgloseDeBolsa(t)
              const cuotas = `${t.cuotas} ${t.cuotas === 1 ? 'cuota' : 'cuotas'}`
              return {
                key: t.tramo,
                label: rotuloDelTramo(t.tramo, r.cortes),
                values: [t.usd],
                note: d && t.usd > 0 ? `${cuotas} · ${textoDelDesglose(d)}` : cuotas,
              }
            })}
            format={formatUsd}
            formatShort={formatUsdShort}
            ejeLabel="Tramo"
            unidadLabel="Cuotas y desglose"
            footnote="En dólares con fee; el desglose financiado + service fee + IVA de cada tramo está en su globo y en su tabla."
            empty="No se recuperó nada vencido en este periodo."
          />
        )}
      </Seccion>

      <Seccion
        titulo="Pacientes que se pusieron al día, por tramo (%)"
        info="De los pacientes que estaban en cada tramo al empezar la semana (el lunes), los que estaban al día al cerrarla (o ahora, si está en curso) ÷ los que estaban en el tramo; el cambio completo entre tramos está en Riesgo › Resumen."
      >
        {cura.isPending && <SkeletonList rows={3} />}
        {cura.isError && (
          <Card>
            <NoSePudoLeer onReintentar={() => void cura.refetch()} />
          </Card>
        )}
        {cura.data && <CuraPorTramo cura={cura.data} />}
      </Seccion>

      <Seccion titulo="Gestiones de cobranza con pago en 72 h, por canal y hora">
        {efectividad.isPending && <SkeletonList rows={3} />}
        {efectividad.isError && (
          <Card>
            <NoSePudoLeer onReintentar={() => void efectividad.refetch()} />
          </Card>
        )}
        {e && <EfectividadDeGestion e={e} />}
      </Seccion>
    </div>
  )
}
