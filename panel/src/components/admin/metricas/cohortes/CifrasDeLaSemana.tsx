import { Stat, StatGrid, formatUsd, formatNumero } from '@/components/ui'
import type { EstadoCifra } from '@/components/ui'
import { desgloseCorto } from '@/features/admin/metricas/cohortes/desglose'
import { aunNoVence } from '@/features/admin/metricas/cohortes/estados'
import { pct } from '@/features/admin/metricas/cohortes/frases'
import type { Cohorte } from '@/features/admin/metricas/cohortes/tipos'
import type { Desglose } from '@/features/admin/metricas/lectura'
import { LineaDelDesglose } from './ImporteDeCuota'

/**
 * Las cuatro cifras de la semana elegida, en lo que hay que COBRAR (decisión
 * de Javier del 27-09): el total a cobrar (la cuota 1 + la 2, con el service
 * fee dentro), qué parte ya se cobró, lo vencido y lo por vencer. Cada
 * importe lleva debajo, en pequeño, de qué está hecho: el consumo sin fee y
 * el service fee. Es la condición de la excepción a la regla del fee.
 *
 * El desglose va en el hueco de la forma (`visual`) y no en el pie del
 * `Stat`: el pie se corta en una línea, y un desglose cortado no vale.
 * Debajo, en gris, lo secundario: consumos, usuarios que consumieron y lo
 * perdido.
 */
export function CifrasDeLaSemana({
  cohorte,
  hoy,
  estado,
  onReintentar,
}: {
  cohorte: Cohorte | null
  hoy: string
  estado: EstadoCifra
  onReintentar: () => void
}) {
  const a = cohorte?.aCobrar ?? null
  const comun = { estado, onReintentar }
  const nadaVence = a !== null && aunNoVence(a, hoy)
  const vencido = a?.estados.vencida ?? null
  const porVencer = a?.estados.por_vencer ?? null
  const perdido = a?.estados.perdida ?? null

  return (
    <div className="flex flex-col gap-2">
      <StatGrid cols={4}>
        <Stat
          {...comun}
          label="Total a cobrar"
          value={a ? formatUsd(a.importe.payableUsd) : ''}
          visual={a ? <LineasDeDesglose d={a.importe} /> : undefined}
          info="Cuota 1 + cuota 2 de los financiamientos confirmados de esta semana (lunes a domingo, por día operativo), con su desglose: financiado (sin fee) + service fee + IVA."
        />
        <Stat
          {...comun}
          label="Cobrado (%)"
          value={a && a.cobradoPct !== null ? pct(a.cobradoPct) : '—'}
          visual={
            a ? (
              <LineasDeDesglose
                d={a.cobrado.importe}
                cabeza={`${formatUsd(a.cobrado.importe.payableUsd)} de ${formatUsd(a.importe.payableUsd)}`}
              />
            ) : undefined
          }
          info="Cobrado (a tiempo o con atraso) ÷ total a cobrar de esta semana, los dos en dólares con fee; debajo, el importe cobrado y su desglose."
        />
        <Stat
          {...comun}
          label="Vencido"
          value={vencido ? formatUsd(vencido.importe.payableUsd) : ''}
          visual={
            vencido ? (
              nadaVence ? (
                <p className="type-panel-caption text-panel-muted">Todavía no vence nada.</p>
              ) : (
                <LineasDeDesglose d={vencido.importe} cola={usuarios(vencido.personas)} />
              )
            ) : undefined
          }
          info="Cuotas de esta semana sin pagar cuyo vencimiento ya pasó (también las que siguen en la gracia), sin lo perdido, en dólares con fee; debajo, su desglose y cuántos pacientes lo deben."
        />
        <Stat
          {...comun}
          label="Por vencer"
          value={porVencer ? formatUsd(porVencer.importe.payableUsd) : ''}
          visual={porVencer ? <LineasDeDesglose d={porVencer.importe} cola={usuarios(porVencer.personas)} /> : undefined}
          info="Cuotas de esta semana sin pagar cuyo vencimiento todavía no llega, en dólares con fee; debajo, su desglose y cuántos pacientes las tienen."
        />
      </StatGrid>

      {cohorte && (
        <p className="px-1 type-panel-caption text-panel-muted">
          {formatNumero(cohorte.consumos, 0)} {cohorte.consumos === 1 ? 'financiamiento' : 'financiamientos'} ·{' '}
          {usuarios(cohorte.personas)} que {cohorte.personas === 1 ? 'se financió' : 'se financiaron'}
          {perdido && perdido.importe.payableUsd > 0
            ? ` · perdido ${formatUsd(perdido.importe.payableUsd)} (${desgloseCorto(perdido.importe)})`
            : ''}
        </p>
      )}
    </div>
  )
}

function usuarios(n: number): string {
  return `${formatNumero(n, 0)} ${n === 1 ? 'paciente' : 'pacientes'}`
}

/** El desglose de una cifra, debajo de ella: una línea de cabeza opcional, la de las dos partes y una cola. */
function LineasDeDesglose({ d, cabeza, cola }: { d: Desglose; cabeza?: string; cola?: string }) {
  return (
    <p className="flex flex-col gap-0.5 type-panel-caption tabular-nums text-panel-muted">
      {cabeza && <span className="text-on-surface-variant">{cabeza}</span>}
      <span>
        <LineaDelDesglose d={d} />
      </span>
      {cola && <span>{cola}</span>}
    </p>
  )
}
