import { formatUsd, formatPorcentaje } from '@/components/ui'
import type { ParteDeFrase } from '@/components/admin/metricas/kit/FraseConCifras'

import { conVentas, elQueMasConsumio, elQueMasCrecio, frenteALaAnterior, referenciaDeLaAnterior } from './rendimiento'
import { semanaEnFrase } from './semanas'
import type { FilaLocal, LocalesDeLaSemana } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// La frase de arriba de la pestaña, con las cifras dentro:
//
//   «Esta semana se consumió en **2 locales**. La Quinta Bar se lleva el
//    **60 %** del consumo y El Marchante crece un **20 %** frente a la semana
//    pasada a la misma altura.»
//
// y la de un local elegido. Una frase con los números vale más que un
// párrafo, y se lee antes que la tabla. Solo dice lo que dicen los datos:
// con un empate arriba no se corona a nadie. Todo importe de consumo dice
// que va sin el service fee.
//
// Puro: se prueba en `frase.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

function contar(n: number, una: string, varias: string): string {
  return `${n} ${n === 1 ? una : varias}`
}

/** «Esta semana», o «La semana del 14 al 20 sep». */
function sujeto(d: LocalesDeLaSemana): string {
  return d.semana.enCurso ? 'Esta semana' : `La semana ${semanaEnFrase(d.semana.desde)}`
}

/** «A», «A y B», «A, B y C». */
export function enumerar(nombres: ReadonlyArray<string>): string {
  if (nombres.length <= 1) return nombres.join('')
  return `${nombres.slice(0, -1).join(', ')} y ${nombres.at(-1) ?? ''}`
}

function pctEntero(pct: number): string {
  return formatPorcentaje(Math.round(pct), 0)
}

/** La frase de todos los locales. */
export function fraseDeLaSemana(d: LocalesDeLaSemana): ParteDeFrase[] {
  const vendieron = conVentas(d.locales)
  const ref = referenciaDeLaAnterior(d)

  if (vendieron.length === 0) {
    return [`${sujeto(d)} ${d.semana.enCurso ? 'todavía no se ha financiado' : 'no se financió'} en ninguna clínica.`]
  }

  const partes: ParteDeFrase[] = [`${sujeto(d)} se financió en `, { cifra: contar(vendieron.length, 'clínica', 'clínicas') }]
  const crecio = elQueMasCrecio(vendieron)

  if (vendieron.length === 1) {
    const [unico] = vendieron
    partes.push(`, ${unico.nombre}: `, { cifra: formatUsd(unico.consumoUsd) }, ` sin fee en ${contar(unico.consumos, 'financiamiento', 'financiamientos')}`)
    if (crecio) partes.push(', un ', { cifra: pctEntero(crecio.pct) }, ` más que ${ref}`)
    partes.push('.')
    return partes
  }

  partes.push('. ')
  const lider = elQueMasConsumio(vendieron)

  if (lider) {
    partes.push(`${lider.nombre} se lleva el `, { cifra: pctEntero(lider.partePct ?? 0) }, ' del financiado')
    if (crecio && crecio.local.merchantId === lider.merchantId) {
      partes.push(' y crece un ', { cifra: pctEntero(crecio.pct) }, ` frente a ${ref}.`)
    } else if (crecio) {
      partes.push(` y ${crecio.local.nombre} crece un `, { cifra: pctEntero(crecio.pct) }, ` frente a ${ref}.`)
    } else {
      partes.push('.')
    }
    return partes
  }

  // Empate arriba: se nombra a todos los que empatan.
  const arriba = vendieron.reduce((max, l) => Math.max(max, l.consumoUsd), 0)
  const empatados = vendieron.filter((l) => l.consumoUsd === arriba)
  partes.push(`Empatan ${enumerar(empatados.map((l) => l.nombre))}, con `, { cifra: formatUsd(arriba) }, ' sin fee cada una')
  if (crecio) partes.push(`, y ${crecio.local.nombre} crece un `, { cifra: pctEntero(crecio.pct) }, ` frente a ${ref}`)
  partes.push('.')
  return partes
}

/** La frase de un local elegido. */
export function fraseDelLocal(d: LocalesDeLaSemana, l: FilaLocal): ParteDeFrase[] {
  const ref = referenciaDeLaAnterior(d)
  const cuando = d.semana.enCurso ? 'esta semana' : `la semana ${semanaEnFrase(d.semana.desde)}`

  if (l.consumoUsd === 0) {
    const partes: ParteDeFrase[] = [
      `${l.nombre} ${d.semana.enCurso ? 'todavía no ha financiado nada' : 'no financió nada'} ${cuando}.`,
    ]
    if (l.consumoAnteriorUsd > 0) {
      partes.push(` En ${ref} llevaba `, { cifra: formatUsd(l.consumoAnteriorUsd) }, ' sin fee.')
    }
    return partes
  }

  const partes: ParteDeFrase[] = [
    `${l.nombre} lleva ${cuando} `,
    { cifra: `${formatUsd(l.consumoUsd)} financiado sin fee` },
    ` en ${contar(l.consumos, 'financiamiento', 'financiamientos')} de `,
    { cifra: contar(l.personas, 'paciente', 'pacientes') },
  ]
  if (!d.semana.enCurso) partes[0] = `${l.nombre} registró ${cuando} `

  const cambio = frenteALaAnterior(l)
  if (cambio && (cambio.direccion === 'sube' || cambio.direccion === 'baja')) {
    partes.push(', ', { cifra: cambio.texto }, ` que ${ref}`)
  } else if (cambio?.direccion === 'igual') {
    partes.push(`, lo mismo que ${ref}`)
  }
  partes.push('.')

  if (l.nuevas > 0) {
    partes.push(' ', { cifra: contar(l.nuevas, 'paciente', 'pacientes') }, ` ${l.nuevas === 1 ? 'era nuevo' : 'eran nuevos'} en la clínica.`)
  }
  return partes
}
