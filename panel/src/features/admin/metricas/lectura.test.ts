/**
 * Pruebas de las piezas comunes de las respuestas de Métricas.
 *
 *   npx tsx src/features/admin/metricas/lectura.test.ts
 *
 * Lo que se vigila: que la semana y el «hoy» de la base se lean o se digan
 * ausentes (nunca inventados), y que un importe que se paga no se pueda leer
 * sin sus dos partes.
 */
import { leerDesglose, leerHoyUsado, leerSemanaUsada } from './lectura'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

console.log('── La semana y el hoy que usó la base ────────────────────────')
igual(
  leerSemanaUsada({ desde: '2026-09-21', hasta: '2026-09-27', en_curso: true }),
  { desde: '2026-09-21', hasta: '2026-09-27', enCurso: true },
  'la semana, tal cual',
)
igual(
  leerSemanaUsada({ desde: '2026-09-14', hasta: '2026-09-20' }),
  { desde: '2026-09-14', hasta: '2026-09-20', enCurso: false },
  'sin `en_curso`, cerrada',
)
igual(leerSemanaUsada({ desde: '2026-09-14' }), null, 'sin `hasta` no hay semana')
igual(leerSemanaUsada(null), null, 'sin nada, nada')
igual(leerHoyUsado('2026-09-26'), '2026-09-26', 'el hoy de la base')
igual(leerHoyUsado('mañana'), null, 'un hoy roto no se inventa')

console.log('\n── El desglose de lo que se paga ─────────────────────────────')
igual(
  leerDesglose({ payable_usd: 180.76, financed_usd: 146.72, fee_usd: 34.04 }),
  { payableUsd: 180.76, financedUsd: 146.72, feeUsd: 34.04 },
  'las tres partes',
)
igual(
  leerDesglose({ payable_usd: '12.32', financed_usd: '10' }),
  { payableUsd: 12.32, financedUsd: 10, feeUsd: 12.32 - 10 },
  'sin el fee, se deduce; los numeric que llegan como texto se leen',
)
igual(leerDesglose({ payable_usd: 12.32 }), null, 'sin el financiamiento no hay desglose')
igual(leerDesglose({ financed_usd: 10, fee_usd: 2.32 }), null, 'sin lo que se paga, tampoco')
igual(leerDesglose({ payable_usd: '', financed_usd: 10 }), null, 'un vacío es que falta')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
