/**
 * Pruebas de los números de capacitación.
 *
 *   npx tsx src/features/admin/demo/demo.test.ts
 *
 * Lo que se vigila: que la lectura aguante los números como texto y el
 * «todavía no hubo reinicio», que el resumen diga lo que hizo el reinicio y
 * que el alta no salga con un dato vacío.
 */
import { BORRADOR_VACIO, faltaEnBorrador, leerEstadoDeDemo, resumenDeReinicio } from './demo'

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

// ── La lectura ─────────────────────────────────────────────────────────────

const estado = leerEstadoDeDemo({
  phones: [
    {
      phone_e164: '+584141110001',
      label: 'Carla',
      created_at: '2026-10-14T20:00:00Z',
      patients: '3',
      open_orders: 2,
      pending_orders: 1,
    },
  ],
  last_reset: {
    at: '2026-10-15T04:00:00Z',
    automatic: true,
    detail: {
      revertidas: 0,
      anuladas: 1,
      borrados: '4',
      ordenes_borradas: 5,
      retirados: 0,
      sin_reiniciar: [{ order_number: 41, motivo: 'pago abierto' }],
    },
  },
})

igual('el número y quién capacita', [estado.numeros[0].phone, estado.numeros[0].label], ['+584141110001', 'Carla'])
igual('los contadores, de texto a número', [estado.numeros[0].patients, estado.numeros[0].openOrders], [3, 2])
igual('el último reinicio, el de medianoche', estado.ultimoReinicio?.automatico, true)
igual('los borrados y sus órdenes', [estado.ultimoReinicio?.borrados, estado.ultimoReinicio?.ordenesBorradas], [4, 5])
igual('lo que no se pudo reiniciar', estado.ultimoReinicio?.sinReiniciar, [
  { orderNumber: 41, motivo: 'pago abierto' },
])
igual('sin reinicios todavía', leerEstadoDeDemo({ phones: [], last_reset: null }).ultimoReinicio, null)

// ── El resumen ─────────────────────────────────────────────────────────────

const nada = { revertidas: 0, anuladas: 0, borrados: 0, ordenesBorradas: 0, retirados: 0, sinReiniciar: [] }
igual(
  'lo borrado, en plural',
  resumenDeReinicio({ ...nada, anuladas: 1, borrados: 3, ordenesBorradas: 4 }),
  '3 pacientes borrados con 4 órdenes',
)
igual(
  'lo de antes, en singular',
  resumenDeReinicio({ ...nada, borrados: 1, ordenesBorradas: 1, revertidas: 1, retirados: 1 }),
  '1 paciente borrado con 1 orden, 1 orden revertida, 1 paciente retirado',
)
igual('nada que hacer', resumenDeReinicio(nada), 'No había nada que reiniciar')

// ── El alta ────────────────────────────────────────────────────────────────

igual('vacío: pide el número', faltaEnBorrador(BORRADOR_VACIO), 'Falta el WhatsApp de quien capacita.')
igual('sin nombre', faltaEnBorrador({ phone: '04141110001', label: ' ' }), 'Falta quién capacita con ese número.')
igual('completo', faltaEnBorrador({ phone: '04141110001', label: 'Carla' }), undefined)

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
