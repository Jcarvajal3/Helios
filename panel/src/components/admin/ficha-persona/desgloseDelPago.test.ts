/**
 * Pruebas de los sumandos de un pago reportado en la ficha de un usuario.
 *
 *   npx tsx src/components/admin/ficha-persona/desgloseDelPago.test.ts
 *
 * Lo que se vigila: que el monto con fee nunca salga sin sus partes y que los
 * cargos por atraso vayan aparte, no mezclados con el fee.
 */
import { desgloseDelPago } from './desgloseDelPago'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('── Los sumandos de un pago ──────────────────────────────────')
// Julio Castillo, 04/08 en dev: €42,80 = cuotas €34,80 (28,25 + 6,55) + cargos €8,00.
const conCargos = desgloseDelPago({
  cuotasPayableUsd: 34.8,
  cuotasFinancedUsd: 28.25,
  cuotasFeeUsd: 6.55,
  lateFeesUsd: 8,
})
comprueba(
  conCargos.includes('financiamiento') && conCargos.includes('fee') && conCargos.includes('cargos por atraso'),
  'con cargos: financiamiento, fee y cargos, cada uno aparte',
  conCargos,
)
comprueba(conCargos.includes('8,00'), 'los cargos, con su cifra', conCargos)

const sinCargos = desgloseDelPago({
  cuotasPayableUsd: 18.49,
  cuotasFinancedUsd: 15,
  cuotasFeeUsd: 3.49,
  lateFeesUsd: 0,
})
comprueba(!sinCargos.includes('cargos'), 'sin cargos no se nombran', sinCargos)
comprueba(sinCargos.includes('15,00') && sinCargos.includes('3,49'), 'las dos partes de las cuotas', sinCargos)

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} ${fallos === 1 ? 'falla' : 'fallan'}.`)
if (fallos > 0) process.exit(1)
