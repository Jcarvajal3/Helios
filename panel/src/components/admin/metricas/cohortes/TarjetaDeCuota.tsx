import { DataLabel, InfoDot, formatNumero } from '@/components/ui'
import {
  ROTULO_DE_ESTADO,
  parteDeEstado,
  pastillaDeCuota,
  queEsCadaEstado,
  tramosDeCobro,
} from '@/features/admin/metricas/cohortes/estados'
import { pct } from '@/features/admin/metricas/cohortes/frases'
import { rangoDeVencimiento } from '@/features/admin/metricas/cohortes/semanas'
import { ESTADOS_DE_CUOTA } from '@/features/admin/metricas/cohortes/tipos'
import type { CuotaDeCohorte } from '@/features/admin/metricas/cohortes/tipos'
import { BarraDeEstados } from './BarraDeEstados'
import { COLOR_DE_ESTADO } from './colores'
import { ImporteDeCuota } from './ImporteDeCuota'
import { PastillaDeEstado } from './PastillaDeEstado'

/**
 * Una cuota de la semana (la 1 o la 2, cada una en su tarjeta). Lo que se
 * cobra en ella con su desglose (consumo sin fee · service fee), la barra por
 * estados y, por cada estado, su importe (también con desglose), qué parte es
 * y cuántas personas. Las dos tarjetas suman el total a cobrar de arriba.
 */
export function TarjetaDeCuota({ cuota, hoy }: { cuota: CuotaDeCohorte; hoy: string }) {
  const q = cuota

  return (
    <article className="flex flex-col gap-3.5 rounded-panel-card border border-panel-hairline bg-panel-card p-panel-pad-card">
      <div className="flex flex-wrap items-center gap-x-2.5 gap-y-1">
        <h3 className="type-panel-section text-on-surface">Cuota {q.numero}</h3>
        <PastillaDeEstado pastilla={pastillaDeCuota(q, hoy)} />
        <span className="ml-auto type-panel-caption text-panel-muted">
          {q.venceDesde === q.venceHasta ? 'Vence' : 'Vencen'} {rangoDeVencimiento(q.venceDesde, q.venceHasta)}
        </span>
      </div>

      <div className="flex flex-col gap-1">
        <span className="flex items-center gap-1.5">
          <DataLabel>Total de la cuota {q.numero} (con fee)</DataLabel>
          <InfoDot
            title={`Cuota ${q.numero}`}
            what={`Suma de las cuotas ${q.numero} de los financiamientos de esta semana: financiado (sin fee) + service fee + IVA. ${queEsCadaEstado()}`}
          />
        </span>
        <ImporteDeCuota importe={q.importe} claseCifra="type-panel-figure text-on-surface" />
      </div>

      <BarraDeEstados
        tramos={tramosDeCobro(q)}
        rotulo={`Cuota ${q.numero} por estado`}
        titulo={`Cuota ${q.numero}`}
        total={q.importe}
        alto="gruesa"
      />

      <table className="w-full border-collapse tabular-nums">
        <caption className="sr-only">
          Cuota {q.numero} por estado: importe con fee (financiado y service fee + IVA), qué parte es y cuántos pacientes
        </caption>
        <thead className="sr-only">
          <tr>
            <th scope="col">Estado</th>
            <th scope="col">Importe (con fee)</th>
            <th scope="col">Parte</th>
            <th scope="col">Pacientes</th>
          </tr>
        </thead>
        <tbody>
          {ESTADOS_DE_CUOTA.map((e) => {
            const parte = q.estados[e]
            const hay = parte.importe.payableUsd > 0
            const porcentaje = parteDeEstado(q, e)
            return (
              <tr key={e} className="border-t border-panel-hairline align-top">
                <th scope="row" className="py-1.5 pr-2 text-left font-normal">
                  <span
                    className={`inline-flex items-center gap-2 type-panel-body ${hay ? 'text-on-surface' : 'text-panel-muted'}`}
                  >
                    <span
                      aria-hidden
                      className="size-2 shrink-0 rounded-[3px]"
                      style={{ backgroundColor: hay ? COLOR_DE_ESTADO[e] : 'var(--color-panel-control)' }}
                    />
                    {ROTULO_DE_ESTADO[e]}
                  </span>
                </th>
                <td className="py-1.5 text-right">
                  {hay ? (
                    <ImporteDeCuota importe={parte.importe} variante="compacta" />
                  ) : (
                    <span className="type-panel-body text-panel-muted">—</span>
                  )}
                </td>
                <td className="w-14 py-1.5 text-right type-panel-caption text-panel-muted">
                  {hay && porcentaje !== null ? pct(porcentaje) : ''}
                </td>
                <td className="w-24 py-1.5 text-right type-panel-caption text-panel-muted">
                  {hay ? `${formatNumero(parte.personas, 0)} ${parte.personas === 1 ? 'paciente' : 'pacientes'}` : ''}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </article>
  )
}
