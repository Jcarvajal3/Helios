/**
 * Pruebas de los consumos de una persona.
 *
 *   npx tsx src/features/admin/directorio/consumosDePersona.test.ts
 *
 * Lo que se comprueba no se ve mirando la pantalla: una fila con la comisión
 * dentro parece una fila correcta, y una parte que falta se leería como cero.
 */
import { leerConsumosDePersona } from './consumosDePersona'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

// Dos filas como las manda `admin_user_detail.consumos` en dev: un grupo que
// abrió otra persona y un consumo pendiente, sin cuotas todavía.
const filas = leerConsumosDePersona([
  {
    charge_id: 'grupo-ajeno',
    order_number: 1043,
    status: 'confirmed',
    business_date: '2026-09-20',
    created_at: '2026-09-21T01:00:00Z',
    confirmed_at: '2026-09-21T01:01:00Z',
    void_reason: null,
    merchant_id: 'local-2',
    merchant_name: null,
    group_id: 'g1',
    is_group: true,
    started_it: false,
    financed_usd: '40.00',
    share_financed_usd: 15,
  },
  {
    charge_id: 'pendiente',
    order_number: 1044,
    status: 'pending',
    business_date: null,
    created_at: '2026-09-19T23:00:00Z',
    confirmed_at: null,
    void_reason: null,
    merchant_id: 'local-1',
    merchant_name: 'Kabal',
    group_id: null,
    is_group: false,
    started_it: true,
    financed_usd: 12,
    share_financed_usd: null,
  },
])

console.log('── La lectura de la base ────────────────────────────────────')
comprueba(filas.length === 2, 'una fila por financiamiento', String(filas.length))
comprueba(
  filas.map((f) => f.chargeId).join() === 'grupo-ajeno,pendiente',
  'en el orden de la base, del más reciente al más viejo',
  filas.map((f) => f.chargeId).join(),
)
const ajeno = filas.at(0)
comprueba(ajeno?.cuentaUsd === 40 && ajeno.parteUsd === 15, 'financiamiento de 40, leído del texto, y su parte 15')
comprueba(ajeno?.merchantName === null, 'una clínica sin nombre queda en null, no en texto vacío')
const pendiente = filas.at(1)
comprueba(pendiente?.parteUsd === null, 'un pendiente no tiene parte: null, no cero')
comprueba(pendiente?.merchantName === 'Kabal', 'la clínica con su nombre')
comprueba(leerConsumosDePersona(undefined).length === 0, 'sin la clave, ninguna fila')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} ${fallos === 1 ? 'fallo' : 'fallos'}.`)
if (fallos > 0) process.exit(1)
