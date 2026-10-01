/**
 * Pruebas de los datos de un paciente.
 *
 *   npx tsx src/features/admin/pacientes/datos.test.ts
 *
 * Lo que se vigila: que la pestaña `datos` se lea venga anidada o no, que
 * corregir el contacto mande solo lo que cambió (el mismo teléfono escrito
 * de otra forma no es un cambio), que un fijo no pase como móvil y que un
 * cambio propuesto enseñe solo lo que difiere.
 */
import {
  cambioDeDatos,
  cambiosDelPaciente,
  edadEn,
  leerCambioPropuesto,
  leerDatosDelPaciente,
  movilAE164,
} from './datos'

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

const detalle = {
  user_id: 'u1',
  created_at: '2026-10-01T14:00:00Z',
  datos: {
    document: 'V12345678',
    birth_date: '1990-04-12',
    age: 36,
    sex: 'M',
    phone_e164: '+584141234567',
    email: 'jose@gmail.com',
    email_invalid_at: '2026-10-02T10:00:00Z',
    state: 'Miranda',
    city: 'Caracas',
    address: 'Los Palos Grandes',
    occupation: null,
    reference_name: 'María Pérez',
    reference_phone: '+584241234567',
    reference_relationship: 'Madre',
    registered_by_name: 'Ana',
    registered_merchant_name: 'Consultorio Demo',
  },
}
const datos = leerDatosDelPaciente(detalle)
igual('se lee de `datos`', [datos.document, datos.age, datos.registeredMerchantName], ['V12345678', 36, 'Consultorio Demo'])
igual('el alta, de la raíz si `datos` no la trae', datos.createdAt, '2026-10-01T14:00:00Z')
igual('el correo inválido se lee', datos.emailInvalidAt, '2026-10-02T10:00:00Z')
igual('sin `datos`, de la raíz', leerDatosDelPaciente({ document_number: 'E81234567', email: 'x@y.com' }).document, 'E81234567')

igual('edad antes del cumpleaños', edadEn('1990-04-12', '2026-04-11'), 35)
igual('edad el día del cumpleaños', edadEn('1990-04-12', '2026-04-12'), 36)
igual('sin fecha, sin edad', edadEn(null, '2026-04-12'), null)

// ── Móviles ────────────────────────────────────────────────────────────────

igual('0414 a E.164', movilAE164('0414-123.45.67'), '+584141234567')
igual('el 0422 es móvil', movilAE164('04221234567'), '+584221234567')
igual('con el 58', movilAE164('+58 426 1234567'), '+584261234567')
igual('un fijo no', movilAE164('0212 5551234'), null)
igual('corto no', movilAE164('0414 123'), null)

// ── Corregir ───────────────────────────────────────────────────────────────

const borrador = {
  phone: '0414 1234567',
  email: 'JOSE@gmail.com',
  state: 'Miranda',
  city: 'Caracas',
  address: 'Los Palos Grandes',
  occupation: '',
  reference_name: 'María Pérez',
  reference_phone: '0424-1234567',
  reference_relationship: 'Madre',
}
igual('lo mismo escrito distinto no es un cambio', cambioDeDatos(datos, borrador), {
  ok: false,
  motivo: 'No has cambiado nada.',
})
igual(
  'solo lo que cambia',
  cambioDeDatos(datos, { ...borrador, email: 'jose.perez@gmail.com', occupation: 'Docente' }),
  { ok: true, payload: { email: 'jose.perez@gmail.com', occupation: 'Docente' }, campos: ['email', 'occupation'] },
)
igual(
  'el teléfono va en E.164',
  cambioDeDatos(datos, { ...borrador, phone: '0416 7654321' }),
  { ok: true, payload: { phone: '+584167654321' }, campos: ['phone'] },
)
igual('borrar la ocupación es un cambio a null', cambioDeDatos({ ...datos, occupation: 'Docente' }, borrador), {
  ok: true,
  payload: { occupation: null },
  campos: ['occupation'],
})
igual('sin teléfono no', cambioDeDatos(datos, { ...borrador, phone: ' ' }).ok, false)
igual('un fijo no', cambioDeDatos(datos, { ...borrador, phone: '0212 5551234' }).ok, false)
igual('sin correo no', cambioDeDatos(datos, { ...borrador, email: '' }).ok, false)
igual('correo mal escrito no', cambioDeDatos(datos, { ...borrador, email: 'jose@gmail' }).ok, false)
igual('referencia con un fijo no', cambioDeDatos(datos, { ...borrador, reference_phone: '0212 5551234' }).ok, false)

// ── Cambios propuestos ─────────────────────────────────────────────────────

const propuesto = leerCambioPropuesto({
  id: 'r1',
  profile_id: 'u1',
  patient_name: 'José Pérez',
  merchant_name: 'Clínica Norte',
  requested_by_name: 'Carla',
  status: 'pendiente',
  created_at: '2026-10-05T10:00:00Z',
  proposed: { email: 'otro@gmail.com', city: 'Caracas', phone: '+584141111111' },
  current: { email: 'jose@gmail.com', city: 'Caracas', phone: '+584141234567' },
})
igual('solo lo que difiere', propuesto.diferencias.map((d) => d.campo), ['email', 'phone'])
igual('con su nombre', propuesto.diferencias.map((d) => d.rotulo), ['Correo', 'Teléfono'])
igual('lo propuesto y lo actual', [propuesto.diferencias[0]?.actual, propuesto.diferencias[0]?.propuesto], [
  'jose@gmail.com',
  'otro@gmail.com',
])
igual('sin `current`, todo es diferencia', leerCambioPropuesto({ id: 'r2', user_id: 'u2', changes: { city: 'Maracay' } }).diferencias.length, 1)
igual('el paciente también de user_id', leerCambioPropuesto({ id: 'r2', user_id: 'u2' }).profileId, 'u2')

const varios = [
  propuesto,
  { ...propuesto, id: 'r3', createdAt: '2026-10-07T10:00:00Z' },
  { ...propuesto, id: 'r4', profileId: 'otro' },
]
igual('los de un paciente, del más nuevo', cambiosDelPaciente(varios, 'u1').map((c) => c.id), ['r3', 'r1'])

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
