import { BarChart3, LayoutDashboard } from 'lucide-react'

import { MiniBarras, Ring, colorDeTono } from '@/components/charts'
import { Meter, Seccion, StatGrid, formatUsd, formatPct } from '@/components/ui'
import type { EstadoCifra, SenalDeCifra } from '@/components/ui'
import { pantalla } from '@/features/admin/catalogo'
import { lunesDe } from '@/features/admin/semana'
import { rotuloDeMes } from '@/features/admin/riesgo/cosechas'
import {
  contar,
  diaDelCierre,
  globoDeDeudaVencida,
  medidorDelCierre,
  pieDeDeudaVencida,
  semanaCorta,
  senalDelCierre,
} from './cifras'
import type { LecturaDeCifra } from './cifras'
import { Entrada } from './Entrada'
import { TarjetaDeArea } from './TarjetaDeArea'
import { useCierreDeHoy, useDeudaVencida, useFinanciadoDeLaSemana, useImpagoPrimeraCuota } from './useCifrasDeHoy'

/** Lo que `TarjetaDeArea` necesita saber de una lectura, sin sus datos. */
function estadoDe<T>(l: LecturaDeCifra<T>): { estado: EstadoCifra; onReintentar?: () => void } {
  return l.estado === 'error' ? { estado: 'error', onReintentar: l.reintentar } : { estado: l.estado }
}

/** El medidor va en el tono del área, y en el del estado solo si la cifra cruza su umbral. */
function tonoDelMedidor(senal: SenalDeCifra | undefined): 'area' | 'warning' | 'error' {
  return senal?.tone === 'warning' || senal?.tone === 'error' ? senal.tone : 'area'
}

/** Los datos de una lectura lista; `null` si todavía no, o si no hay. */
function datosDe<T>(l: LecturaDeCifra<T | null>): T | null {
  return l.estado === 'listo' ? l.datos : null
}

/** Cobranza: lo vencido, con la mora sobre la deuda viva. */
function DeudaVencida() {
  const lectura = useDeudaVencida()
  const d = datosDe(lectura)
  const p = pantalla('cartera-vencida')

  return (
    <TarjetaDeArea
      area={p.espacio}
      icono={p.icono}
      rotulo="Vencido (financiamiento + comisión)"
      info="Las cuotas vencidas y sin pagar hoy, sin la deuda dada por perdida ni los cargos por atraso, con su financiamiento y su Comisión Helios debajo y los pacientes que las deben; «Mora» es ese vencido ÷ (vencido + por vencer)."
      destino={p.destino}
      {...estadoDe(lectura)}
      valor={d ? formatUsd(d.vencido) : '—'}
      senal={d?.senal}
      visual={
        d && d.porCobrar > 0 ? (
          <Meter
            valor={d.vencido}
            max={d.porCobrar}
            tono={tonoDelMedidor(d.senal)}
            rotulo={`Vencido, financiamiento + comisión: ${formatUsd(d.vencido)} de ${formatUsd(d.porCobrar)} de deuda viva (vencido + por vencer)`}
            globo={globoDeDeudaVencida(d, colorDeTono(tonoDelMedidor(d.senal)))}
          />
        ) : undefined
      }
      pie={d && pieDeDeudaVencida(d, d.usuarios)}
    />
  )
}

/**
 * Caja: lo que sale hoy hacia las clínicas, contra la caja. Se les paga a
 * diario (cada liquidación, el día siguiente a su vencimiento), así que el
 * próximo pago es hoy.
 */
function SaleEnElCierre({ hoy }: { hoy: string }) {
  const lectura = useCierreDeHoy(hoy)
  const c = datosDe(lectura)
  const p = pantalla('pagos-a-locales')
  const medidor = c ? medidorDelCierre(c.salen, c.caja) : null
  const senal: SenalDeCifra | undefined = c ? senalDelCierre(c.veredicto) : undefined

  return (
    <TarjetaDeArea
      area={p.espacio}
      icono={p.icono}
      rotulo={
        !c?.fechaCierre || c.fechaCierre === hoy
          ? 'Sale hoy hacia las clínicas'
          : `Sale el ${diaDelCierre(c.fechaCierre)} hacia las clínicas`
      }
      info="Lo que hay que transferirles hoy a las clínicas, con lo atrasado de días anteriores, frente a la caja según el libro. Se les paga a diario: cada liquidación, el día siguiente a su vencimiento (la consulta, a los 8 y a los 15 días; la comisión de la secretaria, el día siguiente a la confirmación). «No cubre»: la caja de hoy no alcanza para el pago de hoy."
      destino={p.destino}
      {...estadoDe(lectura)}
      valor={c ? formatUsd(c.salen) : ''}
      senal={senal}
      visual={
        c && medidor ? (
          <Meter
            valor={medidor.valor}
            max={medidor.max}
            tono={c.veredicto === 'urgente' ? 'error' : 'area'}
            rotulo={`Sale hoy: ${formatUsd(c.salen)} de ${formatUsd(c.caja)} en caja`}
          />
        ) : undefined
      }
      pie={c && `de ${formatUsd(c.caja)} en caja`}
    />
  )
}

