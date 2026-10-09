/**
 * Pruebas de las clínicas.
 *
 *   npx tsx src/features/admin/clinicas/clinicas.test.ts
 *
 * Lo que se vigila: el alta con sus datos médicos, que la cuenta de pago
 * tenga titular, documento y al menos una forma de pagarle (una cuenta de 20
 * dígitos o un Pago Móvil), lo que se copia para transferir, y que lo que se
 * le paga a la clínica se parta en consultas y comisiones del personal.
 */
import {
  cambioDeCuenta,
  celularAE164,
  comisionEfectiva,
  correccionesDeSolicitud,
  datosDeAlta,
  leerSolicitud,
  telefonoLocal,
  formatoCuenta,
  leerConsultasYComisiones,
  leerCuentaDePago,
  lineasParaCopiar,
  motivoDeAlta,
  normalizarDocumento,
  partirPorMotivo,
  telefonoAE164,
  textoParaCopiar,
} from './clinicas'
import type { AltaDeClinica, BorradorDeCuenta } from './clinicas'

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

// ── El alta ────────────────────────────────────────────────────────────────

const alta: AltaDeClinica = {
  ownerName: 'Ana Pérez',
  ownerDocument: 'V-12.345.678',
  taxId: '',
  specialty: 'Pediatría',
  collegeNumber: '',
  mppsNumber: '',
  clinicName: 'Consultorio Demo',
  address: 'Av. Principal, piso 3',
  phone: '0212 555 12 34',
  email: 'demo@consultorio.com',
  pagoMovilBank: 'Banesco',
  pagoMovilDocument: '12345678',
  pagoMovilPhone: '0414-123 4567',
}
igual('un alta completa pasa (sin RIF, Colegio ni MPPS)', motivoDeAlta(alta), null)
igual('sin nombre no', motivoDeAlta({ ...alta, ownerName: ' ' }), 'Falta el nombre completo.')
igual('sin cédula no', motivoDeAlta({ ...alta, ownerDocument: '' }), 'Falta la cédula o el pasaporte.')
igual('un pasaporte vale', motivoDeAlta({ ...alta, ownerDocument: 'AB1234567' }), null)
igual('un RIF mal escrito manda su motivo', motivoDeAlta({ ...alta, taxId: 'X1' }), 'RIF: Empieza por J, G, V, E o P.')
igual('con RIF bueno pasa', motivoDeAlta({ ...alta, taxId: 'J-12345678-9' }), null)
igual('sin especialidad no', motivoDeAlta({ ...alta, specialty: '' }), 'Falta la especialidad.')
igual('sin consultorio no', motivoDeAlta({ ...alta, clinicName: '' }), 'Falta el nombre del consultorio o centro médico.')
igual('sin dirección no', motivoDeAlta({ ...alta, address: '' }), 'Falta la dirección del consultorio.')
igual('sin teléfono no', motivoDeAlta({ ...alta, phone: '' }) !== null, true)
igual('un correo raro no', motivoDeAlta({ ...alta, email: 'demo@' }), 'El correo no parece un correo.')
igual('sin banco no', motivoDeAlta({ ...alta, pagoMovilBank: '' }), 'Elige el banco del Pago Móvil.')
igual('el Pago Móvil con RIF vale', motivoDeAlta({ ...alta, pagoMovilDocument: 'J-12345678-9' }), null)
igual('el Pago Móvil a un fijo no', motivoDeAlta({ ...alta, pagoMovilPhone: '0212 5551234' }), 'El teléfono del Pago Móvil tiene que ser un celular: 0414 1234567.')
igual('lo que se manda va limpio', datosDeAlta({ ...alta, email: ' Demo@Consultorio.com ' }).email, 'demo@consultorio.com')
igual('un celular a E.164', celularAE164('0414 1234567'), '+584141234567')
igual('un fijo no es celular', celularAE164('0212 5551234'), null)
igual('E.164 a como se escribe', telefonoLocal('+584141234567'), '0414 1234567')

// ── Las solicitudes ────────────────────────────────────────────────────────

const solicitud = leerSolicitud({
  id: 's1',
  status: 'pending',
  owner_name: 'Ana Pérez',
  owner_document: 'V12345678',
  tax_id: null,
  specialty: 'Pediatría',
  clinic_name: 'Consultorio Demo',
  address: 'Av. Principal, piso 3',
  phone: '+582125551234',
  email: 'demo@consultorio.com',
  pago_movil_bank: 'Banesco',
  pago_movil_document: 'V12345678',
  pago_movil_phone: '+584141234567',
  created_at: '2026-10-09T12:00:00Z',
})
igual('la solicitud se lee pendiente', solicitud.status, 'pending')
igual('los teléfonos vuelven como se escriben', solicitud.alta.pagoMovilPhone, '0414 1234567')
igual('la solicitud leída es un alta válida', motivoDeAlta(solicitud.alta), null)
igual('sin cambios no hay correcciones', correccionesDeSolicitud(solicitud.alta, solicitud.alta), null)
igual(
  'solo va lo que se cambió',
  correccionesDeSolicitud(solicitud.alta, { ...solicitud.alta, clinicName: 'Consultorio Ana Pérez' }),
  { clinic_name: 'Consultorio Ana Pérez' },
)
igual('un fijo a E.164', telefonoAE164('0212-5551234'), '+582125551234')

