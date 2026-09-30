/**
 * Pruebas de la frase de la pestaña Locales.
 *
 *   npx tsx src/features/admin/metricas/locales/frase.test.ts
 *
 * Las cifras van entre asteriscos (**así**) para ver cuáles se destacan. Lo
 * que se vigila: que diga con qué se compara (a la misma altura si la semana
 * va a medias), que con un empate no corone a nadie, que sin ventas no se
 * invente nada y que un solo local no se «lleve el 100 %».
 */
import type { ParteDeFrase } from '@/components/admin/metricas/kit/FraseConCifras'

import { RESPUESTA_SEMANA } from './__fixtures__/semana'
import { fraseDeLaSemana, fraseDelLocal } from './frase'
import { leerLocalesDeLaSemana } from './lectura'
import type { FilaLocal, LocalesDeLaSemana } from './tipos'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const ok = dio === esperado
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : `\n          dio:      ${String(dio)}\n          esperado: ${String(esperado)}`}`)
}

function texto(partes: ReadonlyArray<ParteDeFrase>): string {
  return partes.map((p) => (typeof p === 'string' ? p : `**${p.cifra}**`)).join('')
}

const d = leerLocalesDeLaSemana(RESPUESTA_SEMANA)
const cerrada: LocalesDeLaSemana = {
  ...d,
  semana: { desde: '2026-09-14', hasta: '2026-09-20', enCurso: false },
  anterior: { desde: '2026-09-07', hasta: '2026-09-13', mismaAltura: false },
}
const [lq, em, nl, sv] = d.locales as [FilaLocal, FilaLocal, FilaLocal, FilaLocal]

console.log('── Todas las clínicas ─────────────────────────────────────────')
igual(
  texto(fraseDeLaSemana(d)),
  'Esta semana se financió en **3 clínicas**. La Quinta Bar se lleva el **55 %** del financiado y El Marchante crece un **20 %** frente a la semana pasada a la misma altura.',
  'el líder, su parte y el que más crece, a la misma altura',
)
igual(
  texto(fraseDeLaSemana({ ...cerrada, locales: [{ ...lq, consumoAnteriorUsd: 400 }, em] })),
  'La semana del 14 al 20 sep se financió en **2 clínicas**. La Quinta Bar se lleva el **55 %** del financiado y crece un **37 %** frente a la semana anterior.',
  'si el que más crece es el líder, no se repite su nombre',
)
igual(
  texto(fraseDeLaSemana({ ...d, locales: [{ ...lq, consumoUsd: 100 }, { ...em, consumoUsd: 100 }] })),
  'Esta semana se financió en **2 clínicas**. Empatan La Quinta Bar y El Marchante, con **$100,00** sin fee cada uno.',
  'un empate arriba se dice como empate',
)
igual(
  texto(fraseDeLaSemana({ ...d, locales: [nl, sv] })),
  'Esta semana se financió en **1 clínica**, Nueva Clínica: **$88,00** sin fee en 3 financiamientos.',
  'un solo clínica no «se lleva el 100 %»',
)
igual(texto(fraseDeLaSemana({ ...d, locales: [sv] })), 'Esta semana todavía no se ha financiado en ninguna clínica.', 'sin financiamientos, en curso')
igual(texto(fraseDeLaSemana({ ...cerrada, locales: [] })), 'La semana del 14 al 20 sep no se financió en ninguna clínica.', 'sin financiamientos, cerrada')

console.log('── Una clínica ──────────────────────────────────────────────────')
igual(
  texto(fraseDelLocal(d, em)),
  'El Marchante lleva esta semana **$364,00 financiado sin fee** en 13 financiamientos de **19 pacientes**, **20 % más** que la semana pasada a la misma altura. **9 pacientes** eran nuevos en la clínica.',
  'lo que lleva, contra qué y cuánta gente nueva',
)
igual(
  texto(fraseDelLocal(cerrada, { ...lq, nuevas: 0 })),
  'La Quinta Bar vendió la semana del 14 al 20 sep **$548,40 financiado sin fee** en 17 financiamientos de **27 pacientes**, **7 % más** que la semana anterior.',
  'una semana cerrada, sin gente nueva',
)
igual(
  texto(fraseDelLocal(d, { ...sv, consumoAnteriorUsd: 45 })),
  'Sin Financiamientos todavía no ha financiado esta semana. En la semana pasada a la misma altura llevaba **$45,00** sin fee.',
  'sin financiamientos, con lo que llevaba la anterior',
)

if (fallos > 0) {
  console.error(`\n${fallos} prueba(s) fallaron`)
  process.exit(1)
}
console.log('\nTodo bien.')
