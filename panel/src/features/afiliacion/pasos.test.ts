/**
 * Pruebas de la afiliación por pasos.
 *
 *   npx tsx src/features/afiliacion/pasos.test.ts
 *
 * Lo que se vigila: que cada paso frene lo mismo que `motivoDeAlta`, campo a
 * campo; que el banco salga de la cuenta; que la cuenta propia ponga al
 * médico de titular, que «Cédula o RIF» reparta la cédula y el RIF según su
 * letra, y que lo que se manda sea lo mismo que antes.
 */
import {
  ALTA_VACIA,
  SIN_CAPACITACION,
  datosDeAlta,
  motivoDeAlta,
} from '../admin/clinicas/clinicas'
import type { AltaDeClinica } from '../admin/clinicas/clinicas'
import type { Borrador } from './pasos'
import {
  altaParaEnviar,
  bancoDeCuenta,
  erroresDelPaso,
  primerError,
} from './pasos'

let fallos = 0
function igual(nombre: string, obtenido: unknown, esperado: unknown) {
  const ok = JSON.stringify(obtenido) === JSON.stringify(esperado)
  if (!ok) {
    fallos++
    console.error(
      `✗ ${nombre}\n  esperado: ${JSON.stringify(esperado)}\n  obtenido: ${JSON.stringify(obtenido)}`,
    )
  } else {
    console.log(`✓ ${nombre}`)
  }
}

const HOY = '2026-10-26'

// Lo que escribe el médico: sin cédula (va en «Cédula o RIF»), banco ni
// titular (los pone el formulario).
const escrita: AltaDeClinica = {
  ...ALTA_VACIA,
  ownerName: 'Ana Pérez',
  specialty: 'Pediatría',
  clinicName: 'Consultorio Demo',
  address: 'Av. Principal, piso 3',
  phone: '0212 555 12 34',
  email: 'demo@consultorio.com',
  accountNumber: '01340000000000000001',
}

const borrador = (cambios: Partial<Borrador> = {}): Borrador => ({
  alta: escrita,
  documento: 'V12345678',
  cuentaPropia: true,
  capacitacion: SIN_CAPACITACION,
  ...cambios,
})

// ── El banco ───────────────────────────────────────────────────────────────

igual(
  'el banco sale de los 4 primeros dígitos',
  bancoDeCuenta('0134 0000'),
  'Banesco',
)
igual('con menos de 4, todavía no', bancoDeCuenta('013'), '')
igual('un código que no está, ninguno', bancoDeCuenta('0999000000'), '')

// ── Lo que se manda ────────────────────────────────────────────────────────

const propia = altaParaEnviar(borrador())
igual(
  'con V, «Cédula o RIF» es la cédula y no hay RIF',
  [propia.ownerDocument, propia.taxId],
  ['V12345678', ''],
)
igual(
  'cuenta propia: el titular es el médico',
  [propia.accountHolder, propia.holderDocument],
  ['Ana Pérez', 'V12345678'],
)
igual('y el banco, el de la cuenta', propia.bank, 'Banesco')
igual('pasa el freno de siempre', motivoDeAlta(propia, 'portada'), null)
igual(
  'manda lo mismo que el alta escrita a mano',
  datosDeAlta(propia, 'portada'),
  datosDeAlta(
    {
      ...escrita,
      ownerDocument: 'V12345678',
      bank: 'Banesco',
      accountHolder: 'Ana Pérez',
      holderDocument: 'V12345678',
    },
    'portada',
  ),
)

const conRif = altaParaEnviar(
  borrador({
    documento: 'J123456789',
    alta: { ...escrita, ownerDocument: 'E8765432' },
  }),
)
igual(
  'con J, es el RIF y la cédula va aparte',
  [conRif.taxId, conRif.ownerDocument],
  ['J123456789', 'E8765432'],
)
igual(
  'y el titular propio lleva la cédula, no el RIF',
  conRif.holderDocument,
  'E8765432',
)
igual('pasa el freno de siempre con RIF', motivoDeAlta(conRif, 'portada'), null)

