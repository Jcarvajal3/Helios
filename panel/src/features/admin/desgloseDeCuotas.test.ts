/**
 * Pruebas del desglose de lo que se debe en cuotas.
 *
 *   npx tsx src/features/admin/desgloseDeCuotas.test.ts
 *
 * Lo que se vigila: que el fee sea lo que se paga menos el consumo, que la
 * suma no deje colas de coma flotante, y que un desglose que no cuadra con el
 * total que se enseña no salga nunca.
 */
import { desgloseDeCuotas, desgloseQueCuadra } from './desgloseDeCuotas'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const cuotas = [
  { amountUsd: 6.16, financedUsd: 5 },
  { amountUsd: 6.16, financedUsd: 5 },
  { amountUsd: 0.1, financedUsd: 0.1 },
  { amountUsd: 0.2, financedUsd: 0.2 },
]

console.log('── El desglose ───────────────────────────────────────────────')
igual(desgloseDeCuotas(cuotas), { payableUsd: 12.62, financedUsd: 10.3, feeUsd: 2.32 }, 'financiamiento + fee = lo que se paga')
igual(desgloseDeCuotas([]), { payableUsd: 0, financedUsd: 0, feeUsd: 0 }, 'sin cuotas, todo a cero')
igual(desgloseDeCuotas([{ amountUsd: 0.1, financedUsd: 0 }, { amountUsd: 0.2, financedUsd: 0 }]).payableUsd, 0.3, 'sin colas de coma flotante')

console.log('\n── Solo si cuadra ────────────────────────────────────────────')
igual(desgloseQueCuadra(cuotas, 12.62)?.feeUsd ?? null, 2.32, 'cuadra con el total: sale')
igual(desgloseQueCuadra(cuotas, 12.63)?.feeUsd ?? null, 2.32, 'a un céntimo, también (redondeos del servidor)')
igual(desgloseQueCuadra(cuotas, 17.62), null, 'con cinco dólares de más (un cargo por atraso) no sale')
igual(desgloseQueCuadra(cuotas, 0), null, 'sin deuda no hay desglose que enseñar')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
