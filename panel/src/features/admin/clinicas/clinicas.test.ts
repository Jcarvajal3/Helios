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
  SIN_CAPACITACION,
  cambioDeCuenta,
  capacitacionParaEnviar,
  celularAE164,
  comoLoNombran,
  fichaParaCompartir,
  nombreComoLoLeen,
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
  motivoDeCapacitacion,
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
  doctorTitle: 'Dra.',
  ownerDocument: 'V12345678',
  taxId: '',
  specialty: 'Pediatría',
  collegeNumber: '',
  mppsNumber: '',
  clinicName: 'Consultorio Demo',
  address: 'Av. Principal, piso 3',
  phone: '0212 555 12 34',
  email: 'demo@consultorio.com',
  socialNetwork: '',
  socialUser: '',
  accountHolder: 'Ana Pérez',
  holderDocument: 'V12345678',
  bank: 'Banesco',
  accountNumber: '01340000000000000001',
  pagoMovilBank: '',
  pagoMovilPhone: '',
}
igual('un alta con transferencia pasa (sin RIF, Colegio ni MPPS)', motivoDeAlta(alta), null)
igual('y en la portada también', motivoDeAlta(alta, 'portada'), null)
igual('sin nombre no', motivoDeAlta({ ...alta, ownerName: ' ' }), 'Falta el nombre completo.')
igual(
  'sin número de cédula no',
  motivoDeAlta({ ...alta, ownerDocument: 'V' }),
  'Falta la cédula o el pasaporte: elige V, E o P y escribe solo los números.',
)
igual('un pasaporte vale', motivoDeAlta({ ...alta, ownerDocument: 'PAB1234567' }), null)
igual('el RIF solo con la letra es «sin RIF»', motivoDeAlta({ ...alta, taxId: 'J' }), null)
igual('un RIF corto no', motivoDeAlta({ ...alta, taxId: 'J1234' }), 'El RIF lleva 8 o 9 números después de la letra.')
igual('con RIF bueno pasa', motivoDeAlta({ ...alta, taxId: 'J123456789' }), null)
igual('sin especialidad no', motivoDeAlta({ ...alta, specialty: '' }), 'Falta la especialidad.')
igual('sin consultorio no', motivoDeAlta({ ...alta, clinicName: '' }), 'Falta el nombre del consultorio o centro médico.')
igual('sin dirección no', motivoDeAlta({ ...alta, address: '' }), 'Falta la dirección del consultorio.')
igual('sin teléfono no', motivoDeAlta({ ...alta, phone: '' }) !== null, true)
igual('un correo raro no', motivoDeAlta({ ...alta, email: 'demo@' }), 'El correo no parece un correo.')
igual(
  'con su red social pasa',
  motivoDeAlta({ ...alta, socialNetwork: 'instagram', socialUser: '@consultorio.demo' }),
  null,
)
igual('un usuario sin la red no', motivoDeAlta({ ...alta, socialUser: '@consultorio.demo' }), 'Elige qué red social es.')
igual(
  'la red sin usuario no',
  motivoDeAlta({ ...alta, socialNetwork: 'tiktok', socialUser: '  ' }),
  'Escribe el usuario o el enlace de la red social.',
)
igual(
  'la red social se manda limpia',
  ((d) => [d.social_network, d.social_user])(
    datosDeAlta({ ...alta, socialNetwork: 'instagram', socialUser: ' @consultorio.demo ' }, 'portada'),
  ),
  ['instagram', '@consultorio.demo'],
)
igual('el título va con el alta', datosDeAlta({ ...alta, doctorTitle: 'Od.' }).doctor_title, 'Od.')
igual('cómo la nombran sus pacientes', comoLoNombran('Dra.', '  ana maría DE la rosa '), 'Dra. Ana María de la Rosa')
igual('sin título, el nombre solo (y sin el «Dr.» escrito a mano)', comoLoNombran('', 'Dr. luis gómez'), 'Luis Gómez')
igual('un «Od.» escrito a mano no sale dos veces', comoLoNombran('Od.', 'od. ana pérez'), 'Od. Ana Pérez')
igual('«la» tras «de», en minúscula', nombreComoLoLeen('MARÍA DE LA LUZ seijas'), 'María de la Luz Seijas')
igual('«La» suelta es apellido', nombreComoLoLeen('daniel peña la grave'), 'Daniel Peña La Grave')
igual('las partículas portuguesas', nombreComoLoLeen('sonia DE abreu DOS reis'), 'Sonia de Abreu dos Reis')
igual('mayúscula tras el guion', nombreComoLoLeen('ricardo ziri-castro'), 'Ricardo Ziri-Castro')

