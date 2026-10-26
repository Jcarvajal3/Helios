/**
 * Pruebas de la moneda y la tasa de un pago reportado.
 *
 *   npx tsx src/features/admin/tasaDelPago.test.ts
 */
import { etiquetaDeLaTasa, partesDelPago } from './tasaDelPago'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const base = { amountUsd: 15.99, fxRate: 886.2271 }

// Una cuota de una orden en euros: toda a la tasa del euro, en euros.
const euros = partesDelPago({
  ...base,
  monedas: ['EUR'],
  fxRateEur: 993.088364,
  amountEur: 14.24,
  usdPartUsd: 0,
  eurPartUsd: 15.99,
})
comprueba(
  euros.length === 1 && euros[0].moneda === 'EUR' && euros[0].monto === 14.24 && euros[0].tasa === 993.088364,
  'un pago de una orden en euros va a la tasa del euro, en euros',
  JSON.stringify(euros),
)

// Una en dólares: a la del dólar.
const dolares = partesDelPago({
  amountUsd: 85.44,
  fxRate: 886.2271,
  monedas: ['USD'],
  fxRateEur: null,
  amountEur: null,
  usdPartUsd: 85.44,
  eurPartUsd: 0,
})
comprueba(
  dolares.length === 1 && dolares[0].moneda === 'USD' && dolares[0].monto === 85.44 && dolares[0].tasa === 886.2271,
  'un pago de una orden en dólares va a la tasa del dólar',
  JSON.stringify(dolares),
)

// Las dos: dólares primero, cada parte a la suya.
const mezcla = partesDelPago({
  amountUsd: 101.43,
  fxRate: 886.2271,
  monedas: ['USD', 'EUR'],
  fxRateEur: 993.088364,
  amountEur: 14.24,
  usdPartUsd: 85.44,
  eurPartUsd: 15.99,
})
comprueba(
  mezcla.map((p) => `${p.moneda}:${p.monto}`).join(' ') === 'USD:85.44 EUR:14.24',
  'con las dos monedas, una parte por moneda y dólares primero',
  JSON.stringify(mezcla),
)

// Una base sin la migración: todo en dólares, como antes.
const vieja = partesDelPago(base)
comprueba(
  vieja.length === 1 && vieja[0].moneda === 'USD' && vieja[0].monto === 15.99,
  'sin las monedas en la base, todo el pago es en dólares',
  JSON.stringify(vieja),
)

comprueba(etiquetaDeLaTasa('EUR') === 'Tasa euro' && etiquetaDeLaTasa('USD') === 'Tasa dólar', 'las etiquetas')

if (fallos > 0) {
  console.log(`\n${fallos} ${fallos === 1 ? 'prueba falla' : 'pruebas fallan'}`)
  process.exit(1)
}
console.log('\nTodo en verde.')
