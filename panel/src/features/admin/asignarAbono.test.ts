/**
 * Pruebas de la sugerencia al asignar un abono sin dueño.
 *
 *   npx tsx src/features/admin/asignarAbono.test.ts
 *
 * Una sugerencia mala es peor que ninguna: marca cuotas de más y el operador
 * confirma lo que ya viene marcado.
 */
import {
  cargosQueViajan,
  cuotasPendientes,
  cuotasPorConsumo,
  montoDeLaSeleccion,
  repartirCargos,
  sugerirCuotas,
} from './asignarAbono'
import type { CargoDeLaPersona, CuotaDeLaPersona } from './asignarAbono'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function cuota(id: string, parcial: Partial<CuotaDeLaPersona>): CuotaDeLaPersona {
  return {
    id,
    chargeId: 'c1',
    sequence: 1,
    amountUsd: 10,
    dueDate: '2026-09-10',
    status: 'pending',
    merchantName: 'Bar Nocturno',
    ...parcial,
  }
}

function cargo(id: string, parcial: Partial<CargoDeLaPersona>): CargoDeLaPersona {
  return {
    id,
    amountUsd: 2,
    status: 'pending',
    waivedAt: null,
    installmentId: null,
    sequence: 1,
    dueDate: '2026-09-10',
    merchantName: 'Bar Nocturno',
    ...parcial,
  }
}

// Dos consumos: c1 (cuotas a1, a2) y c2 (b1, b2). a1 ya está pagada.
const todas = [
  cuota('a1', { status: 'paid', dueDate: '2026-09-03' }),
  cuota('a2', { sequence: 2, dueDate: '2026-09-10' }),
  cuota('b1', { chargeId: 'c2', dueDate: '2026-09-12', amountUsd: 6 }),
  cuota('b2', { chargeId: 'c2', sequence: 2, dueDate: '2026-09-19', amountUsd: 6 }),
]
const pendientes = cuotasPendientes(todas)

console.log('── Las cuotas ───────────────────────────────────────────────')
{
  comprueba(pendientes.map((c) => c.id).join() === 'a2,b1,b2', 'pendientes, de la más vieja a la más nueva', pendientes.map((c) => c.id).join())
  const n = cuotasPorConsumo(todas)
  comprueba(n.get('c1') === 2 && n.get('c2') === 2, '«de N» sale de los datos, con las pagadas')
}

console.log('\n── Los cargos por atraso ────────────────────────────────────')
const cargos = [
  cargo('f-a2', { installmentId: 'a2', sequence: 2, dueDate: '2026-09-10' }),
  // De la cuota a1, que ya se pagó: huérfano, viaja con cualquier pago.
  cargo('f-a1', { installmentId: 'a1', sequence: 1, dueDate: '2026-09-03' }),
  cargo('f-condonado', { installmentId: 'b1', sequence: 1, dueDate: '2026-09-12', waivedAt: '2026-09-15T10:00:00Z' }),
  cargo('f-pagado', { installmentId: 'b1', status: 'paid', sequence: 1, dueDate: '2026-09-12' }),
]
const reparto = repartirCargos(pendientes, cargos)
{
  comprueba(reparto.porCuota.get('a2')?.[0]?.id === 'f-a2', 'el cargo va con su cuota')
  comprueba(reparto.huerfanos.map((c) => c.id).join() === 'f-a1', 'el de una cuota pagada es huérfano', reparto.huerfanos.map((c) => c.id).join())
  comprueba(!reparto.porCuota.has('b1'), 'los condonados y los pagados no cuentan')

  // Dos cuotas con el mismo número, vencimiento y local (dos consumos de la
  // misma noche): solo el id dice de cuál es el cargo.
  const gemelas = [cuota('x1', { chargeId: 'cx' }), cuota('y1', { chargeId: 'cy' })]
  const exacto = repartirCargos(gemelas, [cargo('f-y1', { installmentId: 'y1' })])
  comprueba(exacto.porCuota.get('y1')?.[0]?.id === 'f-y1' && !exacto.porCuota.has('x1'), 'con cuotas gemelas, el cargo va con la suya')
  const sinCuota = repartirCargos(gemelas, [cargo('f-viejo', {})])
  comprueba(sinCuota.huerfanos.map((c) => c.id).join() === 'f-viejo', 'uno sin cuota, de antes del reparto, es huérfano')

  const viajan = cargosQueViajan(new Set(['b1']), reparto).map((c) => c.id)
  comprueba(viajan.join() === 'f-a1', 'con b1 viaja solo el huérfano', viajan.join())
  comprueba(cargosQueViajan(new Set(), reparto).length === 0, 'sin selección no viaja nada')

  const m = montoDeLaSeleccion(pendientes, new Set(['a2']), reparto)
  comprueba(m.cuotasUsd === 10 && m.cargosUsd === 4, 'a2 cuesta su cuota más dos cargos', JSON.stringify(m))
}

console.log('\n── La sugerencia ────────────────────────────────────────────')
{
  // a2 (10) + su cargo (2) + el huérfano (2) = 14.
  comprueba(sugerirCuotas(14, pendientes, reparto)?.join() === 'a2', 'la más vieja con sus cargos')
  comprueba(sugerirCuotas(14.6, pendientes, reparto)?.join() === 'a2', 'dentro del dólar de tolerancia')
  // 14 + b1 (6) = 20.
  comprueba(sugerirCuotas(20, pendientes, reparto)?.join() === 'a2,b1', 'las dos más viejas')
  // b2 suelta: 6 + huérfano 2 = 8. Ninguna tanda da 8.
  comprueba(sugerirCuotas(8, pendientes, reparto)?.join() === 'b1', 'una suelta, la más vieja que cuadra')
  comprueba(sugerirCuotas(50, pendientes, reparto) === null, 'nada cuadra: sin sugerencia')
  comprueba(sugerirCuotas(10, [], repartirCargos([], [])) === null, 'sin cuotas: sin sugerencia')
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