// ── Los datos para un interesado ───────────────────────────────────────────

igual(
  'los datos del médico, cada uno en su línea',
  fichaParaCompartir({
    nombre: 'Dra. Nadia Andi Khabbaze Alfaro',
    especialidad: 'ODONTOLOGÍA ESTÉTICA.',
    telefono: '+584141234567',
    direccion: 'Av. Principal, Torre Médica, piso 3',
    ciudad: 'Caracas',
  }),
  '*Dra. Nadia Andi Khabbaze Alfaro*\nEspecialidad: Odontología estética\nTeléfono: 0414-1234567\nDirección: Av. Principal, Torre Médica, piso 3, Caracas',
)
igual(
  'la ciudad no se repite, y lo que falta no sale',
  fichaParaCompartir({ nombre: 'Dr. Luis Gómez', especialidad: null, telefono: null, direccion: 'Calle 5, Caracas', ciudad: 'Caracas' }),
  '*Dr. Luis Gómez*\nDirección: Calle 5, Caracas',
)
igual(
  'sin título no',
  motivoDeAlta({ ...alta, doctorTitle: '' }),
  'Falta el título que verán sus pacientes: Dr., Dra., Lcdo., Lcda. u Od.',
)
igual('sin titular no', motivoDeAlta({ ...alta, accountHolder: '' }), 'Falta el titular de la cuenta.')
igual('el titular con RIF vale', motivoDeAlta({ ...alta, holderDocument: 'J123456789' }), null)
igual('sin banco de la cuenta no', motivoDeAlta({ ...alta, bank: '' }), 'Elige el banco de la cuenta.')
igual('una cuenta corta no', motivoDeAlta({ ...alta, accountNumber: '0134' }), 'El número de cuenta tiene 20 dígitos.')
igual(
  'una cuenta de otro banco no',
  motivoDeAlta({ ...alta, accountNumber: '01050000000000000001' }),
  'Esa cuenta no es de Banesco: las de ese banco empiezan por 0134.',
)
const altaSoloPagoMovil = { ...alta, bank: '', accountNumber: '', pagoMovilBank: 'Mercantil', pagoMovilPhone: '0414-123 4567' }
igual('el equipo puede dar solo Pago Móvil', motivoDeAlta(altaSoloPagoMovil), null)
igual('la portada no: pide la cuenta', motivoDeAlta(altaSoloPagoMovil, 'portada'), 'Falta el número de cuenta.')
igual(
  'sin transferencia ni Pago Móvil no',
  motivoDeAlta({ ...alta, accountNumber: '' }),
  'Pon la transferencia, el Pago Móvil o los dos.',
)
igual(
  'el Pago Móvil a un fijo no',
  motivoDeAlta({ ...altaSoloPagoMovil, pagoMovilPhone: '0212 5551234' }),
  'El teléfono del Pago Móvil tiene que ser un celular: 0414 1234567.',
)
igual('lo que se manda va limpio', datosDeAlta({ ...alta, email: ' Demo@Consultorio.com ' }).email, 'demo@consultorio.com')
igual('el RIF vacío no se manda', datosDeAlta({ ...alta, taxId: 'J' }).tax_id, '')
igual('la portada no manda Pago Móvil', 'pago_movil_phone' in datosDeAlta(altaSoloPagoMovil, 'portada'), false)
igual('un celular a E.164', celularAE164('0414 1234567'), '+584141234567')
igual('un fijo no es celular', celularAE164('0212 5551234'), null)
igual('E.164 a como se escribe', telefonoLocal('+584141234567'), '0414 1234567')

