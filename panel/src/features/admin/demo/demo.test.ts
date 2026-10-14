/**
 * Pruebas de los pacientes demo.
 *
 *   npx tsx src/features/admin/demo/demo.test.ts
 *
 * Lo que se vigila: que la lectura aguante los numeric como texto y el
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
  limit_usd: '3000.0000',
  patients: [
    {
      id: 'a',
      full_name: 'Paciente Demo',
      document_number: 'V99000001',
      phone_e164: '+584141110001',
      email: 'demo@helios.test',
      used_usd: '100.0000',
      available_usd: 2900,
      blocked_reason: null,
      pending_orders: 0,
      open_orders: 1,
    },
  ],
  last_reset: {
    at: '2026-10-14T03:30:00Z',
    automatic: true,
    detail: { revertidas: 2, anuladas: 0, sin_reiniciar: [{ order_number: 41, motivo: 'pago abierto' }] },
  },
})

igual('el límite, de texto a número', estado.limitUsd, 3000)
igual('lo usado y lo disponible', [estado.pacientes[0].usedUsd, estado.pacientes[0].availableUsd], [100, 2900])
igual('las órdenes abiertas', estado.pacientes[0].openOrders, 1)
igual('el último reinicio, automático', estado.ultimoReinicio?.automatico, true)
igual('lo que no se pudo reiniciar', estado.ultimoReinicio?.sinReiniciar, [
  { orderNumber: 41, motivo: 'pago abierto' },
])
igual(
  'sin reinicios todavía',
  leerEstadoDeDemo({ limit_usd: 3000, patients: [], last_reset: null }).ultimoReinicio,
  null,
)

// ── El resumen ─────────────────────────────────────────────────────────────

igual(
  'singular y plural',
  resumenDeReinicio({ revertidas: 1, anuladas: 2, sinReiniciar: [] }),
  '1 orden revertida, 2 preguntas anuladas',
)
igual(
  'nada que hacer',
  resumenDeReinicio({ revertidas: 0, anuladas: 0, sinReiniciar: [] }),
  'No había nada que reiniciar',
)

// ── El alta ────────────────────────────────────────────────────────────────

igual('vacío: pide la cédula', faltaEnBorrador(BORRADOR_VACIO), 'Falta la cédula demo.')
igual(
  'sin correo',
  faltaEnBorrador({ document: 'V99000001', firstName: 'A', lastName: 'B', phone: '04141110001', email: ' ' }),
  'Falta el correo: ahí llega el comprobante.',
)
igual(
  'completo',
  faltaEnBorrador({ document: 'V99000001', firstName: 'A', lastName: 'B', phone: '04141110001', email: 'x@y.z' }),
  undefined,
)

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
