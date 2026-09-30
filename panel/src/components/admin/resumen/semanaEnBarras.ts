import { sumarDias } from '@/components/ui'
import type { PuntoDeMiniBarras } from '@/components/charts'
import type { DayPoint } from '@/features/admin/metrics'

const INICIALES = ['L', 'M', 'X', 'J', 'V', 'S', 'D'] as const

/**
 * Lo financiado de cada día de una semana, para las barras de la cifra
 * titular del Resumen. Módulo puro (`semanaEnBarras.test.ts`).
 *
 * Los días que no han llegado van como futuro (`null`) y hoy va destacado. Si
 * la serie diaria no llega a algún día ya pasado —una semana más vieja que
 * los catorce días que se piden—, no hay barras: siete barras con huecos se
 * leerían como noches sin consumo.
 */
export function diasDeLaSemana(
  lunes: string,
  hoy: string,
  serie: ReadonlyArray<Pick<DayPoint, 'businessDate' | 'financedUsd'>> | undefined,
): PuntoDeMiniBarras[] | null {
  if (!serie) return null
  const porDia = new Map(serie.map((p) => [p.businessDate, p.financedUsd]))
  const puntos: PuntoDeMiniBarras[] = []

  for (const [i, rotulo] of INICIALES.entries()) {
    const dia = sumarDias(lunes, i)
    if (dia > hoy) {
      puntos.push({ rotulo, valor: null })
      continue
    }
    const valor = porDia.get(dia)
    if (valor === undefined) return null
    puntos.push({ rotulo, valor, destacado: dia === hoy })
  }

  return puntos
}