// ── Las solicitudes ────────────────────────────────────────────────────────

const solicitud = leerSolicitud({
  id: 's1',
  status: 'pending',
  owner_name: 'Ana Pérez',
  doctor_title: 'Dra.',
  owner_document: 'V12345678',
  tax_id: 'J-123456789',
  specialty: 'Pediatría',
  clinic_name: 'Consultorio Demo',
  address: 'Av. Principal, piso 3',
  phone: '+582125551234',
  email: 'demo@consultorio.com',
  social_network: 'facebook',
  social_user: 'Consultorio Demo',
  account_holder: 'Ana Pérez',
  holder_document: 'J-123456789',
  bank: 'Banesco',
  account_number: '01340000000000000001',
  pago_movil_bank: null,
  pago_movil_phone: null,
  created_at: '2026-10-09T12:00:00Z',
})
igual('la solicitud se lee pendiente', solicitud.status, 'pending')
igual('el RIF vuelve sin guion', solicitud.alta.holderDocument, 'J123456789')
igual('la red social se lee', [solicitud.alta.socialNetwork, solicitud.alta.socialUser], ['facebook', 'Consultorio Demo'])
igual('una red desconocida se lee vacía', leerSolicitud({ social_network: 'myspace' }).alta.socialNetwork, '')
igual('el título se lee', leerSolicitud({ doctor_title: 'Lcda.' }).alta.doctorTitle, 'Lcda.')
igual('un título desconocido se lee vacío', leerSolicitud({ doctor_title: 'Ing.' }).alta.doctorTitle, '')
igual('la solicitud leída es un alta válida', motivoDeAlta(solicitud.alta), null)
igual('sin cambios no hay correcciones', correccionesDeSolicitud(solicitud.alta, solicitud.alta), null)
igual(
  'solo va lo que se cambió',
  correccionesDeSolicitud(solicitud.alta, { ...solicitud.alta, clinicName: 'Consultorio Ana Pérez' }),
  { clinic_name: 'Consultorio Ana Pérez' },
)
igual('un fijo a E.164', telefonoAE164('0212-5551234'), '+582125551234')

// ── La capacitación presencial ─────────────────────────────────────────────

igual('sin capacitación vale', motivoDeCapacitacion(SIN_CAPACITACION, '2026-10-23'), null)
igual(
  'el día sin la hora no',
  motivoDeCapacitacion({ dia: '2026-10-30', hora: '' }, '2026-10-23'),
  'Pon el día y la hora de la capacitación.',
)
igual(
  'hoy no: de mañana en adelante',
  motivoDeCapacitacion({ dia: '2026-10-23', hora: '10:00' }, '2026-10-23'),
  'La capacitación tiene que ser de mañana en adelante.',
)
igual('mañana sí', motivoDeCapacitacion({ dia: '2026-10-24', hora: '10:00' }, '2026-10-23'), null)
igual(
  'a más de 90 días no',
  motivoDeCapacitacion({ dia: '2027-01-22', hora: '10:00' }, '2026-10-23'),
  'La capacitación tiene que ser en los próximos 90 días.',
)
igual('se manda con la hora de Caracas', capacitacionParaEnviar({ dia: '2026-10-30', hora: '10:00' }), '2026-10-30T10:00:00-04:00')
igual('sin capacitación no se manda', capacitacionParaEnviar(SIN_CAPACITACION), null)
igual(
  'la solicitud trae la capacitación',
  leerSolicitud({ training_at: '2026-10-30T14:00:00+00:00' }).capacitacion,
  '2026-10-30T14:00:00+00:00',
)

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
