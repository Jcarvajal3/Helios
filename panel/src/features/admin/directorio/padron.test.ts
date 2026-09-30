/**
 * Pruebas de las cifras del padrón (Directorio › Usuarios).
 *
 *   npx tsx src/features/admin/directorio/padron.test.ts
 */
import { formatUsd } from '@/components/ui'
import { sumandosDeDeuda, vencidoDelPadron } from './padron'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('── Los sumandos de una deuda ────────────────────────────────')
{
  const texto = sumandosDeDeuda({ financedUsd: 37, feeUsd: 8.2 })
  const esperado = `${formatUsd(37)} financiado + ${formatUsd(8.2)} service fee + IVA`
  comprueba(texto === esperado, 'financiado + service fee + IVA, con el vocabulario', texto)
}

console.log('── Lo vencido de la página ──────────────────────────────────')
{
  const filas = [
    { isTest: false, overdueUsd: 45.2, overdueDesglose: { financedUsd: 37, feeUsd: 8.2 } },
    { isTest: false, overdueUsd: 12.3, overdueDesglose: { financedUsd: 10, feeUsd: 2.3 } },
    // Al día: no cuenta.
    { isTest: false, overdueUsd: 0, overdueDesglose: { financedUsd: 0, feeUsd: 0 } },
    // De prueba: sale en la lista, pero no suma.
    { isTest: true, overdueUsd: 99, overdueDesglose: { financedUsd: 80, feeUsd: 19 } },
  ]
  const r = vencidoDelPadron(filas)
  comprueba(r.usuarios === 2, 'cuenta solo a los pacientes reales con algo vencido', String(r.usuarios))
  comprueba(Math.abs(r.vencidoUsd - 57.5) < 1e-9, 'suma lo vencido con el fee dentro', String(r.vencidoUsd))
  comprueba(
    r.partes !== null && Math.abs(r.partes.financedUsd - 47) < 1e-9 && Math.abs(r.partes.feeUsd - 10.5) < 1e-9,
    'los sumandos suman por separado',
    JSON.stringify(r.partes),
  )
  comprueba(
    r.partes !== null && Math.abs(r.partes.financedUsd + r.partes.feeUsd - r.vencidoUsd) < 1e-9,
    'financiado + service fee + IVA = vencido',
  )
}
{
  const r = vencidoDelPadron([
    { isTest: false, overdueUsd: 10, overdueDesglose: { financedUsd: 8, feeUsd: 2 } },
    { isTest: false, overdueUsd: 5, overdueDesglose: null },
  ])
  comprueba(r.partes === null, 'sin los sumandos de alguna fila, no se inventan', JSON.stringify(r.partes))
  comprueba(r.vencidoUsd === 15 && r.usuarios === 2, 'el importe y el recuento siguen saliendo')
}
{
  const r = vencidoDelPadron([])
  comprueba(r.usuarios === 0 && r.vencidoUsd === 0 && r.partes !== null, 'una página vacía da cero, con sumandos cero')
}

if (fallos > 0) {
  console.log(`\n${fallos} ${fallos === 1 ? 'prueba falla' : 'pruebas fallan'}`)
  process.exit(1)
}
console.log('\nTodo bien')
