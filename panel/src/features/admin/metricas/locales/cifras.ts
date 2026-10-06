import { formatUsd, formatPorcentaje } from '@/components/ui'
import { textoDeDesglose } from '@/features/admin/metricas/formato'

import { diaConNumero } from './semanas'
import type { ATiempoDeLaSemana, LocalesDeLaSemana, SerieDeLocal, Transferencia } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// Los pies de las cifras de un local (una línea con números dentro) y las
// series de sus chispas.
//
// Puro: se prueba en `cifras.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** El ticket de cada semana de la serie; `null` en una semana sin consumos. */
export function ticketsPorSemana(s: SerieDeLocal): Array<number | null> {
  return s.consumoUsd.map((consumo, i) => {
    const n = s.consumos[i] ?? 0
    return n > 0 ? consumo / n : null
  })
}

/** «18 de 22 cuotas que vencían», o por qué todavía no hay veredicto. */
export function pieDelCobro(a: ATiempoDeLaSemana): string {
  if (a.vencen === 0) return 'No le vencía ninguna cuota esta semana'
  if (a.juzgadas === 0) {
    return a.vencen === 1 ? 'Le vence 1 cuota: sigue en plazo' : `Le vencen ${a.vencen} cuotas: siguen en plazo`
  }
  const enPlazo = a.vencen - a.juzgadas
  return `${a.aTiempo} de ${a.juzgadas} juzgadas${enPlazo > 0 ? ` · ${enPlazo} en plazo` : ''}`
}

/** Lo que se le transfiere en el cierre: lo generado más lo que falta por generar. */
export function totalDelCierre(t: Transferencia): number {
  return t.generadoUsd + t.previstoUsd
}

/**
 * El pie del cierre: qué parte falta por generar (o por transferir, si ya
 * pasó) y lo atrasado de semanas anteriores.
 */
export function pieDelCierre(t: Transferencia, cierre: LocalesDeLaSemana['cierre']): string {
  const atrasado = !cierre.pasado && t.atrasadoUsd > 0.005 ? `más ${formatUsd(t.atrasadoUsd)} atrasado` : null
  if (totalDelCierre(t) <= 0) {
    return atrasado ? `Nada de esta semana; ${atrasado} de semanas anteriores` : 'No le vence nada esta semana'
  }
  if (cierre.pasado) {
    return t.pendienteUsd > 0.005 ? `Faltan ${formatUsd(t.pendienteUsd)} por transferir` : 'Transferido entero'
  }
  if (t.previstoUsd > 0.005) {
    return atrasado
      ? `${formatUsd(t.previstoUsd)} por generar · ${atrasado}`
      : `${formatUsd(t.generadoUsd)} generado + ${formatUsd(t.previstoUsd)} hasta el domingo`
  }
  return atrasado ? `Todo generado · ${atrasado} de semanas anteriores` : `Todo generado · se termina de pagar el ${diaConNumero(cierre.lunes)}`
}

/** «55 % del facturado de todos los locales». */
export function pieDeLaParte(partePct: number | null): string {
  return partePct === null ? 'Ninguna clínica se financió' : `${formatPorcentaje(partePct, 0)} del financiado de todas las clínicas`
}

/**
 * El desglose de un importe en cuotas si la base mandó sus dos partes; si
 * falta alguna, `null`: el desglose no se inventa.
 */
export function desgloseSiLoHay(financedUsd: number | null, feeUsd: number | null): string | null {
  return financedUsd === null || feeUsd === null ? null : textoDeDesglose({ financedUsd, feeUsd })
}
