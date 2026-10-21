import { formatDayShort, formatUsd } from '@/components/ui'
import type { ParteDeFrase } from '@/components/admin/metricas/kit'
import { textoDeDesglose } from '@/features/admin/metricas/formato'
import type { Desglose } from '@/features/admin/metricas/lectura'
import { describirSemana } from '@/features/admin/semana'
import type { CajaDeLaSemana, Movimientos, SemanaDeCaja } from './lectura'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que Métricas › Caja escribe con las cifras de la base: la frase de la
// semana, el rótulo de cada semana, el reparto de lo que se esperaba cobrar y
// el aviso cuando el libro no cuadra con las cuotas. Ninguna cifra de negocio
// nace aquí: son proporciones y frases de cifras que ya da la base.
//
// Puro: se prueba en `calculos.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Por debajo de esto, dos importes son el mismo (un céntimo). */
const CENTIMO = 0.005

/**
 * La frase de arriba de la pestaña, con los números dentro. Lo que entró de
 * cuotas va SIEMPRE con su desglose (regla de la comisión); los cargos por atraso
 * no entran en la frase.
 *
 * Sin local: lo que entró, lo que salió a los locales y la caja. Con local:
 * lo que entró por sus consumos, lo que se le transfirió y lo que se le debe
 * hoy (la caja no es de ningún local).
 */
export function fraseDeLaSemana(c: CajaDeLaSemana, nombreLocal: string | null): ParteDeFrase[] {
  const m = c.movimientos
  const enCurso = c.semana?.enCurso ?? false
  const entro: ParteDeFrase[] = [
    { cifra: `${formatUsd(m.cobrado.payableUsd)} de cuotas` },
    ` (${textoDeDesglose(m.cobrado).replace('Financiamiento', 'financiamiento')})`,
  ]

  if (c.merchantId) {
    const quien = nombreLocal ?? 'esta clínica'
    const cuando = enCurso ? 'En lo que va de semana, de' : 'Esa semana, de'
    const transferido =
      m.transferido.usd > 0
        ? [' y se le transfirieron ', { cifra: formatUsd(m.transferido.usd) }]
        : [' y no se le transfirió nada']
    return [
      `${cuando} los financiamientos de ${quien} entraron `,
      ...entro,
      ...transferido,
      '; hoy se le deben ',
      { cifra: formatUsd(c.porPagarLocales.totalUsd) },
      '.',
    ]
  }

  const cuando = enCurso
    ? 'En lo que va de semana entraron '
    : `La semana ${c.semana ? describirSemana(c.semana.desde) : ''} entraron `
  const caja: ParteDeFrase[] = c.caja
    ? [enCurso ? '; la caja va por ' : '; la caja cerró en ', { cifra: formatUsd(c.caja.alCierreUsd) }]
    : []
  return [
    cuando,
    ...entro,
    ' y salieron ',
    { cifra: formatUsd(m.transferido.usd) },
    ' a las clínicas',
    ...caja,
    '.',
  ]
}

/** «14–20 sep», «31 ago–6 sep»: el rótulo corto de una semana. */
export function etiquetaDeSemana(s: Pick<SemanaDeCaja, 'lunes' | 'domingo'>): string {
  const desde = formatDayShort(s.lunes)
  const hasta = formatDayShort(s.domingo)
  const [diaDesde, mesDesde] = desde.split(' ')
  const [, mesHasta] = hasta.split(' ')
  return mesDesde === mesHasta ? `${diaDesde}–${hasta}` : `${desde}–${hasta}`
}

/**
 * El rótulo de una semana con las dos partes de lo cobrado: «14–20 sep
 * (consumo $723,97 + service fee $168,01)». Es el título del globo de la
 * chispa de «Entró de cuotas»: tampoco ahí va un importe en cuotas sin sus
 * partes.
 */
export function etiquetaConDesglose(s: Pick<SemanaDeCaja, 'lunes' | 'domingo' | 'cobrado'>): string {
  return `${etiquetaDeSemana(s)} (${textoDeDesglose(s.cobrado).replace('Financiamiento', 'financiamiento')})`
}

/**
 * Lo que va en el globo de cada semana de «Cobro esperado y cobro real»,
 * debajo de las dos cifras: de qué está hecho lo cobrado (el consumo, el
 * service fee y, aparte, los cargos por atraso) y si la semana va a medias.
 * Sin las partes todavía (la lectura de la semana no ha llegado), solo lo de
 * la semana en curso. Un importe en cuotas no sale ni en un globo sin sus
 * partes cerca.
 */
export function notaDeLoCobrado(
  partes: Pick<SemanaDeCaja, 'cobrado' | 'cargosCobradosUsd'> | undefined,
  enCurso: boolean,
): string | undefined {
  const hayPartes = partes !== undefined && (partes.cobrado.payableUsd > 0 || partes.cargosCobradosUsd > 0)
  const cobrado = hayPartes
    ? `Cobrado: ${textoDeDesglose(partes.cobrado).replace('Financiamiento', 'financiamiento')}${
        partes.cargosCobradosUsd > 0 ? ` · cargos por atraso ${formatUsd(partes.cargosCobradosUsd)}` : ''
      }`
    : null
  if (enCurso) return cobrado ? `En curso · ${cobrado}` : 'En curso'
  return cobrado ?? undefined
}

/**
 * Lo que se esperaba cobrar una semana, partido como lo que vencía esa
 * semana. La foto del lunes solo guarda el total (con el fee dentro); como
 * el service fee es un porcentaje fijo del consumo de cada cuota, la
 * proporción de lo que vencía es la de lo que se esperaba. `null` si esa
 * semana no vencía nada con que repartirlo.
 */
export function repartirComoVencia(esperadoUsd: number, vencia: Desglose): Desglose | null {
  if (!(vencia.payableUsd > 0)) return null
  const financedUsd = Math.round(((esperadoUsd * vencia.financedUsd) / vencia.payableUsd) * 100) / 100
  return { payableUsd: esperadoUsd, financedUsd, feeUsd: Math.round((esperadoUsd - financedUsd) * 100) / 100 }
}

/**
 * Lo que el libro de caja dice que entró por pagos de cuotas y lo que dicen
 * las cuotas (más los cargos por atraso cobrados), si no cuadran. `null`
 * cuando cuadran o cuando no hay libro (con un local). La diferencia suele
 * ser un pago aprobado con otro día operativo en el libro.
 */
export function descuadreDelLibro(m: Movimientos): { cobradoUsd: number; transferidoUsd: number } | null {
  if (!m.libro) return null
  const cobradoUsd = m.libro.cobradoUsd - (m.cobrado.payableUsd + m.cargosCobrados.usd)
  const transferidoUsd = m.libro.transferidoUsd - m.transferido.usd
  if (Math.abs(cobradoUsd) < CENTIMO && Math.abs(transferidoUsd) < CENTIMO) return null
  return { cobradoUsd, transferidoUsd }
}