// ── La cuenta de pago ──────────────────────────────────────────────────────

igual('sin cuenta, null', leerCuentaDePago(null), null)
igual('una fila vacía es que no hay', leerCuentaDePago({ bank: null, account_holder: null }), null)

const borrador: BorradorDeCuenta = {
  bank: 'Banesco',
  accountHolder: 'Consultorio Demo C.A.',
  holderDocument: 'j-12345678-9',
  accountNumber: '0134 0000 0000 0000 0000',
  pagoMovilPhone: '',
  pagoMovilBank: '',
}
igual('una cuenta bancaria vale', cambioDeCuenta(borrador), {
  ok: true,
  payload: {
    bank: 'Banesco',
    account_holder: 'Consultorio Demo C.A.',
    holder_document: 'J123456789',
    account_number: '01340000000000000000',
    pago_movil_phone: null,
    pago_movil_bank: null,
  },
})
igual('una cuenta corta no', cambioDeCuenta({ ...borrador, accountNumber: '0134 0000' }), {
  ok: false,
  motivo: 'La cuenta bancaria tiene 20 dígitos.',
})
igual('sin banco no', cambioDeCuenta({ ...borrador, bank: '' }), { ok: false, motivo: 'Falta el banco de la cuenta.' })
igual('sin nada con qué pagar no', cambioDeCuenta({ ...borrador, accountNumber: '' }), {
  ok: false,
  motivo: 'Pon la cuenta bancaria, el Pago Móvil o los dos.',
})
const soloPagoMovil = cambioDeCuenta({
  ...borrador,
  bank: '',
  accountNumber: '',
  pagoMovilPhone: '0414 1234567',
  pagoMovilBank: 'Mercantil',
})
igual('solo Pago Móvil vale', soloPagoMovil.ok ? [soloPagoMovil.payload.pago_movil_phone, soloPagoMovil.payload.bank] : null, [
  '+584141234567',
  null,
])
igual('Pago Móvil sin banco no', cambioDeCuenta({ ...borrador, pagoMovilPhone: '04141234567' }).ok, false)
igual('sin documento no', cambioDeCuenta({ ...borrador, holderDocument: '123' }).ok, false)
igual('documento con puntos', normalizarDocumento('V-12.345.678'), 'V12345678')

const cuenta = leerCuentaDePago({
  bank: 'Banesco',
  account_holder: 'Consultorio Demo C.A.',
  holder_document: 'J123456789',
  account_number: '01340000000000000000',
  pago_movil_phone: '+584141234567',
  pago_movil_bank: 'Mercantil',
})
igual('la cuenta en bloques de cuatro', formatoCuenta('01340000000000000000'), '0134 0000 0000 0000 0000')
igual(
  'lo que se copia, con el Pago Móvil en formato local',
  cuenta ? lineasParaCopiar(cuenta).map((l) => l.valor) : null,
  ['Consultorio Demo C.A.', 'J123456789', 'Banesco', '01340000000000000000', '04141234567', 'Mercantil'],
)
igual(
  'todo en un texto',
  cuenta ? textoParaCopiar(cuenta).split('\n')[0] : null,
  'Titular: Consultorio Demo C.A.',
)

// ── Consultas y comisiones ─────────────────────────────────────────────────

const lineas = [
  { reason: 'scheduled_installment', amountUsd: 50 },
  { reason: 'scheduled_installment', amountUsd: 25.1 },
  { reason: 'staff_commission', amountUsd: 0.5 },
  { reason: 'staff_commission', amountUsd: 0.5 },
]
igual('se parte por motivo', partirPorMotivo(lineas), { consultasUsd: 75.1, comisionesUsd: 1 })
igual(
  'los totales de la base mandan',
  leerConsultasYComisiones({ consultas_usd: '75.10', comisiones_usd: 1.5 }, lineas),
  { consultasUsd: 75.1, comisionesUsd: 1.5 },
)
igual('sin totales, las líneas', leerConsultasYComisiones({}, lineas), { consultasUsd: 75.1, comisionesUsd: 1 })
igual('sin nada, null', leerConsultasYComisiones({}), null)

igual('la propia manda', comisionEfectiva(0.75, 0.5), 0.75)
igual('null es la global', comisionEfectiva(null, 0.5), 0.5)
igual('cero es cero, no la global', comisionEfectiva(0, 0.5), 0)

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