/** Riesgo: el impago de la cuota 1 del último mes maduro. */
function ImpagoPrimeraCuota() {
  const lectura = useImpagoPrimeraCuota()
  const r = datosDe(lectura)

  return (
    // El tono y el icono de Riesgo, los de siempre: Riesgo de crédito pasó a
    // Métricas, pero la tarjeta de Inicio no cambia.
    <TarjetaDeArea
      area="riesgo"
      icono={BarChart3}
      rotulo="Impago de la cuota 1 (último mes)"
      info="De las cuotas 1 de lo financiado en el último mes cuyas cuotas 1 ya pasaron todas sus días de gracia, la parte que seguía sin pagar al acabar la gracia, en número de cuotas."
      destino={{ to: '/admin/metricas', search: { vista: 'cobros', sub: 'impago-por-cuota' } }}
      {...estadoDe(lectura)}
      valor={r === null || r.pct === null ? '—' : formatPct(r.pct)}
      senal={r?.senal}
      lateral={
        r && (
          <Ring
            valor={r.pct === null ? null : r.pct / 100}
            tono={r.senal?.tone ?? 'area'}
            rotulo={`Impago de la cuota 1: ${r.pct === null ? 'sin mes maduro' : formatPct(r.pct)}`}
          />
        )
      }
      pie={
        r &&
        (r.mes
          ? `${r.mes.impagas} de ${r.mes.maduras} cuotas 1 sin pagar · financiamientos de ${rotuloDeMes(r.mes.clave)}`
          : 'Ningún mes tiene todavía todas sus cuotas 1 fuera de la gracia')
      }
    />
  )
}

/** Gerencia: lo facturado esta semana (sin fee), con los consumos de cada día. */
function FinanciadoEstaSemana() {
  const lectura = useFinanciadoDeLaSemana()
  const f = datosDe(lectura)

  return (
    // El tono y el icono de Gerencia, los de siempre: el Resumen pasó a
    // Métricas › Semana, pero la tarjeta de Inicio no cambia.
    <TarjetaDeArea
      area="gerencia"
      icono={LayoutDashboard}
      rotulo="Financiado esta semana (sin comisión)"
      info="Sin la Comisión Helios: lo financiado en las clínicas en financiamientos confirmados de lunes a hoy, por día operativo; la pastilla y las barras son el número de financiamientos, en total y de cada día."
      destino={pantalla('metricas-semana').destino}
      {...estadoDe(lectura)}
      valor={f ? formatUsd(f.financiado) : '—'}
      senal={f ? { tone: 'neutral', texto: contar(f.consumos, 'financiamiento', 'financiamientos') } : undefined}
      visual={
        f?.barras ? (
          <MiniBarras
            puntos={f.barras}
            formato={(n) => contar(n, 'financiamiento', 'financiamientos')}
            rotulo="Financiamientos de cada día de esta semana"
          />
        ) : undefined
      }
    />
  )
}

/**
 * «Hoy en cifras»: una cifra por área, con su forma, y cada una lleva a su
 * pantalla. Las mismas lecturas que esas pantallas: aquí no se pide nada
 * nuevo. `desde` es el turno de entrada de la primera tarjeta, detrás de las
 * de «Pendiente».
 */
export function CifrasDeHoy({ hoy, desde = 0 }: { hoy: string; desde?: number }) {
  const semana = datosDe(useFinanciadoDeLaSemana())

  return (
    <Seccion
      titulo="Hoy en cifras"
      controles={<p className="type-panel-label font-normal text-panel-muted">{semanaCorta(semana?.lunes ?? lunesDe(hoy))}</p>}
    >
      <StatGrid cols={4}>
        <Entrada orden={desde}>
          <DeudaVencida />
        </Entrada>
        <Entrada orden={desde + 1}>
          <SaleEnElCierre hoy={hoy} />
        </Entrada>
        <Entrada orden={desde + 2}>
          <ImpagoPrimeraCuota />
        </Entrada>
        <Entrada orden={desde + 3}>
          <FinanciadoEstaSemana />
        </Entrada>
      </StatGrid>
    </Seccion>
  )
}
