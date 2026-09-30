import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import type { UseQueryResult } from '@tanstack/react-query'

import {
  Badge,
  Card,
  DataLabel,
  InfoDot,
  Meter,
  NoSePudoLeer,
  Seccion,
  SkeletonCard,
  estadoDeConsultas,
  formatUsd,
  formatNumero,
  formatPorcentaje,
} from '@/components/ui'
import { CifrasEnFila } from '@/components/admin/tableros/CifrasEnFila'
import { marcasDelCapital, senalDelCapital } from '@/components/admin/tableros/senales'
import type { CashPosition } from '@/features/admin/metrics'
import type { Parametros } from '@/features/admin/parametros'
import { valorDe } from '@/features/admin/parametros'
import type { SemanaResumen } from '@/features/admin/resumen'
import { ritmoSemanal, semaforoDeCapital, semanasDeUnCiclo } from '@/features/admin/semana'

/** Las semanas cerradas con las que se mide el ritmo. */
const SEMANAS_DE_RITMO = 4

const TITULO = 'Capital'

const QUE_ES =
  'Cuánto del capital disponible está comprometido: el financiamiento que los pacientes todavía no han devuelto, sin el service fee. La parte de la clínica es la misma esté transferida o por transferir, así que no se suma aparte; si hay caja para el lunes lo dice el semáforo del cierre. Las semanas suponen que no vuelve nada. Es rojo si lo que queda no cubre un ciclo de cobro (las dos cuotas) y ámbar si no cubre dos: son las marcas del medidor.'

const ENLACE = 'text-on-surface underline decoration-panel-hairline-strong underline-offset-2 hover:decoration-on-surface'

/**
 * El semáforo de capital: si el dinero alcanza.
 *
 * Es de hoy, no de la semana elegida: el capital comprometido es una foto, y
 * el ritmo son las últimas cuatro semanas cerradas. El medidor lleva los dos
 * cortes del semáforo, así que se ve cuánto falta para el ámbar y el rojo.
 *
 * «Por pagar a locales» no va aquí: no se suma a lo comprometido y ya lo
 * dice el Balance, en la misma vista.
 */
export function SemaforoDeCapital({
  parametros,
  caja,
  semanas,
  esSuperAdmin,
}: {
  parametros: UseQueryResult<Parametros>
  caja: UseQueryResult<CashPosition>
  /** Todas las semanas leídas, hasta la en curso. */
  semanas: readonly SemanaResumen[]
  esSuperAdmin: boolean
}) {
  const estado = estadoDeConsultas([parametros, caja])

  if (estado === 'cargando') return <Marco><SkeletonCard /></Marco>

  if (estado === 'error' || !parametros.data || !caja.data) {
    return (
      <Marco>
        <Card>
          <NoSePudoLeer
            onReintentar={() => {
              if (parametros.isError) void parametros.refetch()
              if (caja.isError) void caja.refetch()
            }}
          />
        </Card>
      </Marco>
    )
  }

  const capital = valorDe(parametros.data, 'capital_disponible_usd')

  if (capital === null) {
    return (
      <Marco>
        <Card>
          <DataLabel>Capital disponible sin definir</DataLabel>
          <p className="mt-2 type-panel-body text-on-surface-variant">
            {esSuperAdmin ? (
              <Link to="/admin/ajustes" search={{ tab: 'parametros' }} className={ENLACE}>
                Definirlo en Ajustes › Parámetros
              </Link>
            ) : (
              'Lo define el super admin en Ajustes › Parámetros.'
            )}
          </p>
        </Card>
      </Marco>
    )
  }

  const consumoSinSaldar = caja.data.principalOutstanding
  const ritmo = ritmoSemanal(semanas, SEMANAS_DE_RITMO)
  const ciclo = semanasDeUnCiclo(valorDe(parametros.data, 'installment_interval_days'))
  const c = semaforoDeCapital({
    capital,
    consumoSinSaldar,
    ritmo: ritmo?.media ?? null,
    semanasDeCiclo: ciclo,
  })
  const senal = senalDelCapital(c)

  const formula = [
    `Comprometido: el financiamiento sin saldar, ${formatUsd(c.comprometido)}.`,
    `Usado: ${formatUsd(c.comprometido)} ÷ ${formatUsd(capital)} de capital.`,
    ritmo
      ? `Semanas: lo que queda, ${formatUsd(Math.max(c.queda, 0))}, ÷ ${formatUsd(ritmo.media)} facturados (sin fee) de media por semana.`
      : 'Sin semanas cerradas no hay ritmo con el que contar las semanas.',
  ].join(' ')

  return (
    <Marco>
      <Card className="flex flex-col gap-5">
        <div className="flex flex-col gap-2">
          <div className="flex items-center gap-1.5">
            <DataLabel>Capital comprometido</DataLabel>
            <InfoDot title="Capital comprometido" what={QUE_ES} formula={formula} />
          </div>
          <div className="flex flex-wrap items-center gap-x-2.5 gap-y-1.5">
            <p className="type-panel-figure text-on-surface">
              {c.usadoPct === null ? '—' : formatPorcentaje(c.usadoPct)}
            </p>
            <span className="type-panel-body text-on-surface-variant">de {formatUsd(capital)}</span>
            {senal && (
              <Badge tone={senal.tone} icono>
                {senal.texto}
              </Badge>
            )}
          </div>
          <Meter
            valor={c.usadoPct ?? 0}
            max={100}
            tono={senal?.tone ?? 'area'}
            marcas={marcasDelCapital({ capital, ritmo: ritmo?.media ?? null, semanasDeCiclo: ciclo })}
            // Lo de después de los dos puntos es lo que dice el globo del medidor.
            rotulo={`Capital comprometido: ${c.usadoPct === null ? 'sin dato' : `${formatPorcentaje(c.usadoPct)} de ${formatUsd(capital)}`}`}
            className="mt-1"
          />
        </div>

        <div className="border-t border-panel-hairline pt-4">
          <CifrasEnFila
            cifras={[
              {
                rotulo: 'Financiamiento por cobrar (sin fee)',
                info: 'Calculado de las cuotas sin pagar ni dadas por perdidas: su financiamiento, sin el service fee. Es la parte «Financiamiento» de «Por cobrar a pacientes» del Balance.',
                valor: (
                  <Link to="/admin/metricas" search={{ vista: 'caja', sub: 'balance' }} className="hover:underline">
                    {formatUsd(consumoSinSaldar)}
                  </Link>
                ),
              },
              {
                rotulo: 'Capital sin comprometer',
                info: 'El capital disponible (Ajustes › Parámetros) menos el financiamiento por cobrar.',
                valor: formatUsd(c.queda),
              },
              {
                rotulo: 'Semanas que alcanza',
                valor:
                  c.semanas === null
                    ? 'Sin ritmo'
                    : `${formatNumero(c.semanas)} ${c.semanas === 1 ? 'semana' : 'semanas'}`,
                pie: ritmo
                  ? `A ${formatUsd(ritmo.media)} facturados por semana`
                  : 'Todavía no hay una semana cerrada',
                info: ritmo
                  ? `El capital sin comprometer entre el financiado (sin fee) medio de ${ritmo.semanas === 1 ? 'la última semana cerrada' : `las últimas ${ritmo.semanas} semanas cerradas`}, suponiendo que no vuelve nada.`
                  : undefined,
              },
            ]}
          />
        </div>
      </Card>
    </Marco>
  )
}

function Marco({ children }: { children: ReactNode }) {
  return (
    <Seccion titulo={TITULO} info="Es de hoy, sea cual sea la semana elegida.">
      {children}
    </Seccion>
  )
}
