import type { SenalDeCifra } from '@/components/ui'
import type { Capital } from '@/features/admin/semana'
import { senalPorUmbral } from '@/features/admin/umbrales'
import type { Umbral } from '@/features/admin/umbrales'

// ═══════════════════════════════════════════════════════════════════════════
// Las pastillas y las marcas de los medidores de los tableros.
//
// Módulo puro (`senales.test.ts`). El color de una cifra sale de un umbral y
// nunca de la pantalla: aquí se traducen a pastilla y a marcas los umbrales
// que ya existen (los de `umbrales.ts`, el punto de empate y el ciclo de
// cobro del capital), sin inventar ninguno.
// ═══════════════════════════════════════════════════════════════════════════

/** Un umbral escrito para una marca o una pastilla: '7 %', '15,6 %'. */
export function pctDeUmbral(n: number): string {
  return `${n.toLocaleString('es-VE', { maximumFractionDigits: 1 })} %`
}

/**
 * La pastilla del impago: la de sus umbrales y, pasen lo que pasen ellos,
 * crítica en cuanto llega al punto de empate, porque ahí Ronda pierde dinero.
 * Es la misma regla que `tonoDelImpago`, dicha como pastilla.
 */
export function senalDelImpago(
  tasa: number | null,
  empate: number | null,
  umbral: Umbral | null,
  formato: (n: number) => string = pctDeUmbral,
): SenalDeCifra | undefined {
  if (tasa === null || !Number.isFinite(tasa)) return undefined
  if (empate !== null && tasa >= empate) {
    return { tone: 'error', texto: `Crítico · empate ${formato(empate)}` }
  }
  return senalPorUmbral(tasa, umbral, formato)
}

/** Las marcas de un medidor con los dos cortes de un umbral, rotulados. */
export function marcasDeUmbral(
  umbral: Umbral | null,
  formato: (n: number) => string = pctDeUmbral,
): Array<{ valor: number; rotulo: string }> {
  if (!umbral) return []
  return [
    { valor: umbral.alerta, rotulo: formato(umbral.alerta) },
    { valor: umbral.critico, rotulo: formato(umbral.critico) },
  ]
}

/**
 * El tope de un medidor que tiene que enseñar la cifra y sus marcas: lo mayor
 * de todo, con un cuarto de aire para que la última marca no quede pegada al
 * borde. Sin nada mayor que cero, 1: un medidor vacío, no uno roto.
 */
export function topeDelMedidor(
  valores: ReadonlyArray<number | null | undefined>,
  holgura = 0.25,
): number {
  const finitos = valores.filter((v): v is number => typeof v === 'number' && Number.isFinite(v))
  const mayor = Math.max(0, ...finitos)
  return mayor > 0 ? mayor * (1 + holgura) : 1
}

/**
 * La pastilla del semáforo de capital. Sale del mismo corte que su color —el
 * ciclo de cobro—, y en verde no dice nada: que el capital alcance no es una
 * noticia.
 */
export function senalDelCapital(c: Pick<Capital, 'tono' | 'queda'>): SenalDeCifra | undefined {
  if (c.tono === 'error') {
    return { tone: 'error', texto: c.queda <= 0 ? 'Sin capital libre' : 'No cubre un ciclo' }
  }
  if (c.tono === 'warning') return { tone: 'warning', texto: 'Menos de dos ciclos' }
  return undefined
}

/**
 * Dónde se pone ámbar y dónde rojo el capital comprometido, en % del capital.
 *
 * Es la regla de `semaforoDeCapital` al revés: rojo cuando lo que queda no
 * cubre un ciclo de cobro al ritmo de ahora, ámbar cuando no cubre dos. Sin
 * ritmo, sin ciclo o sin capital no hay cortes. Una marca que caería fuera de
 * la pista (el capital no alcanza ni para un ciclo) no se pinta.
 */
export function marcasDelCapital({
  capital,
  ritmo,
  semanasDeCiclo,
}: {
  capital: number
  ritmo: number | null
  semanasDeCiclo: number | null
}): Array<{ valor: number; rotulo: string }> {
  if (capital <= 0 || ritmo === null || ritmo <= 0 || semanasDeCiclo === null) return []
  const corte = (ciclos: number) => (1 - (ciclos * semanasDeCiclo * ritmo) / capital) * 100
  return [
    { valor: corte(2), rotulo: '2 ciclos' },
    { valor: corte(1), rotulo: '1 ciclo' },
  ].filter((m) => m.valor > 0 && m.valor < 100)
}
