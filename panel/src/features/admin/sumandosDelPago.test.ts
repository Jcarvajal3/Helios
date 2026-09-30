/**
 * Pruebas de los sumandos de un pago reportado.
 *
 *   npx tsx src/features/admin/sumandosDelPago.test.ts
 *
 * Lo que se vigila: que lo que debía pagar sean sus cuotas MÁS sus cargos (no
 * una cuota suelta, que era el fallo de la ficha), que el desglose cuadre y
 * que sin desglose de la base no se invente uno.
 */
import { lineaDeSumandos, sumandosDeLosPagos, sumandosDelPago } from './sumandosDelPago'

let fallos = 0
function igual(nombre: string, obtenido: unknown, esperado: unknown) {
  const ok = JSON.stringify(obtenido) === JSON.stringify(esperado)
  if (!ok) {
    fallos++
    console.error(`✗ ${nombre}\n  esperado: ${JSON.stringify(esperado)}\n  obtenido: ${JSON.stringify(obtenido)}`)
  } else {
    console.log(`✓ ${nombre}`)
  }
}

const eur = (n: number) => `$${n.toFixed(2)}`

// El pago pendiente de dev (2026-09-28): 4 cuotas (30,00 + 6,96) y €8 de cargos.
const pendiente = {
  installmentsUsd: 36.96,
  installmentsFinancedUsd: 30,
  installmentsFeeUsd: 6.96,
  lateFeeUsd: 8,
}

igual('lo que debía = cuotas + cargos', sumandosDelPago(pendiente).totalUsd, 44.96)
igual('financiado + fee = cuotas', 30 + 6.96, sumandosDelPago(pendiente).cuotasUsd)
igual(
  'la línea lleva los tres sumandos',
  lineaDeSumandos(sumandosDelPago(pendiente), eur),
  'financiado $30.00 + service fee + IVA $6.96 + cargos por atraso $8.00',
)

const sinCargos = { ...pendiente, lateFeeUsd: 0 }
igual(
  'sin cargos no se nombran',
  lineaDeSumandos(sumandosDelPago(sinCargos), eur),
  'financiado $30.00 + service fee + IVA $6.96',
)

const baseVieja = { ...pendiente, installmentsFinancedUsd: null, installmentsFeeUsd: null }
igual('sin desglose de la base: sin línea', lineaDeSumandos(sumandosDelPago(baseVieja), eur), null)
igual('sin desglose: el total sigue', sumandosDelPago(baseVieja).totalUsd, 44.96)

const dos = sumandosDeLosPagos([pendiente, sinCargos])
igual('la lista suma cada sumando', [dos.facturadoUsd, dos.feeUsd, dos.cargosUsd], [60, 13.92, 8])
igual('la lista suma el total', Math.round(dos.totalUsd * 100) / 100, 81.92)

const mezcla = sumandosDeLosPagos([pendiente, baseVieja])
igual('uno sin desglose deja la lista sin desglose', [mezcla.facturadoUsd, mezcla.feeUsd], [null, null])
igual('lista vacía', sumandosDeLosPagos([]), {
  cuotasUsd: 0,
  facturadoUsd: 0,
  feeUsd: 0,
  cargosUsd: 0,
  totalUsd: 0,
})

if (fallos > 0) {
  console.error(`\n${fallos} fallo(s)`)
  process.exit(1)
}
console.log('\nTodo bien')
