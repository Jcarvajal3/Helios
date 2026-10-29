/**
 * Pruebas del CSV de datos de alta para el contrato.
 *
 *   npx tsx src/features/admin/clinicas/contrato.test.ts
 *
 * Lo que se vigila: que la fila de la RPC se lea entera, que el teléfono y
 * la cuenta salgan como texto que Excel no destroza, que un texto de la
 * portada no se abra como fórmula y el nombre del archivo.
 */
import { archivoDeContrato, csvDeContratos, leerDatosDeContrato } from './contrato'

/** La marca de orden de bytes con que empieza el CSV (ver lib/csv.ts). */
const BOM = String.fromCharCode(0xfeff)

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

const completa = leerDatosDeContrato({
  merchant_id: 'm-1',
  name: 'Dra. Ana María Pérez',
  consultorio: 'Consultorio Dental Ana Pérez',
  legal_name: 'Consultorio Ana Pérez C.A.',
  tax_id: 'J509876543',
  category: 'odontologia',
  specialty: 'Odontología',
  mpps_number: '98765',
  phone: '+582125551234',
  email: 'ana@example.com',
  address: 'Av. Principal, Torre Médica, piso 3',
  city: 'Caracas',
  status: 'paused',
  is_test: true,
  created_at: '2026-10-10T19:00:00+00:00',
  owner_name: 'Ana María Pérez',
  owner_document: 'V12345678',
  college_number: 'COV-1234',
  bank: 'Banesco',
  account_holder: 'Ana María Pérez',
  holder_document: 'V12345678',
  account_number: '01340000000000000001',
  pago_movil_bank: null,
  pago_movil_phone: '+584141234567',
  applied_at: '2026-10-09T13:30:00+00:00',
  approved_at: '2026-10-10T19:00:00+00:00',
})

igual('se lee el titular', [completa.ownerName, completa.ownerDocument, completa.collegeNumber], [
  'Ana María Pérez',
  'V12345678',
  'COV-1234',
])
igual('se lee el estado y la marca de prueba', [completa.status, completa.isTest], ['paused', true])

const vacia = leerDatosDeContrato({ merchant_id: 'm-2', name: 'Sin Datos', status: 'active', is_test: false })
igual('lo que falta es null', [vacia.ownerName, vacia.bank, vacia.appliedAt], [null, null, null])

const lineas = csvDeContratos([completa, vacia]).replace(new RegExp(`^${BOM}`), '').split('\r\n')
const cabecera = lineas[0].split(';')
const fila = lineas[1].split(';')
const celda = (titulo: string) => fila[cabecera.indexOf(titulo)]

igual('una fila por clínica, con la cabecera', lineas.length, 4) // la última, vacía tras el CRLF final
igual('la primera columna es el consultorio, tras el BOM', [csvDeContratos([]).startsWith(`${BOM}Consultorio;`), cabecera[0]], [
  true,
  'Consultorio',
])
igual('el titular va en su columna', celda('Médico titular'), 'Ana María Pérez')
igual('el consultorio va en la suya', celda('Consultorio'), 'Consultorio Dental Ana Pérez')
igual('el teléfono, en local y con espacio', celda('Teléfono'), '0212 5551234')
igual('el celular del Pago Móvil también', celda('Celular del Pago Móvil'), '0414 1234567')
igual('la cuenta, en grupos de 4', celda('N.º de cuenta'), '0134 0000 0000 0000 0001')
igual('el estado dice si es de prueba', celda('Estado'), 'Pausado (prueba)')
igual('la solicitud, en hora de Caracas', celda('Solicitud'), '2026-10-09 09:30:00')
igual(
  'el punto y coma de la dirección no parte la fila',
  csvDeContratos([{ ...completa, address: 'Av. Principal; piso 3' }]).includes(';"Av. Principal; piso 3";'),
  true,
)
igual('sin solicitud, celda vacía', lineas[2].split(';')[cabecera.indexOf('Solicitud')], '')

igual(
  'una fórmula escrita en la portada queda como texto (lib/csv.ts)',
  csvDeContratos([{ ...completa, consultorio: '=HYPERLINK("x")' }]).split('\r\n')[1].startsWith(`"'=HYPERLINK(""x"")";`),
  true,
)

igual('el archivo de todas', archivoDeContrato(), 'datos-de-alta-de-las-clinicas')
igual('el de una, sin tildes', archivoDeContrato('Consultorio Dental Ana Pérez'), 'datos-de-alta-consultorio-dental-ana-perez')

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