const ajena = altaParaEnviar(
  borrador({
    cuentaPropia: false,
    alta: {
      ...escrita,
      accountHolder: 'Consultorio Demo C.A.',
      holderDocument: 'J123456789',
    },
  }),
)
igual(
  'cuenta ajena: se queda el titular escrito',
  [ajena.accountHolder, ajena.holderDocument],
  ['Consultorio Demo C.A.', 'J123456789'],
)

// ── Los pasos ──────────────────────────────────────────────────────────────

const pasos = (b: Borrador) =>
  [0, 1, 2].map((p) => erroresDelPaso(p as 0 | 1 | 2, b, HOY))
const conAlta = (cambios: Partial<AltaDeClinica>) =>
  borrador({ alta: { ...escrita, ...cambios } })

igual('el alta completa pasa los tres pasos', pasos(borrador()), [{}, {}, {}])
igual(
  'vacía, el paso 1 pide nombre, cédula o RIF y especialidad',
  Object.keys(pasos(borrador({ alta: ALTA_VACIA, documento: '' }))[0]),
  ['ownerName', 'documento', 'specialty'],
)
igual(
  'la cédula corta se explica',
  pasos(borrador({ documento: 'V123' }))[0].documento,
  'La cédula lleva de 6 a 9 números.',
)
igual(
  'el RIF corto también',
  pasos(borrador({ documento: 'J123' }))[0].documento,
  'El RIF lleva 8 o 9 números.',
)
igual(
  'el pasaporte corto también',
  pasos(borrador({ documento: 'PAB1' }))[0].documento,
  'El pasaporte lleva de 5 a 15 letras y números.',
)
igual(
  'con RIF de empresa falta la cédula',
  pasos(borrador({ documento: 'J123456789' }))[0],
  {
    ownerDocument: 'Escribe el número de tu cédula o pasaporte.',
  },
)
igual(
  'el teléfono mal escrito',
  pasos(conAlta({ phone: '1234' }))[1].phone,
  'Revisa el número: 0414 1234567 o 0212 5551234.',
)
igual(
  'el correo vacío',
  pasos(conAlta({ email: '' }))[1].email,
  'Escribe tu correo electrónico.',
)
igual(
  'la red social va entera',
  pasos(conAlta({ socialNetwork: 'instagram' }))[1],
  {
    socialUser: 'Escribe tu usuario o el enlace.',
  },
)
igual(
  'cuenta ajena sin titular',
  Object.keys(pasos(borrador({ cuentaPropia: false }))[2]),
  ['accountHolder', 'holderDocument'],
)
igual(
  'la cuenta corta dice cuántos faltan',
  pasos(conAlta({ accountNumber: '0134000000' }))[2].accountNumber,
  'Te faltan 10 dígitos: la cuenta tiene 20.',
)
igual(
  'una cuenta de un banco desconocido',
  pasos(conAlta({ accountNumber: '09990000000000000001' }))[2].accountNumber,
  'No reconocemos el banco de esta cuenta: revisa los 4 primeros dígitos.',
)
igual(
  'la capacitación, con día y hora',
  pasos(borrador({ capacitacion: { dia: '2026-10-30', hora: '' } }))[2],
  {
    capacitacionHora: 'Elige la hora.',
  },
)
igual(
  'no puede ser hoy',
  pasos(borrador({ capacitacion: { dia: HOY, hora: '10:00' } }))[2]
    .capacitacionDia,
  'Elige un día a partir de mañana.',
)
igual(
  'ni pasados los 90 días',
  pasos(borrador({ capacitacion: { dia: '2027-02-01', hora: '10:00' } }))[2]
    .capacitacionDia,
  'Elige un día dentro de los próximos 90 días.',
)
igual(
  'el foco va al primero del paso',
  primerError(1, pasos(conAlta({ address: '', email: '' }))[1]),
  'address',
)

if (fallos > 0) {
  console.error(
    `\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`,
  )
  process.exit(1)
}
console.log('\nTodo bien.')
