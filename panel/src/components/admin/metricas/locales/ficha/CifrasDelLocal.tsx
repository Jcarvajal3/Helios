import { CifraConTendencia } from '@/components/admin/metricas/kit'
import { StatGrid, formatUsd, formatPorcentaje } from '@/components/ui'
import { rotuloDelCierre } from '../columnasDeLocales'
import { delta, textoDeDesglose } from '@/features/admin/metricas/formato'
import { busquedaDeMetricas } from '@/features/admin/metricas/busqueda'
import {
  pieDeLaParte,
  pieDelCierre,
  pieDelCobro,
  ticketsPorSemana,
  totalDelCierre,
} from '@/features/admin/metricas/locales/cifras'
import { ultimas } from '@/features/admin/metricas/locales/ficha'
import {
  consumosFrenteALaAnterior,
  frenteALaAnterior,
  recurrentes,
  referenciaDeLaAnterior,
  ticketAnterior,
} from '@/features/admin/metricas/locales/rendimiento'
import { semanaCorta } from '@/features/admin/metricas/locales/semanas'
import type { FilaLocal, LocalesDeLaSemana, SerieDeLocal } from '@/features/admin/metricas/locales/tipos'
import type { Parametros } from '@/features/admin/parametros'
import { senalPorUmbralAlto, umbralCobroATiempo } from '@/features/admin/umbrales'

const pctEntero = (n: number) => formatPorcentaje(n, 0)

/**
 * Las cifras de un local en la semana: lo que vendió, a cuánta gente, cómo le
 * paga su gente y qué se le transfiere por la semana. Cada una con su cambio
 * frente a la anterior (a la misma altura si la semana va a medias) y la
 * chispa de sus ocho últimas semanas.
 */
export function CifrasDelLocal({
  d,
  l,
  serie,
  parametros,
}: {
  d: LocalesDeLaSemana
  l: FilaLocal
  serie: SerieDeLocal | null
  parametros: Parametros | undefined
}) {
  const semanas = ultimas(d.series.semanas)
  const etiquetas = semanas.map(semanaCorta)
  const ref = referenciaDeLaAnterior(d)
  const chispa = (valores: ReadonlyArray<number | null>, rotulo: string, formato: (n: number) => string = String) =>
    serie ? { valores: ultimas(valores.map((v) => v ?? 0)), rotulo, etiquetas, formato } : undefined
  const comun = { semana: d.semana.enCurso ? undefined : d.semana.desde, local: l.merchantId ?? undefined }

  return (
    <StatGrid cols={4}>
      <CifraConTendencia
        titulo="Financiado (sin fee)"
        valor={formatUsd(l.consumoUsd)}
        delta={frenteALaAnterior(l)}
        info={`Sin el service fee: la suma de los financiamientos confirmados aquí. El cambio es frente a ${ref}.`}
        pie={pieDeLaParte(l.partePct)}
        chispa={chispa(serie?.consumoUsd ?? [], 'Financiado sin fee, últimas ocho semanas', formatUsd)}
      />
      <CifraConTendencia
        titulo="Financiamientos"
        valor={String(l.consumos)}
        delta={consumosFrenteALaAnterior(l)}
        info={`Financiamientos confirmados aquí. El cambio es frente a ${ref}.`}
        pie={`${l.noches} ${l.noches === 1 ? 'día' : 'días'} con financiamientos`}
        chispa={chispa(serie?.consumos ?? [], 'Financiamientos de las últimas ocho semanas')}
      />
      <CifraConTendencia
        titulo="Pacientes"
        valor={String(l.personas)}
        info="Pacientes distintos con una cuota en los financiamientos de esta semana aquí."
        pie={`${recurrentes(l)} ${recurrentes(l) === 1 ? 'repite' : 'repiten'} en la clínica`}
        chispa={chispa(serie?.personas ?? [], 'Pacientes, últimas ocho semanas')}
      />
      <CifraConTendencia
        titulo="Ticket medio (sin fee)"
        valor={l.ticketMedioUsd === null ? '—' : formatUsd(l.ticketMedioUsd)}
        delta={delta(l.ticketMedioUsd, ticketAnterior(l), { tipo: 'relativo', arribaEsBueno: true })}
        info={`Sin el service fee: el financiado entre los financiamientos. El cambio es frente a ${ref}.`}
        chispa={chispa(serie ? ticketsPorSemana(serie) : [], 'Ticket medio sin fee, últimas ocho semanas', formatUsd)}
      />
      <CifraConTendencia
        titulo="Pacientes nuevos en la clínica"
        valor={String(l.nuevas)}
        info="Pacientes cuya primera cuota en esta clínica es de esta semana, se hubieran financiado antes en otra o no."
        pie={l.personas > 0 ? `${pctEntero((100 * l.nuevas) / l.personas)} de sus pacientes` : 'Nadie se financió'}
        chispa={chispa(serie?.nuevas ?? [], 'Pacientes nuevos en la clínica, últimas ocho semanas')}
      />
      <CifraConTendencia
        titulo="Cobrado a tiempo (%)"
        valor={l.aTiempo.pct === null ? '—' : formatPorcentaje(l.aTiempo.pct, 0)}
        senal={senalPorUmbralAlto(l.aTiempo.pct, umbralCobroATiempo(parametros), pctEntero)}
        info={`Cuotas de financiamientos en esta clínica que vencían esta semana y ya cerraron su plazo (el vencimiento más ${d.graciaDias} días de gracia): las pagadas dentro de él entre todas ellas. Un pago cuenta el día en que se registró.`}
        pie={pieDelCobro(l.aTiempo)}
        link={{ to: '/admin/metricas', search: busquedaDeMetricas('mora', {}, comun) }}
      />
      <CifraConTendencia
        titulo="Vencido (financiamiento + fee)"
        valor={formatUsd(l.vencido.payableUsd)}
        info={`Financiamiento + fee: las cuotas de financiamientos en esta clínica (de cualquier semana) vencidas y sin pagar ${d.semana.enCurso ? 'hoy' : 'al cierre de la semana'}. Debajo, cada parte por separado: su financiamiento y el service fee (IVA incluido). Lo dado por perdido no entra.`}
        pie={textoDeDesglose(l.vencido)}
        link={{ to: '/admin/metricas', search: busquedaDeMetricas('mora', {}, comun) }}
      />
      <CifraConTendencia
        titulo={rotuloDelCierre(d.cierre)}
        valor={formatUsd(totalDelCierre(l.transferencia))}
        info="Calculado de las liquidaciones: lo que se le paga por las cuotas que vencen esta semana, se paguen o no, cada mitad el día siguiente a su vencimiento. Es su neto, que no lleva la Comisión Helios. Es lo mismo que dice Pagos a clínicas; lo atrasado de semanas anteriores va en el pie, aparte."
        pie={pieDelCierre(l.transferencia, d.cierre)}
        link={{ to: '/admin/pagos-clinicas' }}
      />
    </StatGrid>
  )
}
