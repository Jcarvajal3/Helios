/**
 * Pruebas de los pies de las cifras de un local.
 *
 *   npx tsx src/features/admin/metricas/locales/cifras.test.ts
 *
 * Lo que se vigila: que sin cuotas juzgadas se diga por qué no hay
 * porcentaje, que el cierre sume lo generado y lo que falta por generar (y
 * lo diga), y que un ticket de una semana sin consumos no sea cero.
 */
import { textoDeDesglose } from '@/features/admin/metricas/formato'

import { desgloseSiLoHay, pieDeLaParte, pieDelCierre, pieDelCobro, ticketsPorSemana, totalDelCierre } from './cifras'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

console.log('── Cobrado a tiempo ──────────────────────────────────────────')
igual(pieDelCobro({ vencen: 0, juzgadas: 0, aTiempo: 0, pct: null }), 'No le vencía ninguna cuota esta semana', 'sin cuotas')
igual(pieDelCobro({ vencen: 3, juzgadas: 0, aTiempo: 0, pct: null }), 'Le vencen 3 cuotas: siguen en plazo', 'sin juzgadas todavía')
igual(pieDelCobro({ vencen: 22, juzgadas: 18, aTiempo: 15, pct: 83.3 }), '15 de 18 juzgadas · 4 en plazo', 'juzgadas y en plazo')
igual(pieDelCobro({ vencen: 18, juzgadas: 18, aTiempo: 15, pct: 83.3 }), '15 de 18 juzgadas', 'todas juzgadas')

console.log('── El cierre ─────────────────────────────────────────────────')
const t = { generadoUsd: 300, transferidoUsd: 0, pendienteUsd: 300, previstoUsd: 142, atrasadoUsd: 0 }
igual(totalDelCierre(t), 442, 'lo generado más lo previsto')
igual(pieDelCierre(t, { lunes: '2026-09-28', pasado: false }), '$300,00 generado + $142,00 hasta el domingo', 'en curso: las dos partes')
igual(pieDelCierre({ ...t, previstoUsd: 0 }, { lunes: '2026-09-28', pasado: false }), 'Todo generado · se paga el lunes 28', 'en curso, todo generado')
igual(pieDelCierre({ ...t, previstoUsd: 0 }, { lunes: '2026-09-21', pasado: true }), 'Faltan $300,00 por transferir', 'ya pasó y falta')
igual(
  pieDelCierre({ ...t, previstoUsd: 0, pendienteUsd: 0, transferidoUsd: 300 }, { lunes: '2026-09-21', pasado: true }),
  'Transferido entero',
  'ya pasó y se pagó',
)
igual(
  pieDelCierre({ generadoUsd: 0, transferidoUsd: 0, pendienteUsd: 0, previstoUsd: 0, atrasadoUsd: 0 }, { lunes: '2026-09-28', pasado: false }),
  'No le vence nada esta semana',
  'nada que transferir',
)
igual(
  pieDelCierre({ ...t, atrasadoUsd: 279.25 }, { lunes: '2026-09-28', pasado: false }),
  '$142,00 por generar · más $279,25 atrasado',
  'lo atrasado de cierres anteriores también se dice',
)
igual(
  pieDelCierre({ ...t, previstoUsd: 0, atrasadoUsd: 279.25 }, { lunes: '2026-09-28', pasado: false }),
  'Todo generado · más $279,25 atrasado de cierres anteriores',
  'todo generado, con atraso',
)
igual(
  pieDelCierre({ ...t, previstoUsd: 0, atrasadoUsd: 279.25 }, { lunes: '2026-09-21', pasado: true }),
  'Faltan $300,00 por transferir',
  'de un cierre pasado no se dice el atraso de entonces',
)

console.log('── Ticket y parte ────────────────────────────────────────────')
igual(
  ticketsPorSemana({ merchantId: 'a', nombre: 'A', primerConsumo: null, consumoUsd: [0, 60, 90], consumos: [0, 2, 3], personas: [], nuevas: [] }),
  [null, 30, 30],
  'una semana sin financiamientos no tiene ticket',
)
igual(pieDeLaParte(54.8), '55 % del financiado de todas las clínicas', 'la parte')
igual(pieDeLaParte(null), 'Ninguna clínica se financió', 'sin financiamiento de nadie')

console.log('── El desglose ───────────────────────────────────────────────')
// Las palabras del desglose son las de toda Métricas (`textoDeDesglose`):
// aquí se vigila que se use ese texto con las dos partes, no cómo se escribe.
igual(
  desgloseSiLoHay(87.82, 20.38),
  textoDeDesglose({ financedUsd: 87.82, feeUsd: 20.38 }),
  'con sus dos partes, con las palabras de toda Métricas',
)
igual(desgloseSiLoHay(87.82, 20.38)?.includes('$87,82') && desgloseSiLoHay(87.82, 20.38)?.includes('$20,38'), true, 'las dos cifras, escritas')
igual(desgloseSiLoHay(87.82, null), null, 'si falta una parte, no se inventa')

if (fallos > 0) {
  console.error(`\n${fallos} prueba(s) fallaron`)
  process.exit(1)
}
console.log('\nTodo bien.')
